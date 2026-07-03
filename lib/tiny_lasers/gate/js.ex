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

    Map.merge(bounded_run(mod, caps, opts), %{binary: bin, mod: mod})
  end

  @doc """
  **Warm-module / cold-process invocation — the production execution model (Track A / J3).**

  Resolves `src` (for `tenant`) to a compiled module via the per-tenant `ModuleCache`, compiling ONCE per
  distinct {tenant, source, grants} and reusing it across requests (bounds the permanent atom mint — see
  `f2-execution-model`), then runs it in a FRESH resource-bounded process so the per-request object store dies
  with the process (flat memory across requests — see `f2-object-store-leak`). The invocation is bracketed with
  `checkout`/`checkin` for purge safety. Isolation is per-tenant: the cache key folds in `granted`, and the
  module name derives from `sha256(tenant <> source <> grants)` — no cross-tenant sharing.

  Requires the `ModuleCache` GenServer to be running (start it in your supervision tree, or pass `:cache`).
  Returns `%{result, output, mod}`; `%{result: {:compile_cap, tenant}}` if the tenant hit its distinct-program
  ceiling (atom-DoS guard).
  """
  def invoke(tenant, src, opts \\ []) when is_binary(tenant) and is_binary(src) do
    cache = Keyword.get(opts, :cache, TinyLasers.Gate.ModuleCache)
    caps = Keyword.get(opts, :caps, default_caps())
    granted = Keyword.get(opts, :granted, default_granted())
    # fold the grants into the cache key: the same source with different capabilities compiles to a DIFFERENT
    # module (grants change which identifiers resolve to host caps), so they must not share a cache entry.
    key_source = src <> <<0>> <> :erlang.term_to_binary(granted)

    compile_fun = fn modname ->
      body = Lower.program(parse(src), granted)
      quoted = quote do (defmodule unquote(modname) do def run, do: unquote(body) end) end
      TinyLasers.Gate.assert_safe_to_compile!(quoted)
      [{mod, bin}] = Code.compile_quoted(quoted)
      {mod, bin}
    end

    case TinyLasers.Gate.ModuleCache.resolve(tenant, key_source, compile_fun, cache) do
      {:error, :compile_cap} ->
        %{result: {:compile_cap, tenant}, output: [], mod: nil}

      {:ok, mod} ->
        TinyLasers.Gate.ModuleCache.with_module(mod, fn -> Map.put(bounded_run(mod, caps, opts), :mod, mod) end)
    end
  end

  # Run a compiled guest module in a MEMORY- and TIME-bounded isolated process. A guest that allocates or loops
  # forever is killed (max_heap_size{kill} / wall-clock) — it can NEVER exhaust the host. Compilation already
  # happened (a finite, host-controlled step); only the arbitrary guest RUN is sandboxed here.
  defp bounded_run(mod, caps, opts) do
    ctx = %{caps: caps, tenant_root: "/tenant", fs: %{}}

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
      {:completed, {res, output}} -> %{result: res, output: output}
      {:timeout} -> %{result: {:timeout, nil}, output: []}
      {:killed, reason} -> %{result: {:resource_killed, reason}, output: []}
      {:down, reason} -> %{result: {:crash, :down, reason}, output: []}
    end
  end

  defp default_caps do
    %{0 => %{fun: &Runtime.cap_print/2}}
  end

  defp default_granted, do: %{"print" => 0}
end
