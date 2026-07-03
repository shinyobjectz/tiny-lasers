defmodule TinyLasers.Gate.F2NamedEvalTypedArrayTest do
  @moduledoc """
  Two gaps surfaced by running the sucrase TypeScript transpiler *inside* F2 (untrusted TS→JS in the sandbox),
  both fixed on BOTH lanes:

    1. Object-property NamedEvaluation — an anonymous fn/arrow/class value with a STATIC key takes that key as
       its inferred `.name`: `{ foo(){} }.foo.name === "foo"`, shorthand methods and `k: function(){}` alike.
       (Was `""` — F2 only inferred names for `const f = …`, not object properties.)
    2. The three missing typed-array constructors — `Uint8ClampedArray`, `BigInt64Array`, `BigUint64Array` —
       were undefined globals; `undefined.name` threw during sucrase's `basicTypes[ctor.name]` table build.

  `both/1` asserts Walk and Lower agree.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  defp run_lower(src) do
    body = Lower.program(Js.parse(src), %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "NE#{System.unique_integer([:positive])}"])
    [{m, _}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)
    drive(fn -> apply(m, :run, []) end)
  end

  defp run_walk(src), do: drive(fn -> Walk.run(Js.parse(src), %{"print" => 0}) end)

  defp drive(thunk) do
    {:completed, {tag, out}} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})

        tag =
          try do
            thunk.()
            :ok
          catch
            :throw, {t, v} when t in [:gg_throw, :gg_guest_error] ->
              {:threw, to_string(try do Runtime.oget(v, "name") rescue _ -> "?" end)}

            :throw, {:gg_return, _} ->
              :ok
          end

        {tag, Runtime.__output()}
      end, timeout: 10_000, max_heap_size: 134_217_728)

    case tag do
      :ok -> out
      {:threw, name} -> out ++ ["THREW:" <> name]
    end
  end

  defp both(src) do
    lo = run_lower(src)
    wa = run_walk(src)
    assert lo == wa, "lane divergence for #{inspect(src)}:\n  Lower=#{inspect(lo)}\n  Walk =#{inspect(wa)}"
    lo
  end

  test "object shorthand methods infer their key as .name" do
    assert both("var o={ foo(){} }; print(o.foo.name);") == ["foo"]
    assert both("var o={ 'bar'(){} }; print(o.bar.name);") == ["bar"]
  end

  test "object property function/arrow values infer their key as .name" do
    assert both("var o={ baz: function(){} }; print(o.baz.name);") == ["baz"]
    assert both("var o={ qux: ()=>1 }; print(o.qux.name);") == ["qux"]
  end

  test "a named function expression keeps its own name; computed keys do not force one" do
    assert both("var o={ a: function real(){} }; print(o.a.name);") == ["real"]
    assert both("var k='dyn'; var o={ [k]: function(){} }; print('['+o.dyn.name+']');") == ["[]"]
  end

  test "Uint8ClampedArray exists, clamps 0..255, has the right .name" do
    assert both("print(Uint8ClampedArray.name);") == ["Uint8ClampedArray"]
    assert both("var a=new Uint8ClampedArray([300, -5, 128.6]); print(a[0]+','+a[1]+','+a[2]+','+a.length);") ==
             ["255,0,129,3"]
  end

  test "BigInt64Array / BigUint64Array exist, store and read bigints, have the right .name" do
    assert both("print(BigInt64Array.name+','+BigUint64Array.name);") == ["BigInt64Array,BigUint64Array"]
    assert both("var a=new BigInt64Array(2); a[0]=5n; a[1]=-3n; print(a[0]+','+a[1]+','+(typeof a[0]));") ==
             ["5,-3,bigint"]
  end

  test "iterating the typed-array constructor globals and reading .name no longer throws (the sucrase pattern)" do
    src =
      "var s=''; var cs=[Int8Array,Uint8Array,Uint8ClampedArray,Int16Array,Uint16Array,Int32Array," <>
        "Uint32Array,Float32Array,Float64Array,BigInt64Array,BigUint64Array]; " <>
        "for (var i=0;i<cs.length;i++){ s += cs[i].name + ';'; } print(s);"

    assert both(src) == [
             "Int8Array;Uint8Array;Uint8ClampedArray;Int16Array;Uint16Array;Int32Array;Uint32Array;Float32Array;Float64Array;BigInt64Array;BigUint64Array;"
           ]
  end
end
