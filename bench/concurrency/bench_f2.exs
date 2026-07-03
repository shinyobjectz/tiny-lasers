# F2 concurrency benchmark (Track A / J1). Measures LIGHT-request tail latency + throughput under a mixed load
# where a fraction of requests are CPU-heavy. The SAME handler logic runs on node (bench_node.js) for the
# head-to-head. Run: mix run bench/concurrency/bench_f2.exs
#
# The claim under test: on F2 a slow request cannot degrade fast requests, because every request is an isolated,
# preemptively-scheduled BEAM process. (On node's single event loop a genuinely-heavy sync request blocks the
# loop and fast-endpoint latency collapses — see bench_node.js.)

alias TinyLasers.Gate.{Js, Lower, Runtime}

compile = fn src ->
  body = Lower.program(Js.parse(src), %{"print" => 0})
  mod = Module.concat([TinyLasers.Gate.Guest, "Bench#{System.unique_integer([:positive])}"])
  [{m, _}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)
  m
end

# LIGHT = a small realistic transform (parse + fold). HEAVY = a CPU-bound compute. `HEAVY_ITERS` is tuned so the
# heavy handler is ~16 ms on F2 (matching node's genuinely-heavy 30M-iteration handler); F2 is insensitive to it.
heavy_iters = String.to_integer(System.get_env("HEAVY_ITERS") || "100000")
light = compile.("var p='a,bb,ccc,dddd'.split(','); var s=0; for(var i=0;i<p.length;i++){s+=p[i].length;} print('ok'+s);")
heavy = compile.("var s=0; for(var i=0;i<#{heavy_iters};i++){ s+=Math.sqrt(i)*1.0001; } print('c'+Math.round(s));")

# THE execution model: a fresh, resource-bounded process per request (state dies with it).
run = fn m ->
  TinyLasers.Gate.bounded(fn ->
    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
    try do apply(m, :run, []) catch :throw, _ -> :ok end
    :ok
  end, timeout: 120_000, max_heap_size: 134_217_728)
end

run.(light); run.(heavy)  # warm

pct = fn xs, p ->
  s = Enum.sort(xs)
  Enum.at(s, min(length(s) - 1, round(p * length(s)))) |> Float.round(2)
end

scenario = fn label, n, c, heavy_frac ->
  reqs =
    for i <- 1..n do
      if heavy_frac > 0 and rem(i, round(1 / heavy_frac)) == 0, do: :heavy, else: :light
    end

  {wall, results} =
    :timer.tc(fn ->
      reqs
      |> Task.async_stream(
        fn kind ->
          {us, _} = :timer.tc(fn -> run.(if kind == :heavy, do: heavy, else: light) end)
          {kind, us / 1000}
        end,
        max_concurrency: c, timeout: 120_000, ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)
    end)

  lights = for {:light, ms} <- results, do: ms

  IO.puts(
    "#{label}: #{n}req c=#{c} heavy=#{round(heavy_frac * 100)}% -> #{round(n / (wall / 1_000_000))} req/s | " <>
      "LIGHT p50=#{pct.(lights, 0.50)} p99=#{pct.(lights, 0.99)} p999=#{pct.(lights, 0.999)}ms"
  )
end

IO.puts("F2 (heavy handler ≈ #{heavy_iters} sqrt iters):")
scenario.("  pure-light", 4000, 50, 0.0)
scenario.("  5%-heavy  ", 4000, 50, 0.05)
scenario.("  20%-heavy ", 4000, 50, 0.20)
