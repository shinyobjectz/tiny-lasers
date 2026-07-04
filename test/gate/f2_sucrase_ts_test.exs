defmodule TinyLasers.Gate.F2SucraseTsTest do
  @moduledoc """
  **Layer 1 of the TypeScript toolchain: the sucrase transpiler runs untrusted TS/TSX → JS inside F2,
  BYTE-IDENTICAL to node, BOTH lanes, confined.**

  The real `sucrase` (esbuild-bundled to a single ~700KB production script) strips TypeScript types and lowers
  JSX to `React.createElement`, and its output is compared BYTE-FOR-BYTE to the golden captured from sucrase
  under node. This is the in-sandbox TS story: author TS/TSX, transpile it BEAM-native, run the result on F2.

    * INTERPRETER (`Walk`) and COMPILED (`Lower`, confined `ext:[] bifs:[]`) both match the golden.

  Getting here root-caused wb-9rldq: sucrase rolls back a speculative arrow-function parse by truncating its
  token array via `tokens.length = savedLength`, and F2 was ignoring `array.length = n` resize — so every
  trial token leaked and typed constructs double-emitted (`constconst g = (x) =>(x) =>`). The fix (arr_put
  length clause: truncate/grow/RangeError) is exercised directly below and is the load-bearing primitive.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  @conf "test/conformance/sucrase"

  defp transpile(bundle_file, marker) do
    src = File.read!(Path.join(@conf, bundle_file))
    ast = Js.parse(src)
    ctx = %{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}}

    extract = fn out ->
      (Enum.find(out, &String.starts_with?(&1, marker)) || "")
      |> String.replace_prefix(marker, "")
      |> String.replace_suffix("]", "")
      |> String.trim()
    end

    {:completed, walk_out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(ctx)
        try do Walk.run(ast, %{"print" => 0}) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 60_000, max_heap_size: 536_870_912)

    body = Lower.program(ast, %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "Sucrase#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "compiled sucrase module not confined"

    {:completed, lower_out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(ctx)
        try do apply(m, :run, []) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 60_000, max_heap_size: 536_870_912)

    {extract.(walk_out), extract.(lower_out)}
  end

  @tag timeout: 300_000
  test "sucrase strips TypeScript types byte-identical to node, both lanes, confined" do
    golden = File.read!(Path.join(@conf, "ts_golden.js")) |> String.trim()
    {walk, lower} = transpile("ts_bundle.js", "TSOUT[")
    assert walk == golden, "interpreter TS transpile diverged from node golden"
    assert lower == golden, "compiled TS transpile diverged from node golden"
  end

  @tag timeout: 300_000
  test "sucrase lowers TSX (types + JSX → React.createElement) byte-identical to node, both lanes, confined" do
    golden = File.read!(Path.join(@conf, "tsx_golden.js")) |> String.trim()
    {walk, lower} = transpile("tsx_bundle.js", "TSXOUT[")
    assert walk == golden, "interpreter TSX transpile diverged from node golden"
    assert lower == golden, "compiled TSX transpile diverged from node golden"
  end

  @tag timeout: 300_000
  test "the 15-feature TS/TSX coverage corpus transpiles byte-identical to node, both lanes" do
    # decorators, const enum, namespaces, import type, parameter properties, satisfies/as, non-null/optional,
    # abstract/override, generics+keyof, type-only decls, JSX classic + automatic runtime, fragments+spread,
    # computed enums — each transpiled by sucrase and compared to the sucrase-under-node golden.
    golden = File.read!(Path.join(@conf, "corpus_golden.txt")) |> String.trim_trailing()
    src = File.read!(Path.join(@conf, "corpus_bundle.js"))
    ast = Js.parse(src)
    ctx = %{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}}

    join = fn out -> out |> Enum.join("\n") |> String.trim_trailing() end

    {:completed, walk} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(ctx)
        try do Walk.run(ast, %{"print" => 0}) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 120_000, max_heap_size: 536_870_912)

    assert join.(walk) == golden, "interpreter corpus diverged from node"

    body = Lower.program(ast, %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "Corpus#{System.unique_integer([:positive])}"])
    [{m, _}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    {:completed, lower} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(ctx)
        try do apply(m, :run, []) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 120_000, max_heap_size: 536_870_912)

    assert join.(lower) == golden, "compiled corpus diverged from node (parameter-properties needs the destructuring-assign box fix)"
  end

  # ── destructuring ASSIGNMENT to a nested-block-mutated var must box (Lower codegen; param-properties
  #    injection depended on it — the compiled `while` body's `lvar = …` otherwise never leaks out) ──
  test "({a,b} = expr) inside a nested block updates the outer binding read after it, both lanes agree" do
    both = fn src ->
      run = fn thunk ->
        {:completed, out} =
          TinyLasers.Gate.bounded(fn ->
            Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
            try do thunk.() catch :throw, _ -> :ok end
            Runtime.__output()
          end, timeout: 5_000, max_heap_size: 67_108_864)

        out
      end

      w = run.(fn -> Walk.run(Js.parse(src), %{"print" => 0}) end)

      l =
        run.(fn ->
          body = Lower.program(Js.parse(src), %{"print" => 0})
          mod = Module.concat([TinyLasers.Gate.Guest, "DA#{System.unique_integer([:positive])}"])
          [{m, _}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)
          apply(m, :run, [])
        end)

      assert w == l, "lane divergence for #{inspect(src)}: Walk=#{inspect(w)} Lower=#{inspect(l)}"
      w
    end

    # object pattern reassigned inside a while/if, read after the loop
    assert both.(
             "function f(){ let a=[], b=null, i=0; while(i<3){ if(i===1){ ({a,b} = {a:[7,8],b:9}); } i++; } return a.length+','+b; } print(f());"
           ) == ["2,9"]

    # array pattern reassigned inside an if, read after
    assert both.("function f(){ let x=0, y=0; if(true){ [x,y] = [4,5]; } return x+','+y; } print(f());") == ["4,5"]
  end

  # ── the load-bearing primitive wb-9rldq turned on ──
  test "array.length = n resizes (truncate / grow-with-holes), both lanes agree" do
    both = fn src ->
      run = fn thunk ->
        {:completed, out} =
          TinyLasers.Gate.bounded(fn ->
            Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
            try do thunk.() catch :throw, _ -> :ok end
            Runtime.__output()
          end, timeout: 5_000, max_heap_size: 67_108_864)

        out
      end

      w = run.(fn -> Walk.run(Js.parse(src), %{"print" => 0}) end)

      l =
        run.(fn ->
          body = Lower.program(Js.parse(src), %{"print" => 0})
          mod = Module.concat([TinyLasers.Gate.Guest, "AL#{System.unique_integer([:positive])}"])
          [{m, _}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)
          apply(m, :run, [])
        end)

      assert w == l, "lane divergence for #{inspect(src)}: Walk=#{inspect(w)} Lower=#{inspect(l)}"
      w
    end

    assert both.("var a=[1,2,3,4,5]; a.length=2; print('['+a.join(',')+'] '+a.length);") == ["[1,2] 2"]
    assert both.("var a=[1,2]; a.length=4; print(a.length+' '+(a[3]===undefined));") == ["4 true"]
    assert both.("var a=[1,2,3]; a.length=0; print('['+a.join(',')+'] '+a.length);") == ["[] 0"]
    assert both.("try { var a=[]; a.length=-1; print('no'); } catch(e){ print(e.name); }") == ["RangeError"]
  end
end
