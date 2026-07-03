defmodule TinyLasers.Gate.F2GeneratorTest do
  @moduledoc """
  Generators return a proper ITERATOR object (not a bare array), so the explicit protocol works: `it.next()` →
  `{value, done}`, `.return()`, `Symbol.iterator`, alongside for-of and spread. (Evaluation is eager — the body
  runs to completion collecting yields — so two-way `next(v)` can't feed a value back to a paused yield; that
  needs lazy suspension and is out of scope here. Locked so the iterator interface doesn't regress.)
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime}

  defp run(src) do
    body = Lower.program(Js.parse(src), %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "Gen#{System.unique_integer([:positive])}"])
    [{m, _}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    {:completed, out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
        try do apply(m, :run, []) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 5_000, max_heap_size: 67_108_864)

    out
  end

  test "explicit it.next() returns {value, done}" do
    assert run("function* g(){ yield 1; yield 2; } var it=g(); var a=it.next(), b=it.next(), c=it.next(); print(a.value+','+a.done+'|'+b.value+','+b.done+'|'+c.value+','+c.done);") ==
             ["1,false|2,false|undefined,true"]
  end

  test "for-of and spread over a generator" do
    assert run("function* g(){ yield 3; yield 4; yield 5; } var s=0; for(var x of g()){ s+=x; } print(''+s);") == ["12"]
    assert run("function* g(){ yield 1; yield 2; } print(''+[...g()].join('-'));") == ["1-2"]
  end

  test "Symbol.iterator returns the generator itself; a mixed cursor stays consistent" do
    # take one via next(), then finish via for-of — the cursor is shared, so no value is repeated or skipped
    assert run("function* g(){ yield 1; yield 2; yield 3; } var it=g(); print(it.next().value+''); for(var x of it){ print('of'+x); }") ==
             ["1", "of2", "of3"]
    assert run("function* g(){ yield 9; } var it=g(); print(''+(it[Symbol.iterator]()===it));") == ["true"]
  end

  test "yield* delegates to an inner iterable" do
    assert run("function* inner(){ yield 1; yield 2; } function* g(){ yield 0; yield* inner(); yield 3; } print(''+[...g()].join(','));") ==
             ["0,1,2,3"]
  end

  test ".return() terminates the generator" do
    assert run("function* g(){ yield 1; yield 2; } var it=g(); var r=it.return(99); print(r.value+','+r.done+'|'+it.next().done);") ==
             ["99,true|true"]
  end
end
