defmodule TinyLasers.Application do
  @moduledoc """
  Boots the runtime's long-lived processes — the same set nexus's supervisor starts for
  Wasm today: the module pool, the JIT cache, the actor children, plus the lock-free
  metrics tables. Lazy ETS tables (`:tl_futex`, `:tl_threads`, ...) are created
  on-demand inside a run, so they need no supervision here.
  """
  use Application

  @impl true
  def start(_type, _args) do
    TinyLasers.Wasm.Metrics.ensure()

    children =
      [
        TinyLasers.Wasm.ModulePool,
        TinyLasers.Wasm.Transpile.AsyncCompiler,
        TinyLasers.Wasm.JitCache
      ] ++
        TinyLasers.Wasm.Actor.child_specs() ++
        f2_execution_model()

    Supervisor.start_link(children, strategy: :one_for_one, name: TinyLasers.Supervisor)
  end

  # The F2 (JS→BEAM) warm-module/cold-process execution model: the per-tenant module cache, invocation metering,
  # admission control, and the atom-pressure watchdog. Config is read from the `:tiny_lasers` app env under
  # `:execution_model` (all keyword-optional). Started last so the WASM lane boots identically to before.
  defp f2_execution_model do
    cfg = Application.get_env(:tiny_lasers, :execution_model, [])

    [
      {TinyLasers.Gate.ModuleCache, Keyword.get(cfg, :module_cache, [])},
      TinyLasers.Gate.Meter,
      {TinyLasers.Gate.Admission, Keyword.get(cfg, :admission, [])},
      {TinyLasers.Gate.AtomWatchdog, Keyword.get(cfg, :atom_watchdog, [])}
    ]
  end
end
