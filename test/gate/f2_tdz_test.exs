defmodule TinyLasers.Gate.F2TdzTest do
  @moduledoc """
  Temporal Dead Zone for `let`/`const` on the compiled (Lower) lane. A lexical binding is hoisted to a poison
  sentinel (`:gg_tdz`) instead of `:undefined`; every read of that name is guarded, so accessing it before its
  declaration executes throws a `ReferenceError` — matching JS semantics and the test262 negative cases in
  `language/statements/{let,const}/*use-before-initialization*`.

  Scope of coverage (deliberate): SAME-scope use-before-declaration. The lexical set is not inherited into
  nested functions — an inner closure captures an outer let/const by value at closure-creation time, and real
  toolchains (rollup's chunk emitters) legally call such closures after the outer init has run, so poisoning
  them would false-positive. `arguments` is never poisoned (it is auto-bound, always available). Locked so the
  guard neither regresses nor over-fires.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime}

  # run guest source; a guest `throw` is caught in-child and rendered as "THREW:<error name>" so a test can
  # assert the thrown error's constructor without the host process dying.
  defp run(src) do
    body = Lower.program(Js.parse(src), %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "Tdz#{System.unique_integer([:positive])}"])
    [{m, _}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    {:completed, {tag, out}} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})

        tag =
          try do
            apply(m, :run, [])
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

  test "reading a let before its declaration (same scope) throws ReferenceError" do
    assert run("{ x; let x = 1; } print('no');") == ["THREW:ReferenceError"]
  end

  test "a let self-initializer (let x = x + 1) is in the dead zone" do
    assert run("let x = x + 1; print(''+x);") == ["THREW:ReferenceError"]
  end

  test "a const self-reference throws" do
    assert run("const y = y; print(''+y);") == ["THREW:ReferenceError"]
  end

  test "the ReferenceError is a real ReferenceError (instanceof), catchable in-guest" do
    assert run("try { q; let q = 1; } catch(e){ print(''+(e instanceof ReferenceError)); }") == ["true"]
  end

  test "after the declaration runs the binding reads normally" do
    assert run("let a = 5; print(''+a); a = 6; print(''+a);") == ["5", "6"]
    assert run("const b = 7; print(''+b);") == ["7"]
  end

  test "let with no initializer is undefined, not poisoned" do
    assert run("let c; print(''+c);") == ["undefined"]
  end

  test "TDZ applies inside a function body (same-scope use-before-declaration)" do
    assert run("function f(){ var r = d; let d = 2; return r; } try { f(); } catch(e){ print(''+(e instanceof ReferenceError)); }") ==
             ["true"]
  end

  test "var is unaffected — hoisted to undefined, never poisoned" do
    assert run("print(''+v); var v = 9; print(''+v);") == ["undefined", "9"]
  end

  test "`arguments` is never poisoned even when the body re-declares `let arguments`" do
    # the arguments object is auto-bound and always available; a `let arguments` must not create a dead zone
    assert run("function f(){ return arguments.length; } print(''+f(1,2,3));") == ["3"]
  end
end
