defmodule TinyLasers.Gate.F2SvelteTest do
  @moduledoc """
  **F2 rung: the real svelte 5 compiler compiles a component byte-identical to node, BOTH lanes, confined.**

  The svelte@5.56.4 compiler (esbuild-bundled to `svelte/svelte_bundle.cjs`, ~1.2MB) runs on the BEAM. It
  compiles a component exercising runes ($props with defaults, $state, an event handler that reassigns state,
  and an `{#each}` block) to CLIENT js, and the result is compared BYTE-FOR-BYTE to the golden captured from
  real svelte under node, in both frontends:

    * INTERPRETER (`Walk`): byte-identical to the golden.

    * COMPILED (`Lower` → native `.beam`, parallel multi-module): byte-identical to the golden AND every module
      is confined (`dangerous_refs == %{ext: [], bifs: []}`).

  Both drive the compiler's full pipeline — its bundled acorn (parse), scope/binding analysis + runes
  detection, the reactive transform (use-site `$.get`/`$.set` rewriting, prop getters, sibling navigation),
  and the esrap printer — proving the shared Runtime handles real svelte end to end. The template-node builder
  and multi-child sibling chain rely on named-function-expression self-recursion and per-invocation function
  declarations (svelte's `t()` walker and recursive `sP()`), which Lower binds via per-evaluation boxes.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  @conf "test/conformance"

  @tag timeout: 600_000
  test "svelte compiles a runes component byte-identical to the golden (interpreter), confined (compiled)" do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js")) <> "\n" <> File.read!(Path.join(@conf, "rollup/node_shims.js"))
    console = "var console = { log: function(){ print(arguments[0]); } };\n"
    bundle = File.read!(Path.join(@conf, "svelte/svelte_bundle.cjs"))
    src = console <> prelude <> bundle
    ast = Js.parse(src)
    golden = File.read!(Path.join(@conf, "svelte/svelte_golden.txt")) |> String.replace_prefix("5.56.4|", "")

    # ── interpreter lane: byte-identical ──
    walk_ctx = %{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}}

    {:completed, walk_out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(walk_ctx)
        try do Walk.run(ast, %{"print" => 0}) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 180_000, max_heap_size: 268_435_456)
    walk_ok = Enum.find(walk_out, &String.starts_with?(&1, "SVELTE_OK["))
    assert walk_ok, "interpreter produced no SVELTE_OK; out=#{inspect(Enum.take(walk_out, 4))}"
    walk_code = walk_ok |> String.replace_prefix("SVELTE_OK[", "") |> String.replace_prefix("5.56.4|", "") |> String.replace_suffix("]", "")
    assert String.trim(walk_code) == String.trim(golden), "interpreter svelte output mismatch"

    # ── compiled lane: parallel multi-module, every module confined ──
    nmods = System.schedulers_online()
    %{main: mainq, siblings: sibqs} = Lower.modules_quoted(ast, %{"print" => 0}, modules: nmods)
    uid = System.unique_integer([:positive])

    mods =
      [{:main, mainq} | Enum.with_index(sibqs) |> Enum.map(fn {q, i} -> {:"sib#{i}", q} end)]
      |> Task.async_stream(
        fn {tag, q} ->
          mod = Module.concat([TinyLasers.Gate.Guest, "Svelte#{uid}#{tag}"])
          [{m, bin} | _] = Code.compile_quoted(quote do (defmodule unquote(mod) do unquote(q) end) end)
          {tag, m, bin}
        end,
        timeout: 600_000, max_concurrency: nmods
      )
      |> Enum.map(fn {:ok, r} -> r end)

    for {tag, _, bin} <- mods do
      assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "compiled module #{tag} not confined"
    end

    # compiled lane: byte-identical to the golden.
    {:main, main, _} = List.keyfind(mods, :main, 0)
    comp_ctx = %{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}}
    sibs = for {tag, m, _} <- mods, tag != :main, do: m

    {:completed, comp_out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(comp_ctx)
        Enum.each(sibs, fn s -> apply(s, :__gg_register, []) end)
        try do apply(main, :run, []) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 180_000, max_heap_size: 268_435_456)
    comp_ok = Enum.find(comp_out, &String.starts_with?(&1, "SVELTE_OK["))
    assert comp_ok, "compiled lane produced no SVELTE_OK; out=#{inspect(Enum.take(comp_out, 4))}"
    comp_code = comp_ok |> String.replace_prefix("SVELTE_OK[", "") |> String.replace_prefix("5.56.4|", "") |> String.replace_suffix("]", "")
    assert String.trim(comp_code) == String.trim(golden), "compiled svelte output mismatch"
  end
end
