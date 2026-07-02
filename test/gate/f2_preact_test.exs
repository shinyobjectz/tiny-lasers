defmodule TinyLasers.Gate.F2PreactTest do
  @moduledoc """
  **F2 rung: real Preact SSR renders byte-identical to node, BOTH lanes, confined — F2 replaces StarlingMonkey.**

  The actual `preact` 10.29.3 + `preact-render-to-string` 6.7.0 runtime (esbuild-bundled to a single 41KB
  script) runs BEAM-native and server-renders a component to an HTML string, compared BYTE-FOR-BYTE to the
  golden captured from real Preact under node. The component exercises the React-family SSR surface: functional
  components + props + children, `useState`/`useReducer`/`useMemo`/`useContext` hooks, `createContext` +
  `Provider`, `memo`, style objects, boolean/aria/data attributes, `dangerouslySetInnerHTML`, keys, and mixed
  null/false/0/undefined children.

    * INTERPRETER (`Walk`): byte-identical to the golden.
    * COMPILED (`Lower` → native `.beam`): byte-identical AND confined (`dangerous_refs == %{ext: [], bifs: []}`).

  This is the flagship proof that F2 runs untrusted framework runtimes server-side, BEAM-native, without the
  WASM engine-in-engine tax. Getting here surfaced + fixed four real gaps: `Symbol.for` as a method,
  then/catch/finally truthiness breaking Promise duck-typing (preact-render-to-string mis-read a thrown error
  as suspense), Array.prototype methods as first-class values (`[].slice.call(arguments, 2)` in `h()`), and a
  Lower codegen bug — a nested member-target assignment `(l4.Consumer = fn).contextType = l4` (createContext)
  clobbered its own return value via a shared temp variable.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  @conf "test/conformance"

  defp extract(out) do
    line =
      Enum.find(out, &String.starts_with?(&1, "PREACT_OK[")) ||
        flunk("no PREACT_OK output; got #{inspect(Enum.map(out, &String.slice(&1, 0, 50)) |> Enum.take(5))}")

    line |> String.replace_prefix("PREACT_OK[", "") |> String.replace_suffix("]", "")
  end

  @tag timeout: 600_000
  test "preact server-renders a runes+hooks component byte-identical to node, both lanes, confined" do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js"))
    bundle = File.read!(Path.join(@conf, "preact/preact_bundle.js"))
    golden = File.read!(Path.join(@conf, "preact/preact_golden.html")) |> String.trim()
    ast = Js.parse(prelude <> "\n" <> bundle)

    # ── interpreter lane (BOUNDED: memory + wall-clock; a runaway guest is killed, never the test host) ──
    ctx = %{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}}

    {:completed, walk_out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(ctx)
        try do Walk.run(ast, %{"print" => 0}) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 120_000, max_heap_size: 134_217_728)

    assert String.trim(extract(walk_out)) == golden, "interpreter Preact render diverged from node golden"

    # ── compiled lane: confined + byte-identical ──
    body = Lower.program(ast, %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "Preact#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "compiled Preact module not confined"

    {:completed, out} = TinyLasers.Gate.bounded_run(m, [], ctx, timeout: 120_000, max_heap_size: 134_217_728)
    assert String.trim(extract(out)) == golden, "compiled lane Preact render diverged from node golden"
  end
end
