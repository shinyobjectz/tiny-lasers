defmodule TinyLasers.Gate.F2DifferentialTest do
  @moduledoc """
  **Continuous differential gate (Track A / J2) — lossless byte-identity confidence.**

  Every program in `test/conformance/differential/` runs on BOTH node and F2 (the compiled Lower lane), and the
  output is compared byte-for-byte. The invariant that makes F2 trustworthy for untrusted code:

      any pure-JS program is byte-identical to node, OR F2 fails LOUDLY — it is NEVER silently wrong.

  A SILENT DIVERGENCE (F2 completes but produces different output than node) is the dangerous failure this gate
  exists to catch. An F2 error/timeout where node succeeded is a LOUD gap — surfaced here so it gets filled, not
  shipped. This is the seed of the harness; growing the corpus toward thousands of real programs is the J2 build.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.Js

  @corpus Path.join([__DIR__, "..", "conformance", "differential"])

  # run a program on node with F2's `print` shimmed to stdout; capture output lines.
  defp node_run(src) do
    tmp = Path.join(System.tmp_dir!(), "diff_#{System.unique_integer([:positive])}.js")
    File.write!(tmp, "globalThis.print=(x)=>console.log(String(x));\n" <> src)

    try do
      case System.cmd("node", [tmp], stderr_to_stdout: false) do
        # compare the FULL text (each print/console.log emits its value + a newline). Splitting per-line would
        # wrongly fragment a single print() of a multi-line value (e.g. JSON.stringify(v, null, 2)) — F2 captures
        # that as ONE output element, node writes it as several stdout lines. Join both to the same text.
        {out, 0} -> {:ok, String.trim_trailing(out, "\n")}
        {err, _} -> {:node_error, err}
      end
    after
      File.rm(tmp)
    end
  end

  for path <- Path.wildcard(Path.join(@corpus, "*.js")) do
    name = Path.basename(path)

    @tag :differential
    test "byte-identical F2↔node: #{name}" do
      src = File.read!(unquote(path))

      case node_run(src) do
        {:node_error, err} ->
          flunk("node itself failed on #{unquote(name)} (fix the corpus program):\n#{err}")

        {:ok, node_text} ->
          %{result: f2_res, output: f2_out} = Js.run(src)
          f2_text = Enum.join(f2_out, "\n")

          case f2_res do
            {:ok, _} ->
              # THE invariant: F2 completed, so it MUST match node byte-for-byte — no silent divergence.
              assert f2_text == node_text, """
              SILENT DIVERGENCE on #{unquote(name)} (F2 succeeded but differs from node):
                node: #{inspect(node_text)}
                F2:   #{inspect(f2_text)}
              """

            other ->
              # F2 did not complete — a LOUD gap (acceptable-not-shipped; fill the builtin). Never silent-wrong.
              flunk("F2 did not complete #{unquote(name)} (#{inspect(other)}) — a gap to fill, not a silent bug")
          end
      end
    end
  end
end
