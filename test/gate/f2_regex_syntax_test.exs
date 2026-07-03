defmodule TinyLasers.Gate.F2RegexSyntaxTest do
  @moduledoc """
  JS-invalid regex patterns/flags throw a catchable `SyntaxError` (test262 S15.10.1 / built-ins/RegExp), on
  BOTH F2 frontends. The validator (`Runtime.js_pattern_error`) is deliberately CONSERVATIVE: it throws only
  on definitely-invalid shapes — nothing-to-repeat quantifiers (`?a`, `++a`), stacked quantifiers (`a**`,
  `x{1}{1,}`), unterminated group/class, unmatched `)`, malformed named groups, duplicate/unknown flags.
  Everything it is unsure about still compiles, and a PCRE-only failure keeps the silent never-match fallback —
  JS-valid patterns the toolchains rely on (`[^]`, lazy `a*?`, lookaheads, named groups, Annex-B literal `{`)
  must never start throwing. Locked so the validator neither regresses nor over-fires.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  defp run_lower(src) do
    body = Lower.program(Js.parse(src), %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "RxS#{System.unique_integer([:positive])}"])
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

  defp catches(pattern_js) do
    both("try { new RegExp(#{pattern_js}); print('NOTHROW'); } catch(e){ print('SE:'+(e instanceof SyntaxError)); }")
  end

  test "nothing-to-repeat and stacked quantifiers throw SyntaxError (catchable in-guest)" do
    assert catches("'a**'") == ["SE:true"]
    assert catches("'++a'") == ["SE:true"]
    assert catches("'?a'") == ["SE:true"]
    assert catches("'??a'") == ["SE:true"]
    assert catches("'x{1}{1,}'") == ["SE:true"]
    assert catches("'x{1,2}{1}'") == ["SE:true"]
  end

  test "unterminated group / class and unmatched paren throw" do
    assert catches("'(a'") == ["SE:true"]
    assert catches("'[a'") == ["SE:true"]
    assert catches("'a)'") == ["SE:true"]
  end

  test "invalid flags throw SyntaxError" do
    assert both("try { new RegExp('a','gg'); print('NO'); } catch(e){ print('SE:'+(e instanceof SyntaxError)); }") == ["SE:true"]
    assert both("try { new RegExp('a','z'); print('NO'); } catch(e){ print('SE:'+(e instanceof SyntaxError)); }") == ["SE:true"]
  end

  test "out-of-order class ranges and {max<min} quantifiers throw" do
    assert catches("'^[z-a]$'") == ["SE:true"]
    assert catches("'0{2,1}'") == ["SE:true"]
  end

  test "new RegExp(regexObj, flags) rebuilds from the source; empty flags inherit" do
    assert both("var r = new RegExp(new RegExp('ab'), 'g'); print(r.global+','+r.source);") == ["true,ab"]
    assert both("var r = new RegExp(/xy/i); print(r.ignoreCase+','+r.source);") == ["true,xy"]
  end

  test "constructor-object property protocol (S15.10.5.1): prototype is own, non-enum, non-deletable" do
    assert both("print(''+RegExp.hasOwnProperty('prototype'));") == ["true"]
    assert both("print(''+(delete RegExp.prototype));") == ["false"]
    assert both("print(''+RegExp.prototype.isPrototypeOf(/a/));") == ["true"]
    assert both("print(''+(RegExp.prototype.constructor===RegExp));") == ["true"]
  end

  test "\\xHH at or above 0x80 matches the CODE POINT in UTF-8 guest strings" do
    assert both("var a=/\\xFF/.exec('\\u00FF'); print(a===null?'null':a[0]==='\\u00FF'?'cp':'byte');") == ["cp"]
  end

  test "JS-valid patterns the toolchains rely on must NOT throw" do
    assert both("print(''+/aa*?/.test('aaa'));") == ["true"]
    assert both("print(''+/[^]/.test('x'));") == ["true"]
    assert both("print(''+/(?=a)a/.test('a'));") == ["true"]
    assert both("print(''+/(?<y>a)/.test('a'));") == ["true"]
    assert both("print(''+/a{/.test('a{'));") == ["true"]
    assert both("print(''+/[*+?]/.test('*'));") == ["true"]
    assert both("print(''+/x{2}/.test('xx'));") == ["true"]
    assert both("print(''+new RegExp('a+b*c?').test('aabc'));") == ["true"]
  end
end
