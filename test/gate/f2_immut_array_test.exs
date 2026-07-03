defmodule TinyLasers.Gate.F2ImmutArrayTest do
  @moduledoc """
  **Object-store-leak fix (Lever 2) — non-escaping, never-mutated array literals become GC'd `{:al}` terms.**

  F2 stores every mutable array as a `{:gg_vec, id}` process-dictionary handle that is NEVER reclaimed (the
  process dict is a GC root), so an allocation-heavy loop leaks one permanent entry per array — the root cause
  of GSAP's multi-GB retention (see memory `f2-object-store-leak`, bd `wb-a5tn6`). A conservative use-whitelist
  in Lower proves an array literal binding never escapes and is never mutated, and lowers it to a direct
  `{:al, list}` term (no handle) that the BEAM GC reclaims. This test locks BOTH properties:

    * CORRECTNESS — the immutable-ized program still computes the right answer, on BOTH lanes (Walk == Lower).
    * BOUNDEDNESS — after 100k temp-array allocations the process-dict store stays at baseline, not O(allocs).

  Soundness is also runtime-enforced: a mutating op on an `{:al}` array RAISES, so an analysis miss would show
  up here (or anywhere in the gate suite) as a loud divergence, never silent corruption.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

  # a hot loop building a fresh 2-element array each iteration, read only by index — the canonical leak pattern.
  @leak "var n=0; for(var i=0;i<100000;i++){ var t=[i,i+1]; n+=t[0]+t[1]; } print('R['+n+']');"

  defp lower_run(src) do
    body = Lower.program(Js.parse(src), %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "ImmutArr#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)
    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "immutable-array module not confined"

    ctx = %{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}}

    {:completed, {out, keys}} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(ctx)
        try do apply(m, :run, []) catch :throw, _ -> :ok end
        {Runtime.__output(), Enum.count(Process.get_keys())}
      end, timeout: 60_000, max_heap_size: 268_435_456)

    {out, keys}
  end

  defp walk_run(src) do
    ast = Js.parse(src)
    ctx = %{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}}

    {:completed, out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(ctx)
        try do Walk.run(ast, %{"print" => 0}) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 60_000, max_heap_size: 268_435_456)

    out
  end

  test "a hot temp-array loop stays bounded (no per-allocation store leak) and byte-identical across lanes" do
    {lower_out, keys} = lower_run(@leak)

    # correctness: sum of (i + i+1) for i in 0..99999 = 2*sum(0..99998) + ... == the interpreter's answer.
    assert lower_out == walk_run(@leak), "compiled lane diverged from interpreter"
    assert [line] = lower_out
    # sum of (i + (i+1)) for i in 0..99999 = sum(2i+1) = 100000^2 = 10_000_000_000
    assert line == "R[10000000000]", "unexpected sum: #{line}"

    # BOUNDEDNESS: 100k arrays were built; if they leaked, the store would hold ~100k {:gg_vec} keys. The
    # immutable {:al} representation keeps it at a small constant baseline.
    assert keys < 100, "object store leaked #{keys} process-dict keys (expected < 100 — arrays not reclaimed)"
  end

  test "arrays that DO escape or mutate are NOT immutable-ized (stay correct, mutable path)" do
    # push (mutation), aliasing into another var, and returning all keep the array mutable — correctness must
    # hold and no {:al}-mutation raise may fire.
    srcs = [
      "var a=[1,2]; a.push(3); print('R['+a.length+']');",              # mutating method
      "var a=[1,2]; var b=a; b[0]=9; print('R['+a[0]+']');",            # aliased then mutated via alias
      "function f(){ var a=[1,2]; return a; } var r=f(); r.push(3); print('R['+r.length+']');", # returned then mutated
      "var a=[1,2]; a[0]=7; print('R['+a[0]+']');"                      # index write
    ]

    for src <- srcs do
      {out, _} = lower_run(src)
      assert out == walk_run(src), "escape/mutation case diverged (lane mismatch): #{src}"
    end
  end
end
