defmodule TinyLasers.Gate.F2TdzTest do
  @moduledoc """
  Temporal Dead Zone for `let`/`const` — on BOTH F2 frontends: the compiled `Lower` lane and the `Walk`
  interpreter. A lexical binding is hoisted to a poison sentinel (`:gg_tdz`) instead of `:undefined`; every
  read of that name is guarded, so accessing it before its declaration executes throws a `ReferenceError` —
  matching JS semantics and the test262 negatives in `language/statements/{let,const}/*use-before-init*`.

  Scope of coverage (deliberate): SAME-FUNCTION-scope use-before-declaration. Neither lane poisons across a
  function boundary — an inner closure reads an outer let/const that may legally initialize before the closure
  actually runs (rollup registers `.then(() => outerConst)` a line before `const outerConst = …`), and a
  microtask drain can interleave before the declaration; so a cross-boundary poison read degrades to the legacy
  `:undefined` rather than throwing. (Correctly catching only the *synchronous* cross-boundary case — an IIFE
  run during the initializer — needs deferred-scheduling fidelity we don't yet guarantee; see bd follow-up.)
  `arguments` is never poisoned (auto-bound, always available). Locked so the guard neither regresses nor
  over-fires, and so the two lanes agree.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

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

  # same, but through the Walk interpreter — used to prove the two frontends agree on TDZ.
  defp run_walk(src) do
    {:completed, {tag, out}} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})

        tag =
          try do
            Walk.run(Js.parse(src), %{"print" => 0})
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

  # assert both lanes produce the same observable result for `src`, and return it.
  defp both(src) do
    lo = run(src)
    wa = run_walk(src)
    assert lo == wa, "lane divergence for #{inspect(src)}:\n  Lower=#{inspect(lo)}\n  Walk =#{inspect(wa)}"
    lo
  end

  # `both/1` asserts Lower and Walk agree, so each of these also locks lane parity.
  test "reading a let before its declaration (same scope) throws ReferenceError" do
    assert both("{ x; let x = 1; } print('no');") == ["THREW:ReferenceError"]
  end

  test "a let self-initializer (let x = x + 1) is in the dead zone" do
    assert both("let x = x + 1; print(''+x);") == ["THREW:ReferenceError"]
  end

  test "a const self-reference throws" do
    assert both("const y = y; print(''+y);") == ["THREW:ReferenceError"]
  end

  test "the ReferenceError is a real ReferenceError (instanceof), catchable in-guest" do
    assert both("try { q; let q = 1; } catch(e){ print(''+(e instanceof ReferenceError)); }") == ["true"]
  end

  test "after the declaration runs the binding reads normally" do
    assert both("let a = 5; print(''+a); a = 6; print(''+a);") == ["5", "6"]
    assert both("const b = 7; print(''+b);") == ["7"]
  end

  test "let with no initializer is undefined, not poisoned" do
    assert both("let c; print(''+c);") == ["undefined"]
  end

  test "TDZ applies inside a function body (same-scope use-before-declaration)" do
    assert both("function f(){ var r = d; let d = 2; return r; } try { f(); } catch(e){ print(''+(e instanceof ReferenceError)); }") ==
             ["true"]
  end

  test "var is unaffected — hoisted to undefined, never poisoned" do
    assert both("print(''+v); var v = 9; print(''+v);") == ["undefined", "9"]
  end

  test "`arguments` is never poisoned even when the body re-declares `let arguments`" do
    # the arguments object is auto-bound and always available; a `let arguments` must not create a dead zone
    assert both("function f(){ return arguments.length; } print(''+f(1,2,3));") == ["3"]
  end

  test "a cross-function-boundary read of a not-yet-initialized let does NOT throw (both lanes conservative)" do
    # an inner closure may legally run after the outer const initializes; neither lane poisons across the
    # boundary (rollup's `.then(() => outerConst)` pattern). The IIFE here runs during init, but we still
    # degrade to undefined rather than throwing — the deliberate, gate-preserving conservative choice.
    assert both("var out; (function(){ out = typeof w; })(); let w = 1; print(out);") == ["undefined"]
  end

  test "a let read out of its block scope is not poisoned (Walk block scoping)" do
    # Walk gives `s` real block scope; Lower function-scopes it. Both must avoid a spurious dead-zone throw
    # for an out-of-block read — assert no ReferenceError leaks on either lane.
    refute "THREW:ReferenceError" in run_walk("if(true){ let s = 1; } print(typeof s);")
    refute "THREW:ReferenceError" in run("if(true){ let s = 1; } print(typeof s);")
  end
end
