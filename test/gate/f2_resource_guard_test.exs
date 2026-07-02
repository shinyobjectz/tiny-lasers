defmodule TinyLasers.Gate.F2ResourceGuardTest do
  @moduledoc """
  **NON-NEGOTIABLE SANDBOX INVARIANT: guest code can NEVER exhaust host resources.**

  Untrusted guest JS compiles to native BEAM and runs at native speed — so an infinite loop, unbounded heap
  allocation, unbounded *binary* (string) allocation, or runaway recursion would OOM / peg the host if run
  unbounded. Every guest run therefore goes through `Gate.bounded/2` (and `Js.run`, `run_isolated`, `bounded_run`
  built on it): a monitored child process capped by `max_heap_size{kill, include_shared_binaries}` (memory,
  including off-heap refc binaries) AND a wall-clock timeout (CPU). This test proves each exhaustion vector is
  contained and the host survives — if it ever fails, guest code can crash the machine and that is a P0.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.Js

  # deliberately tight bounds — even a guard regression can't hurt the test host: ~50 MB heap, 2 s wall-clock.
  @opts [max_heap_size: 6_500_000, timeout: 2_000]

  defp run(src), do: Js.run(src, @opts)

  test "a normal guest completes and returns its output" do
    r = run(~S|print("ok"); print("done");|)
    assert r.result == {:ok, :undefined}
    assert r.output == ["ok", "done"]
  end

  # containment is the invariant: a bomb is CONTAINED if it is killed (memory) or timed out (wall-clock) —
  # either way the guest is dead and the host is unharmed. The specific mechanism is checked per-vector below.
  defp contained?(%{result: {:resource_killed, _}}), do: true
  defp contained?(%{result: {:timeout, _}}), do: true
  defp contained?(_), do: false

  test "unbounded on-heap DATA growth is contained (never completes, never harms the host)" do
    r = run(~S|var o = {}; var i = 0; while (true) { o[i] = "v" + i; i = i + 1; }|)
    assert contained?(r), "on-heap bomb was not contained: #{inspect(r.result)}"
  end

  test "unbounded BINARY (string) allocation is killed by the memory cap — the off-heap vector" do
    # big strings live off-heap; without include_shared_binaries this would evade the heap cap and OOM the host.
    r = run(~S|var a = []; while (true) { a.push("x".repeat(100000)); }|)
    assert r.result == {:resource_killed, :max_heap_size}, "binary bomb escaped the memory cap: #{inspect(r.result)}"
  end

  test "an infinite CPU loop (no allocation) is killed by the wall-clock timeout" do
    r = run(~S|var i = 0; while (true) { i = i + 1; }|)
    assert r.result == {:timeout, nil}
  end

  test "runaway recursion is killed by the memory cap" do
    r = run(~S|function f(n) { return f(n + 1) + 1; } f(0);|)
    assert r.result == {:resource_killed, :max_heap_size}
  end

  test "the host process is unharmed after running every bomb" do
    before = :erlang.memory(:total)

    for src <- [
          ~S|var a = []; while (true) { a.push("x".repeat(100000)); }|,
          ~S|var i = 0; while (true) { i = i + 1; }|,
          ~S|function f(n) { return f(n + 1) + 1; } f(0);|
        ] do
      run(src)
    end

    # a real change to product source always has a runtime surface to drive.
    grew_mb = div(:erlang.memory(:total) - before, 1_000_000)
    assert grew_mb < 100, "host heap grew #{grew_mb}MB running guest bombs — containment leaked"
    assert run(~S|print("host still works");|).output == ["host still works"]
  end
end
