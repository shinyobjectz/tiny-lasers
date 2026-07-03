defmodule TinyLasers.Gate.Admission do
  @moduledoc """
  Admission control for the execution model: before a guest invocation runs it must be admitted, bounding what
  any one tenant (or the node) can consume. Three gates, checked cheaply and lock-free on the hot path:

    * **rate** — a fixed 1-second window counter per tenant (`max_rps`).
    * **concurrency** — in-flight invocations per tenant (`max_inflight`) and node-wide (`max_global_inflight`).
    * **atom-pressure shedding** — a flag the `AtomWatchdog` raises; when set, admission is refused so the node
      can drain toward a recycle (atoms are permanent — see `f2-execution-model`).

  `admit/1` returns `:ok` (and has incremented the in-flight counters — the caller MUST `release/1`) or
  `{:error, reason}`. The GenServer owns table lifecycle + periodic cleanup of stale rate windows.
  """
  use GenServer

  @inflight :tl_inflight
  @rate :tl_rate
  @ctl :tl_admission_ctl
  @global :__global__

  @defaults %{max_rps: 1_000, max_inflight: 64, max_global_inflight: 4_000}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Admit an invocation for `tenant`. On :ok the in-flight counters are incremented — pair with release/1."
  def admit(tenant, opts \\ []) do
    cfg = config(opts)

    cond do
      shedding?() -> {:error, :atom_pressure}
      not rate_ok?(tenant, cfg.max_rps) -> {:error, :rate_limited}
      true -> reserve_inflight(tenant, cfg)
    end
  end

  @doc "Release an in-flight slot taken by a successful admit/1."
  def release(tenant) do
    :ets.update_counter(@inflight, tenant, {2, -1}, {tenant, 0})
    :ets.update_counter(@inflight, @global, {2, -1}, {@global, 0})
    :ok
  end

  @doc "Raise/lower the atom-pressure shedding flag (called by AtomWatchdog)."
  def set_shedding(on?) when is_boolean(on?), do: (ensure(); :ets.insert(@ctl, {:shedding, on?}); :ok)
  def shedding?, do: match?([{:shedding, true}], safe_lookup(@ctl, :shedding))

  @doc "Current in-flight counts, for observability."
  def inflight(tenant), do: counter(@inflight, tenant)
  def global_inflight, do: counter(@inflight, @global)

  # ── hot-path helpers (lock-free) ──

  defp rate_ok?(tenant, max_rps) do
    window = System.system_time(:second)
    :ets.update_counter(@rate, {tenant, window}, {2, 1}, {{tenant, window}, 0}) <= max_rps
  end

  defp reserve_inflight(tenant, cfg) do
    g = :ets.update_counter(@inflight, @global, {2, 1}, {@global, 0})
    t = :ets.update_counter(@inflight, tenant, {2, 1}, {tenant, 0})

    cond do
      g > cfg.max_global_inflight -> undo_inflight(tenant); {:error, :node_overloaded}
      t > cfg.max_inflight -> undo_inflight(tenant); {:error, :tenant_overloaded}
      true -> :ok
    end
  end

  defp undo_inflight(tenant) do
    :ets.update_counter(@inflight, tenant, {2, -1}, {tenant, 0})
    :ets.update_counter(@inflight, @global, {2, -1}, {@global, 0})
  end

  defp counter(table, key) do
    case safe_lookup(table, key) do
      [{^key, n}] -> n
      _ -> 0
    end
  end

  defp config(opts), do: Map.merge(@defaults, Map.new(Keyword.take(opts, [:max_rps, :max_inflight, :max_global_inflight])))

  defp safe_lookup(table, key) do
    case :ets.whereis(table) do
      :undefined -> []
      _ -> :ets.lookup(table, key)
    end
  end

  defp ensure do
    if :ets.whereis(@ctl) == :undefined do
      :ets.new(@ctl, [:named_table, :public, :set, read_concurrency: true])
    end
  end

  # ── GenServer: lifecycle + stale-window cleanup ──

  @impl true
  def init(_opts) do
    :ets.new(@inflight, [:named_table, :public, :set, write_concurrency: true, read_concurrency: true])
    :ets.new(@rate, [:named_table, :public, :set, write_concurrency: true])
    :ets.new(@ctl, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(@ctl, {:shedding, false})
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # drop rate-window rows older than 2s (the current + previous window are all we need)
    cutoff = System.system_time(:second) - 2
    :ets.select_delete(@rate, [{{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, 5_000)
end
