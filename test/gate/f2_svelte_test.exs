defmodule TinyLasers.Gate.F2SvelteTest do
  @moduledoc """
  **F2 rung: the real svelte 5 compiler compiles a component byte-identical to node.**

  The svelte@5.56.4 compiler (esbuild-bundled to `svelte/svelte_bundle.cjs`, ~1.2MB) runs on the BEAM. It
  compiles a component exercising runes ($props with defaults, $state, an event handler that reassigns state,
  and an `{#each}` block) to CLIENT js, and the result is compared to the golden captured from real svelte
  under node.

  Two lanes:

    * INTERPRETER (`Walk`): byte-identical to the golden. This drives the compiler's full pipeline — its
      bundled acorn (parse), scope/binding analysis + runes detection, the reactive transform (use-site
      `$.get`/`$.set` rewriting, prop getters), and the esrap printer — proving the shared Runtime handles
      real svelte end to end. This is the locked assertion.

    * COMPILED (`Lower` → native `.beam`, parallel multi-module): every module is confined
      (`dangerous_refs == %{ext: [], bifs: []}`) and the compile runs, but the client template-node builder
      diverges from the interpreter (empty `$.from_html` template) — a use-site codegen bug tracked in bd,
      NOT yet byte-identical. Asserted here for COMPILATION + CONFINEMENT only.
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
    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
    walk_out = try do Walk.run(ast, %{"print" => 0}); Runtime.__output() catch :throw, _ -> Runtime.__output() end
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

    # compiled lane runs + emits SVELTE_OK (byte-identity pending — see moduledoc / bd).
    {:main, main, _} = List.keyfind(mods, :main, 0)
    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
    for {tag, m, _} <- mods, tag != :main, do: apply(m, :__gg_register, [])
    try do apply(main, :run, []) catch :throw, _ -> :ok end
    comp_out = Runtime.__output()
    assert Enum.any?(comp_out, &String.starts_with?(&1, "SVELTE_OK[")), "compiled lane produced no SVELTE_OK"
  end
end
