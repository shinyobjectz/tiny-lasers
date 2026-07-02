# F2 differential fuzzer — RUNNER. Reads the oracle corpus (TSV: expr<TAB>json(String(eval(expr)))), builds
# ONE F2 program that evaluates every expr under try/catch, runs it through Walk (fast: one parse+run), and
# diffs each result against the oracle. Reports mismatches with minimal repros. Env LANE=lower to also compile.
alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}

corpus = File.read!(System.get_env("CORPUS")) |> String.split("\n", trim: true)
cases =
  corpus
  |> Enum.map(fn line -> [expr, jout] = String.split(line, "\t", parts: 2); {expr, TinyLasers.Wasm.Json.decode!(jout)} end)

# build one program: R<i><TAB><String(expr) | THROW:Name>
body =
  cases
  |> Enum.with_index()
  |> Enum.map(fn {{expr, _}, i} ->
    ~s|try { print("R#{i}\\t" + String(#{expr})); } catch (e) { print("R#{i}\\tTHROW:" + (e && e.constructor ? e.constructor.name : "Error")); }|
  end)
  |> Enum.join("\n")

prelude = "var console = { log: function(){ print(arguments[0]); } };\n"
ast = Js.parse(prelude <> body)

run_walk = fn ->
  Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
  # a guest throw is expected; an ELIXIR-level error (ArithmeticError, etc.) is an F2 BUG that crashes the whole
  # batch — rescue it and keep the partial output so we can pinpoint the crashing expr (the first missing R<i>).
  crash =
    try do Walk.run(ast, %{"print" => 0}); nil catch :throw, _ -> nil rescue e -> Exception.message(e) |> String.slice(0, 60) end
  {Runtime.__output(), crash}
end

{out, crash} = run_walk.()
got = Map.new(out, fn l -> case String.split(l, "\t", parts: 2) do [k, v] -> {k, v}; [k] -> {k, ""} end end)
# if an Elixir-level crash occurred, the first case with no R<i> is (near) the crasher.
if crash do
  crasher = cases |> Enum.with_index() |> Enum.find(fn {_, i} -> not Map.has_key?(got, "R#{i}") end)
  IO.puts("!! F2 ELIXIR CRASH: #{crash}")
  IO.puts("!! crashing expr (first missing): #{inspect(crasher && elem(elem(crasher, 0), 0))}")
end

{ok, mism} =
  cases
  |> Enum.with_index()
  |> Enum.reduce({0, []}, fn {{expr, oracle}, i}, {ok, ms} ->
    f2 = Map.get(got, "R#{i}", "(missing)")
    if f2 == oracle, do: {ok + 1, ms}, else: {ok, [{expr, oracle, f2} | ms]}
  end)

total = length(cases)
IO.puts("=== F2 FUZZER (Walk) — #{total} cases ===")
IO.puts("MATCH #{ok}  MISMATCH #{length(mism)}  (#{Float.round(ok * 100 / max(total, 1), 1)}%)")
IO.puts("\n=== MISMATCHES (up to 40) ===")
mism |> Enum.reverse() |> Enum.take(40) |> Enum.each(fn {e, o, f} ->
  IO.puts("  #{String.pad_trailing(e, 40)} oracle=#{inspect(o)} f2=#{inspect(f)}")
end)
# bucket by rough signature (the expr's dominant token) for the distillation-target ranking
IO.puts("\n=== MISMATCH BUCKETS ===")
mism
|> Enum.map(fn {e, _, _} -> cond do
     String.contains?(e, "Math.") -> "Math"; String.contains?(e, ".") and String.match?(e, ~r/"\w/) -> "String"
     String.contains?(e, "[") -> "Array"; String.contains?(e, "String(") or String.contains?(e, "Number(") -> "coerce"
     true -> "op" end end)
|> Enum.frequencies()
|> Enum.sort_by(fn {_, n} -> -n end)
|> Enum.each(fn {b, n} -> IO.puts("  #{String.pad_trailing(b, 10)} #{n}") end)
