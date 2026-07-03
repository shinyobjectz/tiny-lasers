/* hello_bridge.c — the __host bridge ABI reference guest (docs/host-bridge-abi.md §5b, §2).
 *
 * Proves the full typed-host-call round trip on a plain wasm32-wasi CORE module (no component model):
 *   host --(tl_alloc + write + run(ptr,len))--> guest
 *   guest --(host_call("echo_up", ["<input>"]))--> host concern (TinyLasers.Wasm.HostEcho)
 *   guest <-- JSON string result
 *   host  <-- run returns (ptr<<32)|len pointing at "<input>|<UPCASED>"
 *
 * Freestanding on purpose: no libc calls, static bump allocator — the ABI must not depend on a guest
 * malloc implementation, only on the exported tl_alloc convention.
 *
 * Build (committed fixture; rebuild only when the contract changes):
 *   zig cc --target=wasm32-wasi -O2 -mexec-model=reactor \
 *     -Wl,--export=run -Wl,--export=tl_alloc hello_bridge.c -o hello_bridge.wasm
 */

__attribute__((import_name("host_call")))
extern int host_call(const char *name, int name_len,
                     const char *args, int args_len,
                     char *out, int out_cap);

static char heap[65536];
static int hp = 0;

__attribute__((export_name("tl_alloc")))
char *tl_alloc(int n) {
  char *p = &heap[hp];
  hp = (hp + n + 7) & ~7;
  return p;
}

__attribute__((export_name("run")))
long long run(const char *in, int len) {
  /* args JSON: ["<input>"] — test inputs contain no quotes/backslashes (ABI doc §2: JSON marshaling;
   * a real compiler backend emits a full JSON encoder, the reference keeps the fixture readable). */
  char args[1024];
  int al = 0;
  args[al++] = '[';
  args[al++] = '"';
  for (int i = 0; i < len && al < 1000; i++) args[al++] = in[i];
  args[al++] = '"';
  args[al++] = ']';

  char out[4096];
  int rl = host_call("echo_up", 7, args, al, out, (int)sizeof out);

  /* result = "<input>|<host result sans JSON quotes>" */
  char *res = tl_alloc(len + 1 + (rl > 2 ? rl - 2 : 0));
  int n = 0;
  for (int i = 0; i < len; i++) res[n++] = in[i];
  res[n++] = '|';
  for (int i = 1; i < rl - 1; i++) res[n++] = out[i];

  return ((long long)(int)res << 32) | (unsigned int)n;
}
