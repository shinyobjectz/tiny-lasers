defmodule TinyLasers.Gate.Meter do
  @moduledoc """
  Per-tenant invocation accounting for the warm-module / cold-process execution model. The hot path
  (`record/3`, `record_rejection/2`) is lock-free ETS `update_counter` — safe under high concurrency. The
  GenServer only owns the table's lifecycle. Read aggregates with `stats/1` (per tenant) or `totals/0`.
  """
  use GenServer

  @table :tl_meter

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Record a completed invocation: bumps count + total wall-µs, and a per-outcome counter."
  def record(tenant, duration_us, result) do
    bump(tenant, :invocations, 1)
    bump(tenant, :total_us, max(0, duration_us))

    outcome =
      case result do
        {:ok, _} -> :ok
        {:resource_killed, _} -> :resource_kills
        {:timeout, _} -> :timeouts
        {:guest_error, _} -> :guest_errors
        _ -> :errors
      end

    bump(tenant, outcome, 1)
    :ok
  end

  @doc "Record an admission rejection (rate-limited / overloaded / atom-pressure), tagged by reason."
  def record_rejection(tenant, reason) do
    bump(tenant, :rejections, 1)
    bump(tenant, {:rejected, reason}, 1)
    :ok
  end

  @doc "All counters for a tenant as a map."
  def stats(tenant) do
    case :ets.whereis(@table) do
      :undefined -> %{}
      _ -> :ets.match_object(@table, {{tenant, :_}, :_}) |> Map.new(fn {{_, m}, v} -> {m, v} end)
    end
  end

  @doc "Aggregate counters across all tenants (for node-level health/observability)."
  def totals do
    case :ets.whereis(@table) do
      :undefined ->
        %{}

      _ ->
        :ets.foldl(
          fn {{_tenant, metric}, v}, acc -> Map.update(acc, metric, v, &(&1 + v)) end,
          %{},
          @table
        )
    end
  end

  defp bump(tenant, metric, n),
    do: :ets.update_counter(@table, {tenant, metric}, {2, n}, {{tenant, metric}, 0})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true, read_concurrency: true])
    {:ok, %{}}
  end
end
