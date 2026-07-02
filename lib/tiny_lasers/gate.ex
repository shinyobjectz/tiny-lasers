defmodule TinyLasers.Gate do
  @moduledoc """
  Capability-gate spike: compile a confined guest to **native BEAM** and run it.

  This is the security core of the "drop WASM, confine on the BEAM" architecture —
  the thing the red-team (`test/guest_gate_redteam_test.exs`) attacks. It is NOT a
  JS frontend (guest programs are hand-built ASTs) and NOT an execution-speed claim;
  it isolates the one risky assumption: *can a handle-capability gate confine native
  BEAM code so a hostile guest cannot reach the host?*

      compile/2      guest AST + granted cap names -> real BEAM module (Code.compile_quoted)
      run/2          run the module in-process, collecting output / fs effects
      run_isolated/2 run in a heap-capped, timeout-bounded, monitored process (DoS containment)
      refs/1         every external module/BIF the emitted bytecode references
      dangerous_refs/1  the subset that would constitute an escape (must be empty)
  """

  alias TinyLasers.Gate.{Codegen, Runtime}

  @cap_fns %{
    "print" => &Runtime.cap_print/2,
    "fs_read" => &Runtime.cap_fs_read/2,
    "fs_write" => &Runtime.cap_fs_write/2,
    "eval" => &Runtime.cap_eval/2
  }

  # The ONLY external module a confined guest may call.
  @allowed_modules MapSet.new([TinyLasers.Gate.Runtime])

  # ── PRE-COMPILE window (audit_quoted/1) ──
  # dangerous_refs/1 inspects the OUTPUT bytecode, but `Code.compile_quoted` expands macros and evaluates the
  # module body BEFORE that output exists — a compile-time-execution window the output check cannot see. The
  # lowered grammar is closed and tiny (verified empirically over the svelte + rollup bundles and a diverse
  # construct sweep): the module body is ONLY function definitions; every remote call targets the Runtime; the
  # only local call heads are compile-time-safe Kernel special-forms/operators. None is a code-executing macro
  # (`eval`/`apply`/`use`/`import`/`require`/`quote`/`@attr`), so nothing runs at compile time except the
  # deterministic expansion of these safe forms. This gate asserts that invariant FAIL-CLOSED: any head outside
  # the allowlist, any module attribute, any non-Runtime remote target, or any `unquote` leak rejects the AST
  # before it reaches the compiler.
  @safe_local_heads MapSet.new([:-, :"->", :., :=, :__block__, :case, :cond, :def, :defp, :fn, :if, :in, :not, :try, :{}])

  # module names permitted as a remote-call target in the guest AST (same confined surface as @allowed_modules).
  @allowed_ast_modules @allowed_modules

  # BIFs that, if present in guest bytecode, would be an escape or a DoS primitive.
  @danger_bifs MapSet.new([
                 :apply,
                 :binary_to_atom,
                 :binary_to_existing_atom,
                 :list_to_atom,
                 :list_to_existing_atom,
                 :binary_to_term,
                 :spawn,
                 :spawn_link,
                 :spawn_opt,
                 :open_port,
                 :halt,
                 :processes,
                 :register,
                 :whereis,
                 :send,
                 :load_module
               ])

  @doc "Compile a guest AST, granting exactly `granted_names` (least privilege)."
  def compile(ast, granted_names) when is_list(granted_names) do
    granted = granted_names |> Enum.with_index() |> Map.new()

    caps =
      granted_names
      |> Enum.with_index()
      |> Map.new(fn {name, id} ->
        {id, %{name: name, fun: Map.fetch!(@cap_fns, name)}}
      end)

    modname = Module.concat(TinyLasers.Gate.Compiled, "G#{System.unique_integer([:positive])}")
    quoted = Codegen.module(modname, ast, granted)
    # pre-compile confinement audit (compile-time-execution window) before the compiler runs.
    assert_safe_to_compile!(quoted)
    [{mod, bin}] = Code.compile_quoted(quoted)
    %{module: mod, binary: bin, granted: granted, caps: caps}
  end

  @doc "Run in-process. Returns %{result, output, fs_writes}. A guest throw is caught as a guest error."
  def run(compiled, opts \\ []) do
    ctx = %{
      caps: compiled.caps,
      granted: compiled.granted,
      tenant_root: Keyword.get(opts, :tenant_root, "/work"),
      fs: Keyword.get(opts, :fs, %{})
    }

    Runtime.__init(ctx)

    result =
      try do
        {:ok, apply(compiled.module, :run, [])}
      catch
        :throw, {:gg_guest_error, reason} -> {:guest_error, reason}
      end

    %{
      result: result,
      output: Runtime.__output(),
      fs_writes: Process.get(:gg_fs_writes, []) |> Enum.reverse()
    }
  end

  # host-safe defaults for bounding guest execution. 512 MB heap is generous for real bundles (rollup/linkedom
  # runs sit well under it) yet far below host RAM, so an allocating runaway is KILLED long before it can OOM the
  # machine. 30 s wall-clock kills a spinning (non-allocating) loop. Both are overridable per run.
  @default_max_heap_words 67_108_864
  @default_run_timeout 30_000

  @doc """
  THE mandatory way to execute guest code: run `fun` (0-arity) in an isolated process bounded by BOTH
  `max_heap_size{kill}` AND a wall-clock timeout, monitored. A guest that loops or allocates forever is killed —
  it **cannot** exhaust the host. Never `apply` a compiled guest module directly in a host-critical process;
  route it through here (or `run_isolated`).

  `fun` runs in the child, so it must do everything guest-side (init runtime, register sibling modules, apply
  the guest, capture `Runtime.__output()`) and RETURN what the caller needs — the child's process state is not
  visible to the parent. Returns `{:completed, fun_result} | {:timeout} | {:killed, :max_heap_size} | {:down, reason}`.
  """
  def bounded(fun, opts \\ []) when is_function(fun, 0) do
    parent = self()
    ref = make_ref()
    max_heap = Keyword.get(opts, :max_heap_size, @default_max_heap_words)
    timeout = Keyword.get(opts, :timeout, @default_run_timeout)

    {pid, mon} =
      :erlang.spawn_opt(
        fn -> send(parent, {ref, fun.()}) end,
        [
          :monitor,
          # include_shared_binaries (OTP 27+): count OFF-HEAP refc binaries toward the limit. Without it a guest
          # that builds large strings (`"x".repeat(1e5)` in a loop — big binaries live off-heap) would evade the
          # heap kill and OOM the host before the wall-clock timeout. THIS closes the binary-bomb vector.
          {:max_heap_size, %{size: max_heap, kill: true, error_logger: false, include_shared_binaries: true}},
          {:message_queue_data, :off_heap}
        ]
      )

    receive do
      {^ref, res} ->
        Process.demonitor(mon, [:flush])
        {:completed, res}

      {:DOWN, ^mon, :process, ^pid, :killed} ->
        {:killed, :max_heap_size}

      {:DOWN, ^mon, :process, ^pid, reason} ->
        {:down, reason}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^mon, :process, ^pid, _} -> :ok
        after
          200 -> :ok
        end

        {:timeout}
    end
  end

  @doc """
  Run a single compiled guest module in a bounded isolated process (see `bounded/2`).
  Returns {:completed, %{result, output, fs_writes}} | {:timeout} | {:killed, reason} | {:down, reason}.
  """
  def run_isolated(compiled, opts \\ []), do: bounded(fn -> run(compiled, opts) end, opts)

  @doc """
  Run a compiled F2 guest (a `main` module plus zero or more `sibling` modules from the multi-module explode
  path) in a BOUNDED isolated process, returning `{status, output_lines}` where status is
  `:completed | :timeout | {:killed, reason} | {:down, reason}`. Registers the siblings and applies `main.run`
  in the child (Runtime state is per-process), drains microtasks, and returns `Runtime.__output()`.

  This is what every harness/test MUST use instead of `apply(mod, :run, [])` — a guest that loops or allocates
  forever is killed, never the host. `ctx` is the `Runtime.__init` context (caps/fs/tenant_root).
  """
  def bounded_run(main_mod, sibling_mods, ctx, opts \\ []) do
    res =
      bounded(
        fn ->
          Runtime.__init(ctx)
          Enum.each(sibling_mods, fn m -> apply(m, :__gg_register, []) end)
          try do
            apply(main_mod, :run, [])
            Runtime.drain_microtasks()
          catch
            :throw, _ -> :ok
          end
          Runtime.__output()
        end,
        opts
      )

    case res do
      {:completed, output} -> {:completed, output}
      other -> other
    end
  end

  # ── structural inspector: what does the emitted NATIVE bytecode actually reference? ──

  @doc "All external {module, fun, arity} calls and BIF names in the compiled guest."
  def refs(%{binary: bin}), do: refs(bin)

  def refs(bin) when is_binary(bin) do
    {:beam_file, _mod, _exp, _attr, _ci, fns} = :beam_disasm.file(bin)

    # Scope the scan to guest-AUTHORED functions. Every Elixir module gets compiler-
    # generated reflection (`module_info/0,1`, `__info__/1`) that calls
    # `:erlang.get_module_info` — boilerplate present in all modules, not guest-emitted
    # and not guest-reachable. Excluding it keeps the structural claim about the guest's
    # own code, which is what confinement is about.
    code =
      fns
      |> Enum.reject(fn {:function, name, _a, _e, _c} -> name in [:module_info, :__info__] end)
      |> Enum.flat_map(fn {:function, _n, _a, _e, c} -> c end)

    %{ext: collect_ext(code) |> Enum.uniq(), bifs: collect_bifs(code) |> Enum.uniq()}
  end

  @doc """
  The subset of refs that would be an escape: any external module other than the
  confined Runtime, or any dangerous BIF. For a properly confined guest this is empty.
  """
  def dangerous_refs(arg) do
    %{ext: ext, bifs: bifs} = refs(arg)
    bad_ext = Enum.reject(ext, fn {m, _f, _a} -> MapSet.member?(@allowed_modules, m) end)
    bad_bifs = Enum.filter(bifs, &MapSet.member?(@danger_bifs, &1))
    %{ext: bad_ext, bifs: bad_bifs}
  end

  @doc """
  Audit a QUOTED guest module BEFORE `Code.compile_quoted` — the compile-time-execution window that
  `dangerous_refs/1` (which reads the *output* bytecode) cannot see. Returns a report map; a confined guest
  has every field empty:

    * `modbody_nondef` — module-body forms other than `def`/`defp` (a top-level statement or attribute would
      run at compile time).
    * `attrs` — `@attribute` nodes (module attributes evaluate at compile time).
    * `unquote` — stray `unquote`/`unquote_splicing` (a splicing leak / malformed AST).
    * `bad_remote` — remote calls to any module other than the confined Runtime.
    * `bad_local` — local call heads outside the safe Kernel special-form/operator set (a code-executing macro
      would appear here).

  Walks EVERY node via `Macro.prewalk`, so no construct hides. Fail-closed: an unknown shape is a violation.
  """
  def audit_quoted(quoted) do
    # 1) the module wrapper is FIXED structure (defmodule + name alias + a body of only def/defp). Classify the
    #    body forms: def/defp are the guest code; a module attribute evaluates at compile time (→ attrs); any
    #    other top-level form runs at compile time (→ modbody_nondef).
    {modbody_nondef, modattrs, defs} =
      case quoted do
        {:defmodule, _, [_name, [do: body]]} ->
          forms = case body do {:__block__, _, ss} -> ss; one -> [one] end

          Enum.reduce(forms, {[], [], []}, fn form, {nd, at, df} ->
            case form do
              {d, _, _} when d in [:def, :defp] -> {nd, at, [form | df]}
              {:@, _, _} = a -> {nd, [Macro.to_string(a) |> String.slice(0, 60) | at], df}
              {other, _, _} -> {[other | nd], at, df}
              other -> {[inspect(other) |> String.slice(0, 40) | nd], at, df}
            end
          end)

        _ ->
          {[:not_a_defmodule], [], []}
      end

    # 2) walk ONLY the def bodies (not the fixed wrapper), visiting every node — a code-executing head,
    #    non-Runtime remote, stray attribute, or unquote anywhere inside is a violation.
    init = %{attrs: modattrs, unquote: [], bad_remote: [], bad_local: []}

    viol =
      Enum.reduce(defs, init, fn {_d, _, def_args}, acc ->
        {_, acc2} = Macro.prewalk(def_body(def_args), acc, fn node, a -> {node, audit_node(node, a)} end)
        acc2
      end)

    Map.put(viol, :modbody_nondef, modbody_nondef)
  end

  # the do-block body of a `def`/`defp` (the head + guards are fixed structure).
  defp def_body(def_args) do
    case List.last(def_args) do
      kw when is_list(kw) -> Keyword.get(kw, :do, kw)
      other -> other
    end
  end

  @doc "True iff `audit_quoted/1` finds no compile-time-execution risk — the guest AST is safe to compile."
  def safe_to_compile?(quoted) do
    r = audit_quoted(quoted)
    r.modbody_nondef == [] and r.attrs == [] and r.unquote == [] and r.bad_remote == [] and r.bad_local == []
  end

  @doc "Raise unless the quoted guest is safe to compile. The pre-compile complement to `dangerous_refs/1`."
  def assert_safe_to_compile!(quoted) do
    unless safe_to_compile?(quoted) do
      raise ArgumentError, "guest AST failed pre-compile confinement audit: #{inspect(audit_quoted(quoted))}"
    end

    quoted
  end

  defp audit_node({:@, _, _} = a, acc), do: %{acc | attrs: [Macro.to_string(a) |> String.slice(0, 60) | acc.attrs]}
  defp audit_node({:unquote, _, _}, acc), do: %{acc | unquote: [:unquote | acc.unquote]}
  defp audit_node({:unquote_splicing, _, _}, acc), do: %{acc | unquote: [:unquote_splicing | acc.unquote]}

  # a remote call's inner dot `mod.fun` (two elements, fun an atom): the module must be the confined Runtime.
  defp audit_node({:., _, [modast, fun]}, acc) when is_atom(fun) do
    case resolve_mod(modast) do
      {:ok, m} -> if MapSet.member?(@allowed_ast_modules, m), do: acc, else: %{acc | bad_remote: [{m, fun} | acc.bad_remote]}
      :dynamic -> %{acc | bad_remote: [{:dynamic_module, fun} | acc.bad_remote]}
    end
  end

  # a local call `head(args)` — the head must be a compile-time-safe special form / operator.
  defp audit_node({head, _, args}, acc) when is_atom(head) and is_list(args) do
    if MapSet.member?(@safe_local_heads, head), do: acc, else: %{acc | bad_local: [head | acc.bad_local]}
  end

  defp audit_node(_node, acc), do: acc

  defp resolve_mod({:__aliases__, _, parts}) when is_list(parts), do: {:ok, Module.concat(parts)}
  defp resolve_mod(m) when is_atom(m), do: {:ok, m}
  defp resolve_mod(_), do: :dynamic

  # deep-walk the disasm term collecting every {:extfunc, m, f, a}
  defp collect_ext(term) do
    cond do
      match?({:extfunc, _, _, _}, term) ->
        {:extfunc, m, f, a} = term
        [{m, f, a}]

      is_tuple(term) ->
        term |> Tuple.to_list() |> Enum.flat_map(&collect_ext/1)

      is_list(term) ->
        Enum.flat_map(term, &collect_ext/1)

      true ->
        []
    end
  end

  # BIFs appear as instruction tuples headed by :bif* / :gc_bif*, name in position 2
  @bif_heads MapSet.new([:bif, :bif0, :bif1, :bif2, :gc_bif, :gc_bif1, :gc_bif2, :gc_bif3])
  defp collect_bifs(code) do
    Enum.flat_map(code, fn
      instr when is_tuple(instr) and tuple_size(instr) >= 2 ->
        head = elem(instr, 0)
        if MapSet.member?(@bif_heads, head), do: [elem(instr, 1)], else: []

      _ ->
        []
    end)
  end
end
