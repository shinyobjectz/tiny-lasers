defmodule TinyLasers.Gate.F2TsRunKitTest do
  @moduledoc """
  **TypeScript Layers 4 + 5: run the bundled output, and the compile-once / reuse-many platform-kit model.**

  Layer 4 (run output) — the ACTUAL bundled TS project (`ts_multi_golden.js`, produced by the rollup+sucrase
  pipeline) is executed on F2, both lanes, confined, and must produce the correct runtime result. This closes
  the full loop: author multi-file TS → transpile → bundle → RUN, entirely BEAM-native.

  Layer 5 (platform kit) — the sucrase toolchain is packaged as a reusable kit (`sucrase_kit.js`: the SUCRASE
  global + an entry that reads its TS source from a host `__input` capability). It is `Code.compile_quoted`
  ONCE (the expensive deploy-time step), then that single compiled module transpiles MANY different TS/TSX
  inputs — each in a fresh bounded process, with NO recompile. This is the kit economics: amortize the compile
  across all invocations, share the public toolchain code (no per-tenant isolation needed — unlike tenant
  code), isolate every invocation. Proves the mechanism the cloud layer packages + version-pins via `.work`.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  @conf "test/conformance"

  # ── Layer 4: the bundled TS output actually runs ──
  test "the bundled multi-file TS output runs on F2 (both lanes, confined) with the correct result" do
    bundle = File.read!(Path.join(@conf, "rollup/ts_multi_golden.js"))
    harness = "var exports = {}; var module = { exports: exports }; var console = { log: function(x){ print(x); } };\n"
    src = harness <> bundle

    run = fn thunk ->
      {:completed, out} =
        TinyLasers.Gate.bounded(fn ->
          Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
          try do thunk.() catch :throw, _ -> :ok end
          Runtime.__output()
        end, timeout: 10_000, max_heap_size: 134_217_728)

      out
    end

    assert run.(fn -> Walk.run(Js.parse(src), %{"print" => 0}) end) == ["hi WORLD! bye world@v1"]

    body = Lower.program(Js.parse(src), %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "L4#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "bundled TS output not confined"
    assert run.(fn -> apply(m, :run, []) end) == ["hi WORLD! bye world@v1"]
  end

  # ── Layer 5: compile the toolchain kit ONCE, reuse for many inputs ──
  @tag timeout: 300_000
  test "the sucrase kit compiles once and transpiles many different TS/TSX inputs with no recompile, confined" do
    kit = File.read!(Path.join(@conf, "sucrase/sucrase_kit.js"))

    # deploy-time: ONE compile
    body = Lower.program(Js.parse(kit), %{"print" => 0, "__input" => 1})
    mod = Module.concat([TinyLasers.Gate.Guest, "SucraseKit#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "sucrase kit not confined"

    # per-invocation: reuse the SAME module `m` for each input (fresh bounded process, TS source via __input cap)
    transpile = fn ts ->
      cap = fn _state, _args -> ts end

      {:completed, out} =
        TinyLasers.Gate.bounded(fn ->
          Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}, 1 => %{fun: cap}}, tenant_root: "/t", fs: %{}})
          try do apply(m, :run, []) catch :throw, _ -> :ok end
          Runtime.__output()
        end, timeout: 30_000, max_heap_size: 268_435_456)

      (Enum.find(out, &String.starts_with?(&1, "KIT[")) || flunk("no KIT output: #{inspect(out)}"))
      |> String.replace_prefix("KIT[", "")
      |> String.replace_suffix("]", "")
      |> String.trim()
    end

    assert transpile.("const x: number = 41 + 1;") == "const x = 41 + 1;"
    assert transpile.("interface P { n: string }\nconst g = (p: P): string => p.n;") == "const g = (p) => p.n;"
    assert transpile.("const el = <div id=\"z\">{1 + 2}</div>;") == "const el = React.createElement('div', { id: \"z\",}, 1 + 2);"

    assert transpile.("enum E { A = 1, B }") ==
             "var E; (function (E) { const A = 1; E[E[\"A\"] = A] = \"A\"; const B = A + 1; E[E[\"B\"] = B] = \"B\"; })(E || (E = {}));"
  end
end
