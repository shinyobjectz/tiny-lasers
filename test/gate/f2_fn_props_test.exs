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

  test "fn.name/.length are non-writable (assignment no-ops) but configurable (delete removes ownness)" do
    assert both("var f=function foo(){}; f.name='zap'; print(f.name);") == ["foo"]
    assert both("var f=function foo(){}; var r=delete f.name; print(r+','+f.hasOwnProperty('name')+',['+f.name+']');") ==
             ["true,false,[]"]
  end

  test "defineProperty CAN redefine fn.name (configurable) even though plain writes cannot" do
    assert both("var f=function foo(){}; Object.defineProperty(f,'name',{value:'zap'}); print(f.name);") == ["zap"]
  end

  # ── per-property attribute model (P1b) ────────────────────────────────────────────────────────────────
  test "defineProperty non-enumerable: hidden from Object.keys and for-in, value still reads" do
    assert both("var o={}; Object.defineProperty(o,'x',{value:1,enumerable:false}); var k=[]; for(var p in o)k.push(p); print('['+Object.keys(o).join(',')+'],['+k.join(',')+'],'+o.x);") ==
             ["[],[],1"]
  end

  test "defineProperty non-writable: assignment is a silent no-op" do
    assert both("var o={}; Object.defineProperty(o,'x',{value:1,writable:false}); o.x=2; print(''+o.x);") == ["1"]
  end

  test "defineProperty non-configurable: delete fails (false) and the property survives" do
    assert both("var o={}; Object.defineProperty(o,'x',{value:1,configurable:false}); var r=delete o.x; print(r+','+o.hasOwnProperty('x'));") ==
             ["false,true"]
  end

  test "getOwnPropertyDescriptor reports recorded attributes; plain props stay all-true" do
    assert both("var o={}; Object.defineProperty(o,'x',{value:5,writable:false,enumerable:true,configurable:false}); var d=Object.getOwnPropertyDescriptor(o,'x'); print(d.value+'|'+d.writable+'|'+d.enumerable+'|'+d.configurable);") ==
             ["5|false|true|false"]

    assert both("var o={a:1}; var d=Object.getOwnPropertyDescriptor(o,'a'); print(d.value+'|'+d.writable+'|'+d.enumerable+'|'+d.configurable);") ==
             ["1|true|true|true"]
  end

  test "freeze: writes/additions blocked, isFrozen true; seal keeps writes but blocks add/delete" do
    assert both("var o={a:1}; Object.freeze(o); o.a=2; o.b=3; print(o.a+','+o.b+','+Object.isFrozen(o));") ==
             ["1,undefined,true"]

    assert both("var o={a:1}; Object.seal(o); o.a=2; o.b=3; var r=delete o.a; print(o.a+','+o.b+','+r+','+Object.isSealed(o));") ==
             ["2,undefined,false,true"]
  end

  test "getOwnPropertyNames includes non-enumerable props (Object.keys does not)" do
    assert both("var o={a:1}; Object.defineProperty(o,'h',{value:2,enumerable:false}); print('['+Object.getOwnPropertyNames(o).join(',')+'],['+Object.keys(o).join(',')+']');") ==
             ["[a,h],[a]"]
  end
end
