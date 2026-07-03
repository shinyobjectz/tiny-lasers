defmodule TinyLasers.Gate.ModuleCache do
  @moduledoc """
  **Per-tenant module cache for the warm-module / cold-process execution model.**

  A guest program compiles to a `.beam` module ONCE and is then applied in a fresh, resource-bounded process per
  invocation (the object-store state dies with the process — see `f2-object-store-leak`). This cache holds the
  compiled modules so the compile cost + the permanent atom mint are paid once per distinct program, not per
  request.

  ## Isolation is the load-bearing property — content-addressing stays INSIDE a tenant

  Caching is content-addressed only within a single tenant's namespace: the key is `{tenant, sha256(source)}` and
  the module name is derived from `sha256(tenant <> source)`. There is **no cross-tenant content sharing**, so
  there is no cross-tenant compile-timing side channel (a tenant only ever hits its OWN cache). Sharing the
  compiled *code* would in fact be BEAM-safe — the pre-compile audit (`assert_safe_to_compile!/1`) proves a guest
  module is pure stateless `def`s (no attributes / `persistent_term` / ETS), so two processes running it share
  only read-only code, exactly like WASM instantiating one compiled module per tenant. We partition anyway
  because it costs almost nothing here and closes the timing/covert channel by construction.

  ## Atoms are permanent — the real bound is RESTART, not dedup

  `Code.compile_quoted` mints a permanent module atom; atoms are never GC'd within a node's lifetime. Dedup only
  MINIMIZES minting (compile each distinct program once per tenant); a per-tenant `compile_cap` bounds a single
  tenant's minting. The actual reclamation is a **recyclable compile worker** restarted when `atom_count`
  approaches a threshold — the BEAM-idiomatic answer (modules are deterministically recompilable from source, so
  a restart just rebuilds the cache lazily). `atom_pressure/0` exposes that watchdog signal.

  ## Purge safety

  Evicting a module that a process is mid-execution in would crash that process. Invocations bracket their run
  with `checkout/1` / `checkin/1` (lock-free ETS counters); eviction only reclaims a module with zero in-flight
  refs and uses `:code.soft_purge` (which itself refuses if any process still references the old code).
  """
  use GenServer

  # ETS table names are PER-INSTANCE (derived from the server name), so multiple caches — the supervised
  # singleton plus a test's transient one — coexist without clobbering each other's tables.

  @default_compile_cap 2_000
  @default_max_entries 4_000
  @default_atom_threshold 900_000

  # ── public API ──────────────────────────────────────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Resolve `source` (for `tenant`) to a compiled module, compiling once on a miss.

  `compile_fun` is `(module_name -> {module, binary})` — the caller compiles into the deterministic name we
  hand it (so an evict+recompile reuses the SAME atom). Returns `{:ok, module}` or `{:error, :compile_cap}` when
  the tenant has hit its distinct-program ceiling (atom-DoS guard).
  """
  def resolve(tenant, source, compile_fun, server \\ __MODULE__) when is_binary(source) and is_function(compile_fun, 1) do
    key = {tenant, :crypto.hash(:sha256, source)}

    case :ets.lookup(cache_tab(server), key) do
      [{^key, module, src_len, _}] when src_len == byte_size(source) ->
        # hit — bump recency (best-effort; racy last_used is fine for LRU) and return
        :ets.update_element(cache_tab(server), key, {4, mono()})
        {:ok, module}

      _ ->
        GenServer.call(server, {:compile, tenant, key, source, compile_fun}, 600_000)
    end
  end

  @doc "Mark a module as in-flight (prevents eviction of live code). Returns :ok."
  def checkout(module, server \\ __MODULE__) do
    :ets.update_counter(refs_tab(server), module, {2, 1}, {module, 0})
    :ok
  end

  @doc "Release an in-flight reference."
  def checkin(module, server \\ __MODULE__) do
    :ets.update_counter(refs_tab(server), module, {2, -1}, {module, 0})
    :ok
  end

  @doc "Run `fun` with `module` checked out for its whole lifetime (invocation bracket)."
  def with_module(module, fun, server \\ __MODULE__) do
    checkout(module, server)
    try do
      fun.()
    after
      checkin(module, server)
    end
  end

  @doc "Atom-table pressure in [0.0, 1.0] vs the configured threshold — the compile-worker-recycle signal."
  def atom_pressure(server \\ __MODULE__), do: GenServer.call(server, :atom_pressure)

  @doc "Under atom pressure, stop compiling NEW programs (cache hits + known-key recompiles still serve). Set by
  the AtomWatchdog; new distinct programs are then refused with {:error, :atom_pressure} until pressure drops."
  def set_compile_shedding(server \\ __MODULE__, on?) when is_boolean(on?),
    do: GenServer.call(server, {:set_compile_shedding, on?})

  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # ── the deterministic, per-tenant module name (same tenant+source → same atom, minted once) ──
  def module_name_for(tenant, source) do
    h = :crypto.hash(:sha256, :erlang.term_to_binary(tenant) <> <<0>> <> source) |> Base.encode16(case: :lower)
    Module.concat([TinyLasers.Gate.Guest, "M" <> binary_part(h, 0, 24)])
  end

  # ── GenServer ───────────────────────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    server = Keyword.get(opts, :name, __MODULE__)
    :ets.new(cache_tab(server), [:named_table, :public, :set, read_concurrency: true])
    :ets.new(refs_tab(server), [:named_table, :public, :set, write_concurrency: true])

    {:ok,
     %{
       server: server,
       compile_cap: Keyword.get(opts, :compile_cap, @default_compile_cap),
       max_entries: Keyword.get(opts, :max_entries, @default_max_entries),
       atom_threshold: Keyword.get(opts, :atom_threshold, @default_atom_threshold),
       # under atom pressure the AtomWatchdog flips this on; new distinct programs are then refused.
       compile_shedding: false,
       # tenant -> MapSet of keys compiled (distinct-program count for the cap)
       per_tenant: %{}
     }}
  end

  @impl true
  def handle_call({:compile, tenant, key, source, compile_fun}, _from, state) do
    case :ets.lookup(cache_tab(state.server), key) do
      # lost a race — another caller compiled it while we queued
      [{^key, module, src_len, _}] when src_len == byte_size(source) ->
        {:reply, {:ok, module}, state}

      _ ->
        tset = Map.get(state.per_tenant, tenant, MapSet.new())

        cond do
          MapSet.member?(tset, key) ->
            # key known to tenant but not in ETS (was evicted) — recompile into the SAME name (atom reused, so
            # this is allowed even under atom-pressure shedding).
            do_compile(tenant, key, source, compile_fun, tset, state)

          state.compile_shedding ->
            # atom pressure: refuse a NEW distinct program (it would mint a permanent atom). Cached tenants keep
            # working; the node drains toward a recycle.
            {:reply, {:error, :atom_pressure}, state}

          MapSet.size(tset) >= state.compile_cap ->
            {:reply, {:error, :compile_cap}, state}

          true ->
            do_compile(tenant, key, source, compile_fun, tset, state)
        end
    end
  end

  def handle_call(:atom_pressure, _from, state) do
    {:reply, :erlang.system_info(:atom_count) / state.atom_threshold, state}
  end

  def handle_call({:set_compile_shedding, on?}, _from, state) do
    {:reply, :ok, %{state | compile_shedding: on?}}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       entries: :ets.info(cache_tab(state.server), :size),
       tenants: map_size(state.per_tenant),
       atom_count: :erlang.system_info(:atom_count),
       atom_pressure: :erlang.system_info(:atom_count) / state.atom_threshold
     }, state}
  end

  defp do_compile(tenant, key, source, compile_fun, tset, state) do
    module_name = module_name_for(tenant, source)
    {module, _bin} = compile_fun.(module_name)

    :ets.insert(cache_tab(state.server), {key, module, byte_size(source), mono()})
    state = %{state | per_tenant: Map.put(state.per_tenant, tenant, MapSet.put(tset, key))}
    state = maybe_evict(state)
    {:reply, {:ok, module}, state}
  end

  # LRU eviction to bound LOADED CODE memory (NOT atoms — atoms need restart). Evicts the oldest entry with no
  # in-flight refs, purge-safe. Does not touch per_tenant counts (the atom stays; a re-request recompiles into it).
  defp maybe_evict(state) do
    ct = cache_tab(state.server)

    if :ets.info(ct, :size) <= state.max_entries do
      state
    else
      candidates =
        :ets.tab2list(ct)
        |> Enum.map(fn {k, mod, _len, used} -> {used, k, mod} end)
        |> Enum.sort()

      Enum.find_value(candidates, state, fn {_used, k, mod} ->
        if in_flight(state.server, mod) == 0 and :code.soft_purge(mod) do
          :code.delete(mod)
          :ets.delete(ct, k)
          :ets.delete(refs_tab(state.server), mod)
          state
        else
          false
        end
      end)
    end
  end

  defp in_flight(server, mod) do
    case :ets.lookup(refs_tab(server), mod) do
      [{^mod, n}] -> n
      _ -> 0
    end
  end

  defp cache_tab(server), do: :"tl_mc_#{server}"
  defp refs_tab(server), do: :"tl_mcr_#{server}"

  defp mono, do: :erlang.monotonic_time()
end
