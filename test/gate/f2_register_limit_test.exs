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

  # a big sync function: >1024 distinct locals, each assigned from a call (non-constant → genuinely live),
  # summed, and the body is well over the 30KB explosion threshold so it takes the exploded lane.
  defp big_fn_src(n) do
    decls = for(i <- 0..(n - 1), into: "", do: "  var v#{i} = g(#{i}); s += v#{i};\n")
    "function g(x){ return x + 1; }\nfunction big(){\n  var s = 0;\n" <> decls <> "  return s;\n}\nprint('' + big());\n"
  end

  test "a function with >1024 own-locals compiles (confined) and runs correctly on the exploded lane" do
    n = 1200
    src = big_fn_src(n)
    nmods = System.schedulers_online()

    %{main: mainq, siblings: sibqs} =
      Lower.modules_quoted(Js.parse(src), %{"print" => 0}, modules: nmods)

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

    # sum of (i+1) for i in 0..n-1  ==  n*(n+1)/2
    assert out == ["#{div(n * (n + 1), 2)}"]
  end
end
