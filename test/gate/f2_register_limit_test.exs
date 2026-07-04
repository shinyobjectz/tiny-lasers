defmodule TinyLasers.Gate.F2RegisterLimitTest do
  @moduledoc """
  **BEAM 1024 Y-register limit on a dense single scope — the exploded-function env-map fix (wb-c9vyw).**

  A single JS function that keeps ≥1024 non-constant locals live across a `try` (early/nested return, the
  async `promise_from` wrapper, or a generator) forces BEAM to preserve each local in a Y (stack) register —
  and a frame caps at 1024. The compiled lane's function-explosion (`modules_quoted`) used to *not* help:
  `explode_func` materialized one box per own-local up front (`box_inits`), all simultaneously live before the
  first chunk call, so a scope with ≥1024 own-locals still blew the limit even after chunking.

  Fix: the own-local boxes now live in ONE per-invocation `fresh_env` map (a single handle threaded to the
  chunk defs); each chunk fetches only the locals it mentions by name (`env_box`), so no BEAM frame ever holds
  ≥1024 live boxes. Fresh per invocation ⇒ recursion stays correct. This locks that a function with well over
  1024 own-locals both COMPILES (confined) and RUNS correctly on the exploded lane.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime}

  @n 1200
  # sum of (i+1) for i in 0..n-1  ==  n*(n+1)/2
  @want "#{div(@n * (@n + 1), 2)}"

  # each variant: >1024 distinct locals, each assigned from a call (non-constant → genuinely live across the
  # body's `try`), body well over the 30KB explosion threshold so it takes the exploded lane.
  defp decls, do: for(i <- 0..(@n - 1), into: "", do: "  var v#{i} = g(#{i}); s += v#{i};\n")
  defp yields, do: for(i <- 0..(@n - 1), into: "", do: "  var v#{i} = g(#{i}); yield v#{i};\n")

  defp sync_src, do: "function g(x){ return x+1; }\nfunction big(){\n  var s=0;\n" <> decls() <> "  return s;\n}\nprint(''+big());\n"
  defp async_src, do: "function g(x){ return x+1; }\nasync function big(){\n  var s=0;\n" <> decls() <> "  return s;\n}\nbig().then(function(r){ print(''+r); });\n"
  defp gen_src, do: "function g(x){ return x+1; }\nfunction* big(){\n" <> yields() <> "}\nvar t=0; for (var x of big()) { t+=x; }\nprint(''+t);\n"

  defp compile_run(src) do
    nmods = System.schedulers_online()
    %{main: mainq, siblings: sibqs} = Lower.modules_quoted(Js.parse(src), %{"print" => 0}, modules: nmods)
    uid = System.unique_integer([:positive])

    mods =
      [{:main, mainq} | Enum.with_index(sibqs) |> Enum.map(fn {q, i} -> {:"sib#{i}", q} end)]
      |> Enum.map(fn {tag, q} ->
        mod = Module.concat([TinyLasers.Gate.Guest, "RegLim#{uid}#{tag}"])
        [{m, bin} | _] = Code.compile_quoted(quote do (defmodule unquote(mod) do unquote(q) end) end)
        {tag, m, bin}
      end)

    for {tag, _, bin} <- mods do
      assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "module #{tag} not confined"
    end

    {:main, main, _} = List.keyfind(mods, :main, 0)
    sibs = for {tag, m, _} <- mods, tag != :main, do: m

    {:completed, out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
        Enum.each(sibs, fn s -> apply(s, :__gg_register, []) end)
        try do apply(main, :run, []) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 60_000, max_heap_size: 268_435_456)

    out
  end

  test "a SYNC function with >1024 own-locals compiles (confined) and runs correctly on the exploded lane" do
    assert compile_run(sync_src()) == [@want]
  end

  test "a huge ASYNC function (>1024 locals) explodes with the promise_from wrapper, confined + correct" do
    assert compile_run(async_src()) == [@want]
  end

  test "a huge GENERATOR (>1024 locals) explodes with the gen_begin/gen_end wrapper, confined + correct" do
    assert compile_run(gen_src()) == [@want]
  end
end
