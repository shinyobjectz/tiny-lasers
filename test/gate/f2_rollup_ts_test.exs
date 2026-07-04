defmodule TinyLasers.Gate.F2RollupTsTest do
  @moduledoc """
  **TypeScript Layer 3: rollup bundles a MULTI-FILE TypeScript project through a sucrase transform plugin,
  BEAM-native, byte-identical to node, confined.**

  This composes the two proven engines — rollup 4.62.2 (`rollup_bundle.cjs`, its Rust→wasm parser behind the
  confined `__host` bridge) and the sucrase transpiler (`sucrase_iife.js`, exposed as the `SUCRASE` global) —
  into the real Layer-3 pipeline. A 4-module `.ts` project (`entry → lib → util`, plus `meta`) is bundled by
  `rollup.rollup({ input: "entry.ts", plugins: [tsPlugin], treeshake: true })`, where `tsPlugin` does:

    * `.ts` extension resolution (`./lib` → `lib.ts`),
    * per-module `transform(code, id)` → `SUCRASE.transform(code, {transforms:['typescript']})` (type stripping),
    * feeds the stripped JS back into rollup's module graph.

  The output exercises cross-module treeshaking (dead `neverUsed`/`alsoDead` exports vanish), scope hoisting
  into one chunk in dependency order, `const enum` lowering, and type erasure — compared BYTE-FOR-BYTE to the
  golden captured from the identical rollup+sucrase pipeline under node (`goldengen` = `ts_multi_golden.js`).

  Together with `f2_sucrase_ts_test.exs` (Layer 1: transpile) this proves author-multi-file-TS → bundle →
  ready-to-run, entirely BEAM-native and confined — the in-sandbox TypeScript project story.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime}

  @conf "test/conformance"

  @tag timeout: 600_000
  test "rollup + sucrase bundle a multi-file TS project byte-identical to node, confined" do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js")) <> "\n" <> File.read!(Path.join(@conf, "rollup/node_shims.js"))
    console = "var console = { log: function(){ print(arguments[0]); } };\n"
    bundle = File.read!(Path.join(@conf, "rollup/rollup_bundle.cjs"))
    sucrase = File.read!(Path.join(@conf, "rollup/sucrase_iife.js"))
    driver = File.read!(Path.join(@conf, "rollup/ts_multi_driver.js"))

    src = console <> prelude <> bundle <> "\n" <> sucrase <> "\n" <> driver
    nmods = System.schedulers_online()

    %{main: mainq, siblings: sibqs} =
      Lower.modules_quoted(Js.parse(src), %{"print" => 0, "__host" => 1}, modules: nmods)

    uid = System.unique_integer([:positive])

    mods =
      [{:main, mainq} | Enum.with_index(sibqs) |> Enum.map(fn {q, i} -> {:"sib#{i}", q} end)]
      |> Task.async_stream(
        fn {tag, q} ->
          mod = Module.concat([TinyLasers.Gate.Guest, "RollupTs#{uid}#{tag}"])
          [{m, bin} | _] = Code.compile_quoted(quote do (defmodule unquote(mod) do unquote(q) end) end)
          {tag, m, bin}
        end,
        timeout: 600_000,
        max_concurrency: nmods
      )
      |> Enum.map(fn {:ok, r} -> r end)

    # the full rollup+sucrase engine references ONLY the Runtime (wasm parser is a granted cap handle).
    for {tag, _, bin} <- mods do
      assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "module #{tag} not confined"
    end

    {:main, main, _} = List.keyfind(mods, :main, 0)
    sibs = for {tag, m, _} <- mods, tag != :main, do: m
    ctx = %{caps: %{0 => %{fun: &Runtime.cap_print/2}, 1 => %{fun: &Runtime.host_rollup_bridge/2}}, tenant_root: "/t", fs: %{}}

    {:completed, out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(ctx)
        Enum.each(sibs, fn s -> apply(s, :__gg_register, []) end)
        try do apply(main, :run, []) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 300_000, max_heap_size: 536_870_912)

    ok_line =
      Enum.find(out, &String.starts_with?(&1, "TSBUNDLE_OK[")) ||
        flunk("no TSBUNDLE_OK; output=#{inspect(Enum.map(out, &String.slice(&1, 0, 60)) |> Enum.take(8))}")

    code = ok_line |> String.replace_prefix("TSBUNDLE_OK[", "") |> String.replace_suffix("]", "") |> String.trim()
    golden = File.read!(Path.join(@conf, "rollup/ts_multi_golden.js")) |> String.trim()

    assert code == golden, "multi-file TS bundle diverged from node golden:\n  got=#{inspect(code)}\n  want=#{inspect(golden)}"
  end
end
