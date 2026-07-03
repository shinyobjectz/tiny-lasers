defmodule TinyLasers.Gate.Exec do
  @moduledoc """
  **The production execution model — one call, all the gates.**

  `invoke/3` is the request entrypoint a multi-tenant service uses. It composes the pieces that were previously
  loose:

      Admission.admit  →  Js.invoke (ModuleCache resolve = compile-once + fresh bounded process)  →  Meter.record
                       ↘ reject (rate / concurrency / atom-pressure) ─ Meter.record_rejection

  All the long-lived state (cache, meter, admission, atom watchdog) runs under `TinyLasers.Application`'s
  supervisor, so this is safe to call from any request process. `prewarm/3` compiles a tenant's programs ahead
  of first request (DeployKit calls this at deploy so the hot path is always a warm-module cache hit).

  Returns `%{result, output, mod, admitted, duration_us}` — `result` is `{:ok, v}` on success,
  `{:rejected, reason}` for an admission/compile refusal, or the bounded-run outcome
  (`{:resource_killed, _}` / `{:timeout, _}` / `{:guest_error, _}`).
  """

  alias TinyLasers.Gate.{Js, ModuleCache, Admission, Meter}

  @doc "Admit, run (compile-once + fresh bounded process), meter. See the module doc."
  def invoke(tenant, source, opts \\ []) when is_binary(tenant) and is_binary(source) do
    case Admission.admit(tenant, opts) do
      {:error, reason} ->
        Meter.record_rejection(tenant, reason)
        %{result: {:rejected, reason}, output: [], mod: nil, admitted: false, duration_us: 0}

      :ok ->
        t0 = System.monotonic_time(:microsecond)

        out =
          try do
            Js.invoke(tenant, source, opts)
          after
            Admission.release(tenant)
          end

        dur = System.monotonic_time(:microsecond) - t0

        case out.result do
          {:rejected, reason} -> Meter.record_rejection(tenant, reason)
          real -> Meter.record(tenant, dur, real)
        end

        Map.merge(out, %{admitted: true, duration_us: dur})
    end
  end

  @doc """
  Pre-compile `sources` for `tenant` into the cache (deploy-time warm-up). Bypasses admission/bounding — this is
  a trusted, host-initiated step, not a guest request. Returns a map `%{compiled, cap_hit}` counting outcomes.
  """
  def prewarm(tenant, sources, opts \\ []) when is_binary(tenant) and is_list(sources) do
    cache = Keyword.get(opts, :cache, ModuleCache)
    granted = Keyword.get(opts, :granted, %{"print" => 0})

    Enum.reduce(sources, %{compiled: 0, cap_hit: 0}, fn src, acc ->
      key_source = src <> <<0>> <> :erlang.term_to_binary(granted)

      compile_fun = fn modname ->
        body = TinyLasers.Gate.Lower.program(Js.parse(src), granted)
        quoted = quote do (defmodule unquote(modname) do def run, do: unquote(body) end) end
        TinyLasers.Gate.assert_safe_to_compile!(quoted)
        [{mod, bin}] = Code.compile_quoted(quoted)
        {mod, bin}
      end

      case ModuleCache.resolve(tenant, key_source, compile_fun, cache) do
        {:ok, _} -> %{acc | compiled: acc.compiled + 1}
        {:error, _} -> %{acc | cap_hit: acc.cap_hit + 1}
      end
    end)
  end

  @doc "Snapshot of node health for observability / readiness probes."
  def health do
    %{
      atom_pressure: safe(fn -> TinyLasers.Gate.AtomWatchdog.pressure() end, 0.0),
      atom_health: safe(fn -> TinyLasers.Gate.AtomWatchdog.health() end, :ok),
      global_inflight: safe(fn -> Admission.global_inflight() end, 0),
      shedding: safe(fn -> Admission.shedding?() end, false),
      cache: safe(fn -> ModuleCache.stats() end, %{}),
      meter: safe(fn -> Meter.totals() end, %{})
    }
  end

  defp safe(fun, default), do: (try do fun.() catch _, _ -> default end)
end
