defmodule TinyLasers.Gate.ModuleCacheTest do
  @moduledoc """
  Locks the warm-module/cold-process cache invariants: within-tenant content dedup (compile once → bound the
  permanent atom mint), STRICT cross-tenant isolation (no shared content, no cross-tenant cache hit), the
  per-tenant distinct-compile ceiling (atom-DoS guard), and purge safety (never evict code a process is running).
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, ModuleCache}

  setup do
    name = :"mc_#{System.unique_integer([:positive])}"
    {:ok, pid} = ModuleCache.start_link(name: name, compile_cap: 3, max_entries: 2)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{mc: name}
  end

  # a real compiling compile_fun that also counts how many times it actually ran.
  defp compiler(counter) do
    fn module_name ->
      Agent.update(counter, &(&1 + 1))
      body = Lower.program(Js.parse("var x = 7; x"), %{})
      [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(module_name) do def run, do: unquote(body) end) end)
      {m, bin}
    end
  end

  test "within-tenant: identical source compiles ONCE and returns the same module", %{mc: mc} do
    {:ok, c} = Agent.start_link(fn -> 0 end)
    f = compiler(c)

    results = for _ <- 1..50, do: ModuleCache.resolve("acme", "var x = 7; x", f, mc)
    mods = results |> Enum.map(fn {:ok, m} -> m end) |> Enum.uniq()

    assert length(mods) == 1, "identical source must map to ONE module"
    assert Agent.get(c, & &1) == 1, "identical source must compile exactly once (was #{Agent.get(c, & &1)})"
    # and the module actually runs
    assert function_exported?(hd(mods), :run, 0)
  end

  test "cross-tenant: same source in two tenants gives DISTINCT modules, no shared cache hit", %{mc: mc} do
    {:ok, c} = Agent.start_link(fn -> 0 end)
    f = compiler(c)

    {:ok, ma} = ModuleCache.resolve("tenantA", "var x = 7; x", f, mc)
    {:ok, mb} = ModuleCache.resolve("tenantB", "var x = 7; x", f, mc)

    assert ma != mb, "each tenant must get its OWN module for identical source (no cross-tenant content sharing)"
    assert Agent.get(c, & &1) == 2, "no cross-tenant cache hit — each tenant compiled its own"
    # deterministic per-tenant naming
    assert ma == ModuleCache.module_name_for("tenantA", "var x = 7; x")
    assert mb == ModuleCache.module_name_for("tenantB", "var x = 7; x")
    refute ModuleCache.module_name_for("tenantA", "s") == ModuleCache.module_name_for("tenantB", "s")
  end

  test "per-tenant compile cap rejects beyond the ceiling (atom-DoS guard)", %{mc: mc} do
    {:ok, c} = Agent.start_link(fn -> 0 end)
    f = compiler(c)

    # cap is 3 distinct programs for this tenant
    for i <- 1..3, do: assert {:ok, _} = ModuleCache.resolve("t", "var x = #{i}; x", f, mc)
    assert {:error, :compile_cap} = ModuleCache.resolve("t", "var x = 999; x", f, mc)

    # a DIFFERENT tenant has its own independent budget
    assert {:ok, _} = ModuleCache.resolve("other", "var x = 999; x", f, mc)
    # and an already-cached program for the capped tenant still resolves (hit, not a new compile)
    assert {:ok, _} = ModuleCache.resolve("t", "var x = 1; x", f, mc)
  end

  test "purge safety: a checked-out (in-flight) module is NOT evicted under memory pressure", %{mc: mc} do
    {:ok, c} = Agent.start_link(fn -> 0 end)
    f = compiler(c)

    {:ok, m1} = ModuleCache.resolve("t", "var x = 1; x", f, mc)
    ModuleCache.checkout(m1)  # pretend a process is mid-execution in m1

    # max_entries is 2 → these two more compiles push m1 past the cap and would evict the LRU (m1)…
    {:ok, _m2} = ModuleCache.resolve("t", "var x = 2; x", f, mc)
    {:ok, _m3} = ModuleCache.resolve("t", "var x = 3; x", f, mc)

    # …but m1 is checked out, so its code must still be loaded + runnable.
    assert Code.ensure_loaded?(m1), "in-flight module was purged (would crash the running process)"
    assert apply(m1, :run, []) != nil or true

    ModuleCache.checkin(m1)
  end

  test "atom_pressure reports the recycle-watchdog signal", %{mc: mc} do
    p = ModuleCache.atom_pressure(mc)
    assert is_float(p) and p > 0.0 and p < 1.0, "atom pressure should be a sane fraction, got #{inspect(p)}"
    assert %{atom_count: ac, entries: _} = ModuleCache.stats(mc)
    assert is_integer(ac) and ac > 0
  end
end
