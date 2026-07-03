defmodule TinyLasers.Gate.F2ExecModelTest do
  @moduledoc """
  **Red-team + invariants for the warm-module / cold-process execution model.**

  The model reuses one compiled module across many requests, running each in a FRESH resource-bounded process.
  Its security rests on: (1) a shared module is pure read-only code (no cross-invocation state can bleed through
  it); (2) each invocation gets a clean process (the object-store dies with it); (3) the cache is host-side and
  structurally unreachable from guest code; (4) tenants are partitioned. This locks (1)+(2)+(4) end-to-end and
  measures the warm-path latency (3) is covered by the confinement audit — a guest module references only the
  Runtime, never the cache.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate.{Js, Lower, Runtime, ModuleCache}

  defp compile(src) do
    body = Lower.program(Js.parse(src), %{"print" => 0})
    name = Module.concat([TinyLasers.Gate.Guest, "EM#{System.unique_integer([:positive])}"])
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(name) do def run, do: unquote(body) end) end)
    {m, bin}
  end

  defp invoke(m) do
    {:completed, out} =
      TinyLasers.Gate.bounded(fn ->
        Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
        try do apply(m, :run, []) catch :throw, _ -> :ok end
        Runtime.__output()
      end, timeout: 10_000, max_heap_size: 33_554_432)

    out
  end

  test "NO cross-invocation state bleed: the same module in fresh processes gives each request a clean slate" do
    # a stateful guest — mutates a GLOBAL and an object across the run. If state bled between invocations
    # (shared process dict / module-level state), the counter would climb 1,2,3…; it must be 1 every time.
    {m, bin} = compile("""
      if (typeof globalThis.__hits === 'undefined') { globalThis.__hits = 0; }
      globalThis.__hits = globalThis.__hits + 1;
      var acc = []; for (var i = 0; i < 100; i++) { acc.push(i); }
      print('hits=' + globalThis.__hits + ' acc=' + acc.length);
    """)

    assert %{ext: [], bifs: []} = TinyLasers.Gate.dangerous_refs(bin), "guest module references a host thing"
    # confinement: the compiled guest references ONLY the Runtime — never the ModuleCache/its ETS tables.
    refute Enum.any?(refs(bin), &(&1 == TinyLasers.Gate.ModuleCache)), "guest can reach the module cache"

    for _ <- 1..5 do
      assert invoke(m) == ["hits=1 acc=100"], "state bled across invocations (fresh-process isolation broken)"
    end
  end

  test "cross-tenant module isolation is structural: tenants get distinct modules, keyed host-side" do
    name = :"em_#{System.unique_integer([:positive])}"
    {:ok, _} = ModuleCache.start_link(name: name, compile_cap: 100, max_entries: 100)
    src = "print('x');"
    cf = fn n -> compile_into(n, src) end

    {:ok, ma} = ModuleCache.resolve("tenantA", src, cf, name)
    {:ok, mb} = ModuleCache.resolve("tenantB", src, cf, name)

    assert ma != mb
    # a guest never supplies or sees the module name — the HOST derives it from {tenant, source}. There is no
    # guest-controllable path from tenant A into tenant B's module.
    assert ma == ModuleCache.module_name_for("tenantA", src)
    assert mb == ModuleCache.module_name_for("tenantB", src)
  end

  test "warm-path latency: a cache hit is microseconds (cold-start = compile is paid once)" do
    name = :"em_#{System.unique_integer([:positive])}"
    {:ok, _} = ModuleCache.start_link(name: name, compile_cap: 100, max_entries: 100)
    src = "var a=1; var b=a+2; b"
    cf = fn n -> compile_into(n, src) end

    {cold_us, {:ok, _}} = :timer.tc(fn -> ModuleCache.resolve("t", src, cf, name) end)
    {warm_us, {:ok, _}} = :timer.tc(fn -> ModuleCache.resolve("t", src, cf, name) end)

    assert warm_us < cold_us, "a cache hit must be cheaper than the cold compile (cold=#{cold_us}us warm=#{warm_us}us)"
    assert warm_us < 1_000, "a warm hit should be well under 1ms, got #{warm_us}us"
  end

  test "END-TO-END: the full warm-module/cold-process path — compile once, run N times, correct + flat" do
    name = :"em_#{System.unique_integer([:positive])}"
    {:ok, _} = ModuleCache.start_link(name: name, compile_cap: 100, max_entries: 100)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    src = """
    var n = 0; for (var i = 0; i < 200; i++) { var t = [i, i * 2]; n += t[1]; }
    print('R[' + n + ']');
    """

    cf = fn module_name ->
      Agent.update(counter, &(&1 + 1))
      compile_into(module_name, src)
    end

    # one full production invocation: cache-resolve (compile once) -> checkout -> FRESH bounded process -> checkin
    request = fn tenant ->
      {:ok, mod} = ModuleCache.resolve(tenant, src, cf, name)

      ModuleCache.with_module(mod, fn ->
        {:completed, out} =
          TinyLasers.Gate.bounded(fn ->
            Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})
            try do apply(mod, :run, []) catch :throw, _ -> :ok end
            Runtime.__output()
          end, timeout: 10_000, max_heap_size: 33_554_432)

        out
      end, name)
    end

    request.("acme")
    :erlang.garbage_collect()
    m0 = :erlang.memory(:total)

    # 1000 requests through the SAME warm module, each a fresh cold process
    Enum.each(1..1000, fn _ -> assert request.("acme") == ["R[39800]"], "request produced wrong/inconsistent output" end)

    :erlang.garbage_collect()
    grew = :erlang.memory(:total) - m0

    assert Agent.get(counter, & &1) == 1, "the module must compile exactly ONCE across 1000 requests"
    # FLAT: 1000 fresh-process requests must not accumulate host memory (the per-request object store dies with
    # each process). A long-lived guest doing the same work would grow ~O(requests); this stays bounded.
    assert grew < 20_000_000, "host memory grew #{div(grew, 1024)}KB across 1000 requests — expected ~flat"
  end

  defp compile_into(name, src) do
    body = Lower.program(Js.parse(src), %{"print" => 0})
    [{m, bin}] = Code.compile_quoted(quote do (defmodule unquote(name) do def run, do: unquote(body) end) end)
    {m, bin}
  end

  defp refs(bin) do
    {:ok, {_, [{:imports, imports}]}} = :beam_lib.chunks(bin, [:imports])
    imports |> Enum.map(fn {mod, _f, _a} -> mod end) |> Enum.uniq()
  end
end
