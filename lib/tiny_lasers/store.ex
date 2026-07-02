defmodule TinyLasers.Store do
  @moduledoc """
  The `{:store, tenant}` VFS backend seam — DELEGATES to a configured backend module.

  Layering stays clean (tiny-lasers never names nexus): the host injects a real,
  durable, tenant-partitioned store via config —

      config :tiny_lasers, store_backend: Nexus.Store

  and nexus's `Nexus.Store` satisfies the exact same 4+1 contract
  (`all/2`, `count/2`, `create/3`, `update/4`, `clear/2`) with identical arities and
  semantics, so no adapter is needed. Absent that config (standalone tests/spikes), it
  falls back to `TinyLasers.Store.InProcess` — a faithful zero-dep in-process implementation.
  `TinyLasers.Wasm.VFS` still defaults to the `:map` backend; this path is only taken when a
  process selects `{:store, tenant}`.
  """

  defp backend, do: Application.get_env(:tiny_lasers, :store_backend, TinyLasers.Store.InProcess)

  def all(mod, tenant), do: backend().all(mod, tenant)
  def count(mod, tenant), do: backend().count(mod, tenant)
  def create(mod, attrs, tenant), do: backend().create(mod, attrs, tenant)
  def update(mod, match, attrs, tenant), do: backend().update(mod, match, attrs, tenant)
  def clear(mod, tenant), do: backend().clear(mod, tenant)
end

defmodule TinyLasers.Store.InProcess do
  @moduledoc """
  The zero-dep default backend — process-dict rows, faithful to the 4+1 Store contract so the
  `{:store, _}` VFS path works in standalone tests/spikes without any host dependency. Ephemeral
  (per-process); the host injects a durable backend (see `TinyLasers.Store`) for real tenancy.
  """

  defp k(mod, tenant), do: {:tl_store, mod, tenant}

  def all(mod, tenant), do: Process.get(k(mod, tenant), [])

  def count(mod, tenant), do: length(all(mod, tenant))

  def create(mod, attrs, tenant) do
    Process.put(k(mod, tenant), all(mod, tenant) ++ [struct(mod, attrs)])
    :ok
  end

  def update(mod, match, attrs, tenant) do
    rows =
      Enum.map(all(mod, tenant), fn r ->
        if Map.take(Map.from_struct(r), Map.keys(match)) == match, do: struct(r, attrs), else: r
      end)

    Process.put(k(mod, tenant), rows)
    :ok
  end

  def clear(mod, tenant) do
    Process.put(k(mod, tenant), [])
    :ok
  end
end
