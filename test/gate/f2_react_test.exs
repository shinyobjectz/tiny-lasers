defmodule TinyLasers.Gate.F2ReactTest do
  @moduledoc """
  **F2 rung: real React 18 SSR renders byte-identical to node, BOTH lanes, confined.**

  The actual `react` 18 + `react-dom/server` (`renderToString`, esbuild-bundled to a single 571KB production
  script — `test/conformance/react/driver.js` is the source) runs BEAM-native and server-renders a component
  tree compared BYTE-FOR-BYTE to the golden captured from real React under node — including React's
  `<!-- -->` text separators. The component exercises the SSR surface: function components + props/children,
  `useState`/`useReducer`/`useMemo`/`useContext`, `createContext` + `Provider` (value threads through
  `useContext`), `memo`, style objects (camelCase → kebab), boolean/aria/data attributes, `hidden`,
  `dangerouslySetInnerHTML`, keys, and mixed null/false/0/undefined children.

    * INTERPRETER (`Walk`): byte-identical to the golden.
    * COMPILED (`Lower` → native `.beam`, ~8s): byte-identical AND confined (`dangerous_refs == %{ext: [], bifs: []}`).

  Passed on the FIRST attempt with zero runtime changes — the preact/svelte/solid work generalized. Together
  with `f2_preact_test.exs` this locks the React-family pair: F2 runs the two dominant SSR runtimes
  untrusted, BEAM-native, without a JS engine.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  @conf "test/conformance"

  defp extract(out) do
    line =
      Enum.find(out, &String.starts_with?(&1, "REACT_OK[")) ||
        flunk("no REACT_OK output; got #{inspect(Enum.map(out, &String.slice(&1, 0, 50)) |> Enum.take(5))}")

    line |> String.replace_prefix("REACT_OK[", "") |> String.replace_suffix("]", "")
  end

  @tag timeout: 600_000
  test "react 18 server-renders hooks+context+memo byte-identical to node, both lanes, confined" do
    bundle = File.read!(Path.join(@conf, "react/react_bundle.js"))
    golden = File.read!(Path.join(@conf, "react/react_golden.html")) |> String.trim()
    ast = Js.parse(bundle)

    # ── interpreter lane (BOUNDED: memory + wall-clock; a runaway guest is killed, never the test host) ──
    ctx = %{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}}

    {:completed, walk_out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(ctx)
        try do Walk.run(ast, %{"print" => 0}) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 120_000, max_heap_size: 536_870_912)

    assert String.trim(extract(walk_out)) == golden, "interpreter React render diverged from node golden"

    # ── compiled lane: confined + byte-identical ──
    body = Lower.program(ast, %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "React#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "compiled React module not confined"

    {:completed, lower_out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(ctx)
        try do apply(m, :run, []) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 120_000, max_heap_size: 536_870_912)

    assert String.trim(extract(lower_out)) == golden, "compiled React render diverged from node golden"
  end
end
