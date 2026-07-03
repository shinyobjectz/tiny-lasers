defmodule TinyLasers.Gate.AtomWatchdog do
  @moduledoc """
  Atoms are permanent within a BEAM node (`Code.compile_quoted` mints a module atom per distinct guest program).
  Dedup + per-tenant caps *minimize* the mint; the only true reclamation is a **node recycle**. This watchdog is
  the signal that drives it:

    * at `soft` pressure it tells the `ModuleCache` to stop compiling NEW programs (cache hits still serve — the
      node keeps working for existing tenants, it just stops minting new atoms);
    * at `hard` pressure it raises admission shedding (drain in-flight) and invokes the configured `recycle`
      callback — in production that gracefully restarts the node/pod (e.g. `System.stop/0`); the default just
      logs, so a deployment wires its own.

  Pressure is `atom_count / atom_limit` by default; a `pressure_fun` can be injected for testing the state
  machine without exhausting the real atom table.
  """
  use GenServer
  require Logger

  @defaults %{soft: 0.70, hard: 0.90, interval_ms: 1_000}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Current atom-table pressure in [0.0, ~1.0]."
  def pressure(server \\ __MODULE__), do: GenServer.call(server, :pressure)

  @doc "Health: :ok | :shedding (soft — new compiles refused) | :critical (hard — recycle signalled)."
  def health(server \\ __MODULE__), do: GenServer.call(server, :health)

  @doc "Force an immediate check (mainly for tests)."
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check)

  @impl true
  def init(opts) do
    cfg = Map.merge(@defaults, Map.new(Keyword.take(opts, [:soft, :hard, :interval_ms])))

    state = %{
      cfg: cfg,
      cache: Keyword.get(opts, :cache, TinyLasers.Gate.ModuleCache),
      pressure_fun: Keyword.get(opts, :pressure_fun, &default_pressure/0),
      recycle: Keyword.get(opts, :recycle, &default_recycle/0),
      health: :ok
    }

    schedule(cfg.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:pressure, _from, state), do: {:reply, state.pressure_fun.(), state}
  def handle_call(:health, _from, state), do: {:reply, state.health, state}
  def handle_call(:check, _from, state), do: {:reply, :ok, evaluate(state)}

  @impl true
  def handle_info(:tick, state) do
    schedule(state.cfg.interval_ms)
    {:noreply, evaluate(state)}
  end

  defp evaluate(state) do
    p = state.pressure_fun.()
    cfg = state.cfg

    health =
      cond do
        p >= cfg.hard -> :critical
        p >= cfg.soft -> :shedding
        true -> :ok
      end

    apply_health(health, state)

    if health != state.health do
      Logger.info("[AtomWatchdog] pressure=#{Float.round(p, 3)} health #{state.health} -> #{health}")
      if health == :critical, do: state.recycle.()
    end

    %{state | health: health}
  end

  defp apply_health(:critical, state) do
    safe(fn -> TinyLasers.Gate.ModuleCache.set_compile_shedding(state.cache, true) end)
    safe(fn -> TinyLasers.Gate.Admission.set_shedding(true) end)
  end

  defp apply_health(:shedding, state) do
    safe(fn -> TinyLasers.Gate.ModuleCache.set_compile_shedding(state.cache, true) end)
    safe(fn -> TinyLasers.Gate.Admission.set_shedding(false) end)
  end

  defp apply_health(:ok, state) do
    safe(fn -> TinyLasers.Gate.ModuleCache.set_compile_shedding(state.cache, false) end)
    safe(fn -> TinyLasers.Gate.Admission.set_shedding(false) end)
  end

  defp default_pressure do
    :erlang.system_info(:atom_count) / :erlang.system_info(:atom_limit)
  end

  defp default_recycle do
    Logger.warning("[AtomWatchdog] atom pressure CRITICAL — node recycle required (wire System.stop/0 in prod)")
  end

  defp safe(fun), do: (try do fun.() catch _, _ -> :ok end)
  defp schedule(ms), do: Process.send_after(self(), :tick, ms)
end
