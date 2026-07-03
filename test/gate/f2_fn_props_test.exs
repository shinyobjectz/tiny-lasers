defmodule TinyLasers.Gate.F2FnPropsTest do
  @moduledoc """
  Function objects expose `name` and `length` as spec own properties — value plus the
  `{ writable:false, enumerable:false, configurable:true }` descriptor — on BOTH F2 frontends (Lower + Walk).
  `.length` is the arity (params before the first default/rest); `.name` is the declaration/expression name or,
  for an anonymous fn/arrow/class bound to a plain identifier, the NamedEvaluation target. Also covers the
  harness prerequisites `Object.prototype.hasOwnProperty` / `propertyIsEnumerable` reaching function receivers
  (these gate test262's propertyHelper.js). `both/1` asserts the two lanes agree.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  defp run_lower(src) do
    body = Lower.program(Js.parse(src), %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "FnP#{System.unique_integer([:positive])}"])
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
      end, timeout: 5_000, max_heap_size: 67_108_864)

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

  test ".length is the arity (params before the first default/rest)" do
    assert both("function f0(){} function f3(a,b,c){} print(f0.length+','+f3.length);") == ["0,3"]
    assert both("function d(a, b=1, c){} print(''+d.length);") == ["1"]
    assert both("function r(a, ...b){} print(''+r.length);") == ["1"]
  end

  test ".name from declaration, named expression, and NamedEvaluation" do
    assert both("function foo(){} print(foo.name);") == ["foo"]
    assert both("var g = function bar(){}; print(g.name);") == ["bar"]
    assert both("const h = function(){}; print(h.name);") == ["h"]
    assert both("const k = () => 1; print(k.name);") == ["k"]
  end

  test "an anonymous function expression has an empty name" do
    assert both("print('['+(function(){}).name+']');") == ["[]"]
  end

  test "getOwnPropertyDescriptor(fn,'length'/'name') reports the spec descriptor" do
    assert both("var d=Object.getOwnPropertyDescriptor(function(a,b){},'length'); print(d.value+'|'+d.writable+'|'+d.enumerable+'|'+d.configurable);") ==
             ["2|false|false|true"]

    assert both("var d=Object.getOwnPropertyDescriptor(function foo(){},'name'); print(d.value+'|'+d.writable+'|'+d.enumerable+'|'+d.configurable);") ==
             ["foo|false|false|true"]
  end

  test "name/length are own but NON-enumerable (for-in skips them, hasOwnProperty finds them)" do
    assert both("var s=[]; for(var k in function foo(a){}) s.push(k); print('['+s.join(',')+']');") == ["[]"]

    assert both("var f=function foo(a){}; print(f.hasOwnProperty('name')+','+f.hasOwnProperty('length')+','+f.hasOwnProperty('nope'));") ==
             ["true,true,false"]
  end

  test "Object.prototype.hasOwnProperty / propertyIsEnumerable reach function receivers (harness prereq)" do
    assert both("var hop=Function.prototype.call.bind(Object.prototype.hasOwnProperty); print(''+hop(function foo(){}, 'name'));") == ["true"]
    assert both("print(''+Object.prototype.propertyIsEnumerable.call(function foo(){}, 'name'));") == ["false"]
  end
end
