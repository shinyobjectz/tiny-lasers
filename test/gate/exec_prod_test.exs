defmodule TinyLasers.Gate.ExecProdTest do
  @moduledoc """
  Production execution model, end to end against the SUPERVISED singletons (started by TinyLasers.Application):
  the module cache, metering, admission control, and the atom-pressure watchdog — plus an empirical load test.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Exec, Meter, Admission, ModuleCache, AtomWatchdog}

  setup do
    # a fresh tenant id per test isolates per-tenant counters/limits on the shared singletons.
    Admission.set_shedding(false)
    %{t: "tenant_#{System.unique_integer([:positive])}"}
  end

  test "the execution-model tier is supervised and alive" do
    for name <- [ModuleCache, Meter, Admission, AtomWatchdog] do
      assert is_pid(Process.whereis(name)), "#{inspect(name)} not started under the supervisor"
    end
  end

  test "Exec.invoke admits, runs, and meters", %{t: t} do
    out = Exec.invoke(t, "var n=0; for(var i=0;i<10;i++){n+=i;} print('R['+n+']');")
    assert out.admitted
    assert out.output == ["R[45]"]
    assert match?({:ok, _}, out.result)

    # a second request for the same source → cache hit (compile once), still correct
    assert Exec.invoke(t, "var n=0; for(var i=0;i<10;i++){n+=i;} print('R['+n+']');").output == ["R[45]"]

    stats = Meter.stats(t)
    assert stats[:invocations] == 2
    assert stats[:ok] == 2
    assert stats[:total_us] > 0
  end

  test "admission — rate limit rejects excess and meters the rejection", %{t: t} do
    # 5 rps cap: the 6th within the same 1s window is rejected
    results = for _ <- 1..8, do: Exec.invoke(t, "print('ok');", max_rps: 5)
    admitted = Enum.count(results, & &1.admitted)
    rejected = Enum.count(results, &match?({:rejected, :rate_limited}, &1.result))

    assert admitted == 5, "expected exactly the cap admitted, got #{admitted}"
    assert rejected == 3
    assert Meter.stats(t)[:rejections] == 3
  end

  test "admission — per-tenant concurrency limit + release", %{t: t} do
    # occupy the tenant's in-flight slots manually, then admit should reject; release frees them
    assert :ok = Admission.admit(t, max_inflight: 2)
    assert :ok = Admission.admit(t, max_inflight: 2)
    assert {:error, :tenant_overloaded} = Admission.admit(t, max_inflight: 2)
    assert Admission.inflight(t) == 2
    Admission.release(t)
    assert :ok = Admission.admit(t, max_inflight: 2)
    Admission.release(t)
    Admission.release(t)
  end

  test "atom watchdog — soft sheds new compiles, hard triggers recycle", %{t: t} do
    cache = :"wc_#{System.unique_integer([:positive])}"
    {:ok, _} = ModuleCache.start_link(name: cache)
    {:ok, recycled} = Agent.start_link(fn -> 0 end)
    {:ok, press} = Agent.start_link(fn -> 0.1 end)

    {:ok, wd} =
      AtomWatchdog.start_link(
        name: :"wd_#{System.unique_integer([:positive])}",
        cache: cache,
        soft: 0.7,
        hard: 0.9,
        interval_ms: 3_600_000,
        pressure_fun: fn -> Agent.get(press, & &1) end,
        recycle: fn -> Agent.update(recycled, &(&1 + 1)) end
      )

    cf = fn name ->
      body = TinyLasers.Gate.Lower.program(TinyLasers.Gate.Js.parse("var x=1;x"), %{})
      [{m, b}] = Code.compile_quoted(quote do (defmodule unquote(name) do def run, do: unquote(body) end) end)
      {m, b}
    end

    # normal pressure → compiles allowed
    Agent.update(press, fn _ -> 0.1 end); AtomWatchdog.check_now(wd)
    assert AtomWatchdog.health(wd) == :ok
    assert {:ok, _} = ModuleCache.resolve(t, "var a=1;a", cf, cache)

    # SOFT pressure → new compiles refused (cached ones still serve), NOT yet recycled
    Agent.update(press, fn _ -> 0.75 end); AtomWatchdog.check_now(wd)
    assert AtomWatchdog.health(wd) == :shedding
    assert {:error, :atom_pressure} = ModuleCache.resolve(t, "var brand_new=2;brand_new", cf, cache)
    assert {:ok, _} = ModuleCache.resolve(t, "var a=1;a", cf, cache)  # already-cached → still works
    assert Agent.get(recycled, & &1) == 0

    # HARD pressure → recycle callback fires
    Agent.update(press, fn _ -> 0.95 end); AtomWatchdog.check_now(wd)
    assert AtomWatchdog.health(wd) == :critical
    assert Agent.get(recycled, & &1) == 1

    GenServer.stop(wd); GenServer.stop(cache)
  end

  test "prewarm compiles ahead so the first request is a cache hit", %{t: t} do
    src = "print('warmed');"
    assert %{compiled: 1} = Exec.prewarm(t, [src])
    before = ModuleCache.stats().entries
    out = Exec.invoke(t, src)
    assert out.output == ["warmed"]
    # invoke did NOT add a cache entry (it hit the prewarmed one)
    assert ModuleCache.stats().entries == before
  end

  test "graceful drain: sheds new admissions and waits for in-flight to clear", %{t: t} do
    # hold an in-flight slot open, then drain concurrently — it must wait, then complete when we release.
    assert :ok = Admission.admit(t)
    assert Admission.global_inflight() >= 1

    task = Task.async(fn -> Exec.drain(5_000) end)
    Process.sleep(50)
    # during the drain, new invocations are shed (admission refused)
    assert %{result: {:rejected, :atom_pressure}} = Exec.invoke(t, "print('x');")
    refute Task.yield(task, 0), "drain returned before in-flight cleared"

    Admission.release(t)
    assert Task.await(task, 5_000) == :drained
    Admission.set_shedding(false)
  end

  test "health snapshot reports live tier state" do
    h = Exec.health()
    assert is_float(h.atom_pressure)
    assert h.atom_health in [:ok, :shedding, :critical]
    assert is_map(h.meter) and is_map(h.cache)
  end

  @tag timeout: 120_000
  test "LOAD: thousands of concurrent invocations — correct, metered, memory-flat, runaway-contained" do
    tenants = for i <- 1..8, do: "load_#{i}_#{System.unique_integer([:positive])}"
    src = "var n=0; for(var i=0;i<40;i++){ var t=[i,i*2]; n+=t[1]; } print('R['+n+']');"
    n = 4000

    :erlang.garbage_collect()
    m0 = :erlang.memory(:total)

    {wall, results} =
      :timer.tc(fn ->
        1..n
        |> Task.async_stream(
          fn i ->
            t = Enum.at(tenants, rem(i, length(tenants)))
            Exec.invoke(t, src, max_rps: 1_000_000, max_inflight: 5_000)
          end,
          max_concurrency: 100, timeout: 60_000, ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)
      end)

    :erlang.garbage_collect()
    grew = :erlang.memory(:total) - m0

    ok = Enum.count(results, &(&1.output == ["R[1560]"]))
    assert ok == n, "only #{ok}/#{n} invocations produced correct output"

    # metering is accurate across tenants
    metered = tenants |> Enum.map(&(Meter.stats(&1)[:invocations] || 0)) |> Enum.sum()
    assert metered == n, "metered #{metered} invocations, expected #{n}"

    # memory FLAT — per-request object store dies with each cold process (not O(requests))
    assert grew < 30_000_000, "host grew #{div(grew, 1024)}KB across #{n} requests — expected ~flat"

    # a runaway guest is still contained through the full production path (host survives)
    kill = Exec.invoke(hd(tenants), "var a=[]; while(true){ a.push('x'.repeat(100000)); }", max_heap_size: 6_500_000, timeout: 2_000, max_rps: 1_000_000, max_inflight: 5_000)
    assert match?({:resource_killed, _}, kill.result) or match?({:timeout, _}, kill.result),
           "runaway not contained through the production path: #{inspect(kill.result)}"

    rps = round(n / (wall / 1_000_000))
    IO.puts("LOAD: #{n} invocations in #{div(wall, 1000)}ms = #{rps} req/s across #{length(tenants)} tenants, host grew #{div(grew, 1024)}KB")
    assert rps > 1_000, "throughput #{rps} req/s unexpectedly low"
  end
end
