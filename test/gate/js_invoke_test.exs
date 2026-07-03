defmodule TinyLasers.Gate.JsInvokeTest do
  @moduledoc """
  Locks `Js.invoke/3` — the production warm-module/cold-process entrypoint (Track A / J3): compile a guest ONCE
  per {tenant, source, grants} via the ModuleCache, run each invocation in a fresh resource-bounded process.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, ModuleCache}

  setup do
    name = :"jsmc_#{System.unique_integer([:positive])}"
    {:ok, pid} = ModuleCache.start_link(name: name, compile_cap: 3, max_entries: 50)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{cache: name}
  end

  test "invoke runs a guest and returns its output, compiling once across requests", %{cache: c} do
    src = "var n=0; for(var i=0;i<50;i++){ n+=i; } print('R['+n+']');"

    # 20 requests, all the same source+tenant → one compile, correct output every time
    for _ <- 1..20 do
      out = Js.invoke("acme", src, cache: c)
      assert out.output == ["R[1225]"], "wrong output: #{inspect(out.output)}"
    end

    assert %{entries: 1} = ModuleCache.stats(c)
  end

  test "cross-tenant + grant isolation: distinct modules, no shared cache entry", %{cache: c} do
    src = "print('x');"
    _ = Js.invoke("tenantA", src, cache: c)
    _ = Js.invoke("tenantB", src, cache: c)
    # same source, DIFFERENT grants → a different module (grants change lowering)
    _ = Js.invoke("tenantA", src, cache: c, granted: %{"print" => 0, "extra" => 1}, caps: %{0 => %{fun: &TinyLasers.Gate.Runtime.cap_print/2}, 1 => %{fun: &TinyLasers.Gate.Runtime.cap_print/2}})

    assert %{entries: 3} = ModuleCache.stats(c), "cross-tenant/grant variants must not share a cache entry"
  end

  test "resource bound still applies through invoke: a runaway guest is killed, not the host", %{cache: c} do
    # an allocating runaway — must be killed by the memory bound, never crash the test host
    out = Js.invoke("acme", "var a=[]; while(true){ a.push('x'.repeat(100000)); }", cache: c, max_heap_size: 6_500_000, timeout: 2_000)
    assert match?({:resource_killed, _}, out.result) or match?({:timeout, _}, out.result),
           "runaway guest was not contained: #{inspect(out.result)}"
    # host still works afterward
    assert Js.invoke("acme", "print('alive');", cache: c).output == ["alive"]
  end

  test "per-tenant compile cap (atom-DoS guard) surfaces through invoke", %{cache: c} do
    for i <- 1..3, do: assert Js.invoke("t", "var x=#{i}; print(''+x);", cache: c).output == ["#{i}"]
    # 4th DISTINCT program for this tenant exceeds the cap
    assert %{result: {:compile_cap, "t"}} = Js.invoke("t", "var y=99; print(''+y);", cache: c)
    # an already-cached program still runs
    assert Js.invoke("t", "var x=1; print(''+x);", cache: c).output == ["1"]
  end
end
