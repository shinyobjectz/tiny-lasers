defmodule Mix.Tasks.Test262.Gate do
  @moduledoc """
  Run the committed test262 slice through the **F2 / Gate lane** (JS→BEAM) — the confined native-compile
  frontend — and report the pass rate + the top failure signatures. Complements `mix test262` (the WASM/ASM
  lane). Runs the compiled `Lower` lane by default; `--walk` runs the tree-walk interpreter instead (the two
  are differential-locked, so they agree closely).

      mix test262.gate                 # Lower (compiled) lane
      mix test262.gate --walk          # Walk (interpreter) lane
      mix test262.gate --dir language/statements/let   # a subtree

  Each guest runs in a memory- and time-bounded process. The committed harness lives at
  `test/conformance/test262/harness`; the 419-case corpus is the curated HARD slice (the toughest cases) —
  F2 scores materially higher on the easy bulk of full test262, so treat this as a regression tripwire, not a
  headline conformance number.
  """
  @shortdoc "Run test262 (committed slice) on the F2/Gate lane; print pass% + failure signatures"
  use Mix.Task

  alias TinyLasers.Gate.{Js, Lower, Runtime, Walk}
  alias TinyLasers.Js.Test262

  @harness "test/conformance/test262/harness"

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(argv, strict: [walk: :boolean, dir: :string, verbose: :boolean])
    lane = if opts[:walk], do: :walk, else: :lower
    sub = opts[:dir] || ""

    cases = Path.wildcard("test/conformance/test262/cases/#{sub}**/*.js") |> Enum.sort()
    results = Enum.map(cases, &{&1, run_one(&1, lane)})
    ran = Enum.reject(results, fn {_, r} -> r == :skip end)
    pass = Enum.count(ran, fn {_, r} -> r == :pass end)

    Mix.shell().info(
      "\nF2 #{lane} lane test262: #{pass}/#{length(ran)} = " <>
        "#{Float.round(pass / max(length(ran), 1) * 100, 1)}%  (#{length(cases) - length(ran)} skipped)"
    )

    ran
    |> Enum.reject(fn {_, r} -> r == :pass end)
    |> Enum.map(fn {_, {:fail, sig}} -> signature(sig) end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, c} -> -c end)
    |> Enum.take(15)
    |> Enum.each(fn {s, c} -> Mix.shell().info("  #{c}\t#{s}") end)
  end

  defp signature({:threw, n}), do: "threw:#{n}"
  defp signature({:wrong_error, want, got}), do: "wrong_error want=#{want} got=#{got}"
  defp signature({:no_throw, want}), do: "no_throw expected=#{want}"
  defp signature({a, _, _}), do: to_string(a)
  defp signature({a, _}), do: to_string(a)
  defp signature(a) when is_atom(a), do: to_string(a)
  defp signature(other), do: inspect(other)

  defp run_one(path, lane) do
    body = File.read!(path)
    meta = Test262.parse_frontmatter(body)

    if Enum.any?([:module, :async, :raw], &(&1 in meta.flags)) do
      :skip
    else
      src = Test262.assemble(body, meta, harness_dir: @harness)

      case build(src, lane) do
        {:cerr, msg} -> classify(:none, msg, meta.negative)
        {:ok, runnable} -> classify(execute(runnable, lane), nil, meta.negative)
      end
    end
  end

  defp build(src, :lower) do
    b = Lower.program(Js.parse(src), %{})
    mod = Module.concat([TinyLasers.Gate.Guest, "T262#{System.unique_integer([:positive])}"])
    [{m, _}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(b) end) end)
    {:ok, {:mod, m}}
  rescue
    e -> {:cerr, Exception.message(e)}
  catch
    k, e -> {:cerr, inspect({k, e})}
  end

  defp build(src, :walk) do
    {:ok, {:ast, Js.parse(src)}}
  rescue
    e -> {:cerr, Exception.message(e)}
  catch
    k, e -> {:cerr, inspect({k, e})}
  end

  defp execute(runnable, _lane) do
    res =
      TinyLasers.Gate.bounded(
        fn ->
          Runtime.__init(%{caps: %{}, tenant_root: "/t", fs: %{}})

          try do
            case runnable do
              {:mod, m} -> apply(m, :run, [])
              {:ast, ast} -> Walk.run(ast, %{})
            end

            :completed
          catch
            :throw, {t, v} when t in [:gg_throw, :gg_guest_error] -> {:threw, err_name(v)}
            :throw, {:gg_return, _} -> :completed
            k, e -> {:hostcrash, inspect({k, e}, limit: 3)}
          end
        end,
        timeout: 5_000,
        max_heap_size: 67_108_864
      )

    case res do
      {:completed, o} -> o
      {:timeout} -> {:hostcrash, :timeout}
      {:killed, _} -> {:hostcrash, :killed}
      {:down, r} -> {:hostcrash, {:down, r}}
    end
  end

  # read a thrown error object's constructor name (in-child, where the runtime process dict is live).
  defp err_name(v) do
    case try_oget(v, "name") do
      n when is_binary(n) -> n
      _ -> (case try_oget(try_oget(v, "constructor"), "name") do n when is_binary(n) -> n; _ -> "Error" end)
    end
  end

  defp try_oget(v, k) do
    Runtime.oget(v, k)
  rescue
    _ -> :undefined
  catch
    _, _ -> :undefined
  end

  defp classify(outcome, compile_err, neg) do
    cond do
      neg != nil ->
        want = neg.type

        cond do
          compile_err != nil ->
            if want == "SyntaxError" and String.contains?(compile_err, "SyntaxError"), do: :pass, else: {:fail, {:neg_compile, want}}

          outcome == :completed ->
            {:fail, {:no_throw, want}}

          match?({:threw, _}, outcome) ->
            got = elem(outcome, 1)
            if got == want, do: :pass, else: {:fail, {:wrong_error, want, got}}

          true ->
            {:fail, {:neg_other, outcome}}
        end

      true ->
        cond do
          compile_err != nil -> {:fail, :compile_error}
          outcome == :completed -> :pass
          match?({:threw, _}, outcome) -> {:fail, {:threw, elem(outcome, 1)}}
          true -> {:fail, outcome}
        end
    end
  end
end
