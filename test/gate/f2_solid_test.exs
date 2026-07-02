defmodule TinyLasers.Gate.F2SolidTest do
  @moduledoc """
  **F2 rung: real SolidJS SSR renders byte-identical to node, BOTH lanes, confined — a SECOND framework, a
  DIFFERENT reactivity model.**

  Where Preact proves the React-family VDOM model, this proves SolidJS 1.9.14's FINE-GRAINED reactive model:
  a JSX component (createSignal / createMemo / `<For>` / `<Show>`) compiled by `babel-preset-solid`
  (`generate: "ssr"`) to Solid's `ssr`/`createComponent`/`escape` runtime calls, bundled with `solid-js/web`,
  server-rendered via `renderToString` — byte-identical to the golden captured from real Solid under node, in
  both frontends (`Walk` interpreter + `Lower` compiled `.beam`, confined).

  The "different reactivity model finds a different bug class" prediction held: Solid pulls in `seroval` (its
  serialization lib), which serializes functions by `Function.prototype.toString()` SOURCE — something F2's
  compile-to-BEAM fundamentally cannot reproduce. But with `hydratable: false` that serialization is init-only
  and never reaches the render output (verified: the render is identical whether those calls resolve or no-op),
  so a placeholder `fn.toString()` + a microtask-deferred `setTimeout` (Solid schedules root disposal via
  `setTimeout(dispose)`) are enough for byte-identical SSR.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  @conf "test/conformance"

  defp extract(out) do
    line =
      Enum.find(out, &String.starts_with?(&1, "SOLID_OK[")) ||
        flunk("no SOLID_OK output; got #{inspect(Enum.map(out, &String.slice(&1, 0, 50)) |> Enum.take(5))}")

    line |> String.replace_prefix("SOLID_OK[", "") |> String.replace_suffix("]", "")
  end

  @tag timeout: 600_000
  test "SolidJS server-renders a signals/For/Show component byte-identical to node, both lanes, confined" do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js")) <> "\n" <> File.read!(Path.join(@conf, "rollup/node_shims.js"))
    console = "var console = { log: function(){ print(arguments[0]); } };\n"
    bundle = File.read!(Path.join(@conf, "solid/solid_bundle.js"))
    golden = File.read!(Path.join(@conf, "solid/solid_golden.html")) |> String.trim()
    ast = Js.parse(console <> prelude <> "\n" <> bundle)

    # ── interpreter lane ──
    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
    walk_out = try do Walk.run(ast, %{"print" => 0}); Runtime.drain_microtasks(); Runtime.__output() catch :throw, _ -> Runtime.__output() end
    assert String.trim(extract(walk_out)) == golden, "interpreter Solid render diverged from node golden"

    # ── compiled lane: confined + byte-identical ──
    body = Lower.program(ast, %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "Solid#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "compiled Solid module not confined"

    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
    try do apply(m, :run, []); Runtime.drain_microtasks() catch :throw, _ -> :ok end
    assert String.trim(extract(Runtime.__output())) == golden, "compiled lane Solid render diverged from node golden"
  end
end
