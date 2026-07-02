defmodule TinyLasers.Gate.F2AppPipelineTest do
  @moduledoc """
  **F2 CAPSTONE: a real multi-component app is BUILT and SERVER-RENDERED entirely on F2, byte-identical to node.**

  The full build+SSR pipeline for a real app, both stages BEAM-native and confined:

    * STAGE 1 — BUILD: real rollup@4.62.2 bundles a 6-module Preact app (`entry` → `App` → `Header`/`CardList`/
      `Card`/`Footer`, `preact` external) into one CJS module. Byte-identical to native rollup, both lanes,
      every compiled module confined. This is the build lane (Phase 3) on REAL app code.

    * STAGE 2 — SSR: that built app is server-rendered with `preact-render-to-string` to HTML. Byte-identical to
      node, both lanes, confined. This is the real-app render (Phase 4).

  Together: source modules → F2/rollup → bundle → F2/preact → HTML, every step byte-identical to the node
  toolchain. F2 replaces the WHOLE build+runtime stack for a real app, with no WASM engine-in-engine tax.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate
  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  @conf "test/conformance"

  defp extract(out, marker) do
    line =
      Enum.find(out, &String.starts_with?(&1, marker <> "[")) ||
        flunk("no #{marker}; got #{inspect(Enum.map(out, &String.slice(&1, 0, 40)) |> Enum.take(4))}")

    line |> String.replace_prefix(marker <> "[", "") |> String.replace_suffix("]", "") |> String.trim()
  end

  @tag timeout: 600_000
  test "STAGE 1 — F2/rollup builds the real app byte-identical to native rollup, both lanes, confined" do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js")) <> "\n" <> File.read!(Path.join(@conf, "rollup/node_shims.js"))
    bundle = File.read!(Path.join(@conf, "rollup/rollup_bundle.cjs"))
    driver = File.read!(Path.join(@conf, "app/build_driver.js"))
    golden = File.read!(Path.join(@conf, "app/build_golden.txt")) |> String.trim()
    ast = Js.parse(prelude <> "\n" <> bundle <> "\n" <> driver)
    granted = %{"print" => 0, "__host" => 1}
    caps = %{caps: %{0 => %{fun: &Runtime.cap_print/2}, 1 => %{fun: &Runtime.host_rollup_bridge/2}}, tenant_root: "/t", fs: %{}}

    # interpreter — BOUNDED (memory + wall-clock capped; a runaway guest is killed, never the test host)
    {:completed, walk_out} =
      Gate.bounded(fn ->
        Runtime.__init(caps)
        try do Walk.run(ast, granted); Runtime.drain_microtasks() catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 180_000, max_heap_size: 268_435_456)

    assert extract(walk_out, "APP_BUILD_OK") == golden, "interpreter build diverged from native rollup"

    # compiled: parallel multi-module (the 1.27MB bundle), every module confined
    nmods = System.schedulers_online()
    %{main: mainq, siblings: sibqs} = Lower.modules_quoted(ast, granted, modules: nmods)
    uid = System.unique_integer([:positive])

    mods =
      [{:main, mainq} | Enum.with_index(sibqs) |> Enum.map(fn {q, i} -> {:"sib#{i}", q} end)]
      |> Task.async_stream(fn {tag, q} ->
        mod = Module.concat([TinyLasers.Gate.Guest, "AppBuild#{uid}#{tag}"])
        [{m, bin} | _] = Code.compile_quoted(quote do (defmodule unquote(mod) do unquote(q) end) end)
        {tag, m, bin}
      end, timeout: 600_000, max_concurrency: nmods)
      |> Enum.map(fn {:ok, r} -> r end)

    for {tag, _, bin} <- mods, do: assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "module #{tag} not confined"

    {:main, main, _} = List.keyfind(mods, :main, 0)
    sibs = for {tag, m, _} <- mods, tag != :main, do: m
    {:completed, build_out} = Gate.bounded_run(main, sibs, caps, timeout: 180_000, max_heap_size: 268_435_456)
    assert extract(build_out, "APP_BUILD_OK") == golden, "compiled build diverged from native rollup"
  end

  @tag timeout: 600_000
  test "STAGE 2 — F2/preact server-renders the built app byte-identical to node, both lanes, confined" do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js")) <> "\n" <> File.read!(Path.join(@conf, "rollup/node_shims.js"))
    console = "var console = { log: function(){ print(arguments[0]); } };\n"
    ssr = File.read!(Path.join(@conf, "app/ssr_bundle.js"))
    golden = File.read!(Path.join(@conf, "app/ssr_golden.html")) |> String.trim()
    ast = Js.parse(console <> prelude <> "\n" <> ssr)

    ssr_ctx = %{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}}

    {:completed, walk_out} =
      Gate.bounded(fn ->
        Runtime.__init(ssr_ctx)
        try do Walk.run(ast, %{"print" => 0}); Runtime.drain_microtasks() catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 120_000, max_heap_size: 134_217_728)

    assert extract(walk_out, "APP_SSR_OK") == golden, "interpreter SSR diverged from node"

    body = Lower.program(ast, %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "AppSSR#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "compiled SSR module not confined"

    {:completed, ssr_out} = Gate.bounded_run(m, [], ssr_ctx, timeout: 120_000, max_heap_size: 134_217_728)
    assert extract(ssr_out, "APP_SSR_OK") == golden, "compiled SSR diverged from node"
  end
end
