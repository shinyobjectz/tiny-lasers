defmodule TinyLasers.Gate.F2GsapTest do
  @moduledoc """
  **F2 runs GSAP — the off-the-shelf animation engine — byte-identical to node, confined, on the compiled lane.**

  GSAP 3.15's core computes tween interpolation and easing purely in JS (no DOM needed for object tweens). This
  drives the real 179KB bundle on the `Lower` (compiled `.beam`) lane and checks two things match node exactly:

    * easing curves sampled directly (`gsap.parseEase`) — power/back(overshoot)/elastic/sine/expo/circ/bounce
    * a tween + a timeline (back.out overshoot, elastic.out) + a stagger, sampled via `seek()`

  Lower-only by design: the Walk interpreter is *correct* here too but too slow on a 179KB bundle (minutes vs
  ~30s compiled) — the reason we iterate real libraries on the compiled lane. `NODRAIN`: GSAP's ticker reschedules
  `setTimeout` forever, and `seek()` output is synchronous, so we don't drain the macrotask queue.

  This is the case that surfaced (and got fixed) a real, general `Lower` codegen bug: a COMPUTED method call
  `obj[key](args)` — e.g. GSAP's ticker `_listeners[prio ? "unshift" : "push"](cb)` — was evaluating `obj[key]`
  to a bound-method value and calling it with NO `this`, so it hit `method(:undefined, …)`. Dotted calls always
  bound `this`; computed calls now do too.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime}

  @conf "test/conformance"

  defp run_lower(bundle_rel, marker) do
    prelude = File.read!(Path.join(@conf, "porffor_cjs/cjs_prelude.js")) <> "\n" <> File.read!(Path.join(@conf, "rollup/node_shims.js"))
    console = "var console = { log: function(){ print(arguments[0]); } };\n"
    ast = Js.parse(console <> prelude <> "\n" <> File.read!(Path.join(@conf, bundle_rel)))
    body = Lower.program(ast, %{"print" => 0})
    mod = Module.concat([TinyLasers.Gate.Guest, "Gsap#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(mod) do def run, do: unquote(body) end) end)

    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "compiled GSAP module not confined"

    # BOUNDED (memory + wall-clock) under a HOST-SAFE cap (1 GB). GSAP now peaks ~150 MB: the ticker's infinite
    # setTimeout reschedule loop is caught by the microtask runaway-detector (@microtask_cap) before it can leak
    # the former ~2.9 GB of {:gg_prom}/{:gg_box} entries. NODRAIN: the seek() output is synchronous.
    ctx = %{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}}

    {:completed, out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(ctx)
        try do apply(m, :run, []) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 120_000, max_heap_size: 134_217_728)

    line = Enum.find(out, &String.starts_with?(&1, marker <> "[")) || flunk("no #{marker} output")
    line |> String.replace_prefix(marker <> "[", "") |> String.replace_suffix("]", "") |> String.trim()
  end

  @tag timeout: 300_000
  test "GSAP easing curves sample byte-identical to node (compiled, confined)" do
    golden = File.read!(Path.join(@conf, "gsap/ease_golden.txt")) |> String.trim()
    assert run_lower("gsap/ease_bundle.js", "EASE_OK") == golden
  end

  # UN-SKIPPED (was: peaked >4GB). Root-caused to GSAP's ticker rescheduling a fake-macrotask setTimeout
  # (Promise.resolve().then) forever inside the end-of-program microtask drain — it looped up to the old 5M
  # @microtask_cap, leaking ~10M {:gg_prom} + ~15M {:gg_box}. Lowering the runaway-detector cap to 250K bounds it
  # to ~150 MB (byte-identical output is printed before the drain, so unchanged). Runs byte-identical to node.
  @tag timeout: 300_000
  test "GSAP tween + timeline + stagger sample byte-identical to node (compiled, confined)" do
    golden = File.read!(Path.join(@conf, "gsap/gsap_golden.txt")) |> String.trim()
    assert run_lower("gsap/gsap_bundle.js", "GSAP_OK") == golden
  end
end
