defmodule TinyLasers.Gate.F2RollupScaleTest do
  @moduledoc """
  **F2 SCALE rung: rollup bundles a LARGE multi-entry graph byte-identical to native rollup, BOTH lanes, confined.**

  Where the multi-module rung proved a 4-module CJS graph, this proves rollup's *code-splitting* at scale: 64
  entry modules (`e0..e63`), each importing a shared `common.js` plus a unique module, bundled to ES format
  with `[name].js` filenames. rollup groups modules into chunks by an ATOM BITMASK — each entry gets a bit,
  and a module's chunk is decided by the set of entries that reach it (`atomMask <<= 1n`,
  `staticDependencyAtomsByEntry`, `chunkSignature`). `common.js` is reached by all 64 entries, so its signature
  is `(1<<64)-1` — WELL past 2^53, where the former float representation of bigints silently corrupted. This is
  the payoff of real bigint: the atom masks stay exact, chunk assignment is correct, and the 65-chunk output is
  byte-for-byte the native rollup@4.62.2 golden.

  The golden (`scale_golden.txt`) was captured from real rollup@4.62.2 under node via its native (non-wasm)
  parser — an INDEPENDENT oracle (the F2 lane uses the wasm parser + a BEAM-side hash). Both F2 frontends must
  match it:

    * INTERPRETER (`Walk`): byte-identical to the golden.
    * COMPILED (`Lower` → native `.beam`, parallel multi-module): byte-identical AND every module confined
      (`dangerous_refs == %{ext: [], bifs: []}`).

  Regression guard for the `assigned_names/1` member-index-mutation fix: `chunks[index++] = chunk` inside
  rollup's `generateChunks` loop needs `index`'s increment threaded across iterations, which the compiled lane
  formerly dropped (every chunk landed at index 0) — surfacing only at this ES-code-splitting scale.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  @conf "test/conformance"

  # F2 joins its chunks with SOH on one print line; the golden joins with a text marker.
  @soh <<1>>
  @golden_sep "\n===CHUNKSEP===\n"

  defp parse_chunks(text, sep) do
    text
    |> String.split(sep)
    |> Enum.flat_map(fn part ->
      case Regex.run(~r/\ASCALE_CHUNK\[([^\]]+)\]\{(.*)\}\s*\z/s, part) do
        [_, name, code] -> [{name, code}]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  defp chunk_line(out) do
    Enum.find(out, &String.starts_with?(&1, "SCALE_CHUNK[")) ||
      flunk("no SCALE_CHUNK output; got #{inspect(Enum.map(out, &String.slice(&1, 0, 40)) |> Enum.take(6))}")
  end

  @tag timeout: 600_000
  test "rollup code-splits a 64-entry graph byte-identical to native rollup, both lanes, confined" do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js")) <> "\n" <> File.read!(Path.join(@conf, "rollup/node_shims.js"))
    bundle = File.read!(Path.join(@conf, "rollup/rollup_bundle.cjs"))
    driver = File.read!(Path.join(@conf, "rollup/scale_driver.js"))
    src = prelude <> "\n" <> bundle <> "\n" <> driver
    ast = Js.parse(src)

    golden = parse_chunks(File.read!(Path.join(@conf, "rollup/scale_golden.txt")), @golden_sep)
    assert length(golden) == 65, "golden should have 65 chunks (64 entries + shared common), got #{length(golden)}"

    # ── interpreter lane: byte-identical to the native golden ──
    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}, 1 => %{fun: &Runtime.host_rollup_bridge/2}}, tenant_root: "/t", fs: %{}})
    walk_out = try do Walk.run(ast, %{"print" => 0, "__host" => 1}); Runtime.__output() catch :throw, _ -> Runtime.__output() end
    walk_chunks = parse_chunks(chunk_line(walk_out), @soh)
    assert walk_chunks == golden, "interpreter output diverged from native rollup golden"

    # ── compiled lane: parallel multi-module, every module confined, byte-identical ──
    nmods = System.schedulers_online()
    %{main: mainq, siblings: sibqs} = Lower.modules_quoted(ast, %{"print" => 0, "__host" => 1}, modules: nmods)
    uid = System.unique_integer([:positive])

    mods =
      [{:main, mainq} | Enum.with_index(sibqs) |> Enum.map(fn {q, i} -> {:"sib#{i}", q} end)]
      |> Task.async_stream(
        fn {tag, q} ->
          mod = Module.concat([TinyLasers.Gate.Guest, "RollupScale#{uid}#{tag}"])
          [{m, bin} | _] = Code.compile_quoted(quote do (defmodule unquote(mod) do unquote(q) end) end)
          {tag, m, bin}
        end,
        timeout: 600_000, max_concurrency: nmods
      )
      |> Enum.map(fn {:ok, r} -> r end)

    for {tag, _, bin} <- mods do
      assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "compiled module #{tag} not confined"
    end

    {:main, main, _} = List.keyfind(mods, :main, 0)
    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}, 1 => %{fun: &Runtime.host_rollup_bridge/2}}, tenant_root: "/t", fs: %{}})
    for {tag, m, _} <- mods, tag != :main, do: apply(m, :__gg_register, [])
    try do apply(main, :run, []) catch :throw, _ -> :ok end
    comp_chunks = parse_chunks(chunk_line(Runtime.__output()), @soh)
    assert comp_chunks == golden, "compiled lane output diverged from native rollup golden"
  end
end
