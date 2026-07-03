# The `__host` Bridge ABI — typed host calls for core wasm guests

**Status: v1 contract.** This is the core-module replacement for what WIT components provided: typed,
named host calls from an untrusted wasm guest, plus typed entry into the guest — with the guest compiled
to plain `wasm32-wasi` (or wasix) core modules. It documents what `TinyLasers.Wasm` executes **today**
(audited against `lib/tiny_lasers/wasm.ex` `call_host/3`), so a compiler backend can codegen against it
without reading the runtime. Nothing here requires the component model, canonical ABI, or wasmtime.

## 0. Execution model (what runs your module)

- **Interpreter lane** — `TinyLasers.Wasm.call/4`, `call_io/4`, `instance_*`. Full import support
  (everything below). Linear memory is a per-call `:atomics` array inside an isolated BEAM process.
- **Tiered transpile lane** — per-FUNCTION compile to BEAM. A function whose body calls an import (or any
  unsupported op) stays interpreted; every other function compiles. "Never wrong code": unsupported means
  fall back, not fail. Import-heavy modules therefore run **today** with hot compute compiled.
- **Bounds** (all per run, all overridable): instruction fuel (default 2e9, `:out_of_fuel` trap), call
  depth (10_000, `:stack_exhausted`), memory ceiling (4096 pages = 256 MB, `memory.grow` can never OOM
  the host). Wall-clock + heap are bounded by the caller's sandbox process.

## 1. Import namespaces

Built-in host imports match on **function name only** — the guest's import *module* string is ignored
(`env`, `wasi_snapshot_preview1`, `wasix_32v1` all work). Resolution order:

1. **WASI preview1 slice** — `fd_*`, `path_*`, `args_*`, `environ_*`, `clock_time_get`, `random_get`,
   `poll_oneoff`, `sched_yield`, `proc_exit` — backed by the virtual FS/fd-table/tty. Standard WASI
   signatures and errnos.
2. **WASIX (`wasix_32v1`) slice** — `futex_*`, `thread_*`, `proc_*` (spawn/exec/fork/join/signal),
   `sock_*`, signal machinery. Proven against real wasix-libc-compiled binaries.
3. **Generic bridge** — `host_call` / `host_call_async` (§2), `host_exec`/`host_exec_read`,
   `host_http`/`host_http_read` (§3).
4. **Per-run extension table** — `Process.put(:tl_imports, %{{mod, name} => fun/1, name => fun/1})`,
   checked **after** all built-ins (can never shadow the core ABI). The fun receives the raw arg list
   (integers) and returns the result integer (or nil). This is how a host embeds arbitrary extra imports
   for one run.
5. Anything else → hard error `"unimplemented host import 'mod'.'name'"` (a trap, caught by the sandbox).

## 2. The typed host call: `host_call`

The generic seam a typed-language guest uses instead of a WIT world. One import covers every host
function; **concerns add no runtime clause**.

```wat
;; (import "env" "host_call"
;;   (func (param i32 i32 i32 i32 i32 i32) (result i32)))
;; host_call(name_ptr, name_len, args_ptr, args_len, out_ptr, out_cap) -> result_len
```

- `name` — raw UTF-8 bytes, the host function name, convention `<concern>_<op>` (§4).
- `args` — a **JSON array** (UTF-8 bytes). Marshaling for every type WIT gave you:
  strings → JSON strings, numbers → JSON numbers, bools → bools, records → objects, lists → arrays,
  option → value/null, result → `{"ok": …}` / `{"error": …}`.
- Return value: **byte length of the JSON-encoded result**, which the runtime writes into the guest's
  `out_ptr` buffer. The guest allocates `out`; the host never allocates guest memory.
- `out_cap`: v1 runtimes ignore it (legacy `0` = "buffer is big enough"). Codegen MUST either size `out`
  generously (≥ 64 KiB) **or** use the two-step pattern (§3) for unbounded results. (Planned hardening:
  `out_cap > 0` → result truncated-with-needed-length semantics; do not rely on overrun.)
- Errors: a failed host fn raises host-side → the run traps (catchable by the embedding sandbox, never
  the host process). Recoverable errors are returned **in-band** as JSON (`{"error": …}` result-shape by
  concern convention).

Async variant:

```wat
;; host_call_async(name_ptr, name_len, args_ptr, args_len, promise_id) -> 0
```

Fire-and-forget; the concern later resolves guest promise `promise_id` via
`TinyLasers.Wasm.Actor.io_complete/4` → the guest's `wb_complete` re-entry export. Use only in
actor/instance mode (§5b); one-shot `call/4` guests use the sync form.

## 3. Unbounded results: the two-step size-then-read pattern

For results whose size the guest can't bound (process output, HTTP bodies), the ABI ships a proven
two-step shape — mirror it for new concerns:

```
len = host_exec(cmd_ptr, cmd_len, stdin_ptr, stdin_len)   ;; runs; host STASHES output; returns length
buf = alloc(len)
code = host_exec_read(buf)                                 ;; copies stash into buf; returns exit code
```

Same for `host_http` (returns body length; `-1` = no transport wired) / `host_http_read` (returns HTTP
status). The stash is per-run process state — no cross-guest leakage; a second call overwrites the first.

## 4. Adding a typed host concern (the Dock/nexus side)

`host_call("<concern>_<op>", args)` routes by naming convention:
`TinyLasers.Wasm.Host<Concern>.call(name, args)` — discovered via `Code.ensure_loaded?` +
`function_exported?`. **The concern module may live in the embedding application** (define
`TinyLasers.Wasm.HostDock` in your own tree); the runtime carries no registry and no opinions. Rules:

- `call(name, args)` returns a JSON-encodable term (`TinyLasers.Wasm.Actor.Term.to_json/1`).
- `call_async(name, args, promise_id)` resolves later via `Actor.io_complete/4`.
- Marshal per §2. Derive the arg/return shapes mechanically from your one source of truth
  (for nexus: `Dock.host_fn_wit/1` signatures → JSON layout above).
- Alternatively, for raw numeric imports (no JSON), use the `:tl_imports` table (§1.4).

## 5. Host → guest entry (calling the guest)

Two conventions, both live today:

**(a) POSIX-style (what the shell/coreutils use).** The host sets argv/stdin/env, runs `_start` (or an
export) via `call_io/4`, and reads captured stdout + exit code. The guest is an ordinary CLI program; no
special exports. This is the drop-in for "run this tool on this input".

**(b) Typed entry (the `Sandbox.call_function(pid, "run", [src])` replacement).** Export args are
integers, so strings go through guest memory:

```
export "tl_alloc"  (func (param i32) (result i32))          ;; bump/malloc; cabi_realloc-compatible wrappers fine
export "run"       (func (param i32 i32) (result i64))      ;; (ptr, len) -> (ptr << 32) | len
```

Host side: `tl_alloc(len)` → `write_bytes` the input → `call "run" [ptr, len]` → unpack the i64 →
read result bytes from guest memory. Returning `0` means "empty". For multi-arg typed entries, pass ONE
JSON array (same marshaling as §2) — one string in, one string out, uniformly.
*(Runtime work item: a `TinyLasers.Wasm.call_str/4` helper wrapping this chain — see the hello-bridge
reference test; until it lands, the four primitive calls above are all public API.)*

## 6. Traps & error mapping

| Guest event | Host-visible result |
|---|---|
| `proc_exit(code)` / wasix `proc_exit2` | clean exit, code captured |
| fuel exhausted | `:out_of_fuel` trap |
| call depth > max | `:stack_exhausted` trap |
| `memory.grow` past ceiling | grow fails in-guest (returns -1), host unaffected |
| unknown import | trap `"unimplemented host import …"` |
| WASI fn errors | standard WASI errno returned in-guest |
| host concern raises | run trap (sandbox catches; host process never dies) |

All traps land in the embedding process as catchable throws; the BEAM process sandbox (heap cap +
wall-clock) is the outer wall.

## 7. Building guests (reference toolchain)

No wasi-sdk required: `zig cc --target=wasm32-wasi -O2 guest.c -o guest.wasm` produces a conforming core
module (wasi-libc included). Rust: `--target wasm32-wasip1`. The `__host` imports are plain externs:

```c
__attribute__((import_name("host_call")))
extern int host_call(const char* name, int name_len, const char* args, int args_len,
                     char* out, int out_cap);
```

## 8. What this deliberately does NOT include

- No component-model binary parsing, no canonical-ABI lift/lower, no resource handles. Components were
  the envelope; this ABI is the letter. Compile to core, link the shim, done.
- No host-side policy (exec policy, HTTP transport, Dock catalogs are all embedder hooks:
  `:tl_exec_policy`, `:tl_http`, concern modules).
