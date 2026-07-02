defmodule TinyLasers.Gate.Js do
  @moduledoc """
  **F2 vertical: JS source → BEAM-native, behind the capability gate.**

  `parse` (acorn, the reused Porffor parser dep — H3) → `TinyLasers.Gate.Lower` (ESTree → Elixir quoted,
  direct-term objects — H1) → `Code.compile_quoted` → a real `.beam` module → `run/0`. Confinement (H2) is
  structural: the emitted module references only `TinyLasers.Gate.Runtime`; verify with
  `TinyLasers.Gate.dangerous_refs/1` on the returned binary.

  This is a spike frontend covering the core language (see `Lower`), not a full JS engine — enough to prove
  real parsed JS runs BEAM-native with GC where the WASM hybrid hits the memory wall.
  """

  alias TinyLasers.Gate.{Lower, Runtime}

  @parser Path.expand("../../../compilers/js/porffor/gate_parse.cjs", __DIR__)

  @doc "Parse JS source to an ESTree AST (decoded map). Raises on parse error."
  def parse(src) when is_binary(src) do
    tmp = Path.join(System.tmp_dir!(), "gate_#{System.unique_integer([:positive])}.js")
    File.write!(tmp, src)

    try do
      case System.cmd("node", [@parser, tmp], stderr_to_stdout: false) do
        {json, 0} -> TinyLasers.Wasm.Json.decode!(json)
        {_out, _} -> raise "parse failed"
      end
    after
      File.rm(tmp)
    end
  end

  @doc """
  Compile JS source to a native BEAM module and run it. Returns `%{result, binary, mod}`.
  `opts[:caps]` is a map of granted host capabilities (default: just `print`).
  """
  def run(src, opts \\ []) when is_binary(src) do
    ast = parse(src)
    caps = Keyword.get(opts, :caps, default_caps())
    granted = Keyword.get(opts, :granted, default_granted())
    body = Lower.program(ast, granted)
    modname = Module.concat([TinyLasers.Gate.Guest, "M#{System.unique_integer([:positive])}"])

    quoted =
      quote do
        defmodule unquote(modname) do
          def run, do: unquote(body)
        end
      end

    # PRE-COMPILE confinement gate: prove no code can execute during `Code.compile_quoted` (macro expansion /
    # module-body evaluation) — the window the post-compile `dangerous_refs/1` cannot see. Fail-closed.
    TinyLasers.Gate.assert_safe_to_compile!(quoted)
    [{mod, bin}] = Code.compile_quoted(quoted)

    ctx = %{caps: caps, tenant_root: "/tenant", fs: %{}}

    # Execute in a MEMORY- and TIME-bounded isolated process. A guest that allocates or loops forever is killed
    # (max_heap_size{kill} / wall-clock) — it can NEVER exhaust the host. Compilation already happened above (a
    # finite, host-controlled step); only the arbitrary guest RUN is sandboxed here.
    bounded =
      TinyLasers.Gate.bounded(
        fn ->
          Runtime.__init(ctx)

          res =
            try do
              r = {:ok, apply(mod, :run, [])}
              Runtime.drain_microtasks()
              r
            catch
              # an uncaught guest `throw` (incl. a TypeError from null/undefined access) is a GUEST error, not a
              # host crash — the thrown value never escaped the confined term domain.
              :throw, {:gg_throw, v} -> {:guest_error, v}
              :throw, {:gg_guest_error, r} -> {:guest_error, r}
              :throw, {:gg_return, v} -> {:ok, v}
              kind, e -> {:crash, kind, e}
            end

          {res, Runtime.__output()}
        end,
        max_heap_size: Keyword.get(opts, :max_heap_size, 67_108_864),
        timeout: Keyword.get(opts, :timeout, 10_000)
      )

    case bounded do
      {:completed, {res, output}} -> %{result: res, output: output, binary: bin, mod: mod}
      {:timeout} -> %{result: {:timeout, nil}, output: [], binary: bin, mod: mod}
      {:killed, reason} -> %{result: {:resource_killed, reason}, output: [], binary: bin, mod: mod}
      {:down, reason} -> %{result: {:crash, :down, reason}, output: [], binary: bin, mod: mod}
    end
  end

  defp default_caps do
    %{0 => %{fun: &Runtime.cap_print/2}}
  end

  defp default_granted, do: %{"print" => 0}
end
