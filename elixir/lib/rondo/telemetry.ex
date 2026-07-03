defmodule Rondo.Telemetry do
  @moduledoc """
  Event catalog and thin `:telemetry.execute/3` wrappers for run lifecycle events.

  This module owns naming and shape only. It has no state, no handlers, and no
  aggregation logic - it exists so every emit site in the codebase uses the same
  event names and metadata keys instead of inventing their own. The only
  consumer in this codebase is the test suite (via `:telemetry.attach/4`);
  external consumers (dashboards, APM) attach their own handlers at runtime.

  `Rondo.RunScorecard` is a separate, unrelated mechanism: it derives outcome
  statistics by reading the run ledger from disk after the fact. It does not
  attach to these events. Telemetry here is for live observability, not for
  historical reporting.

  ## Event catalog

  | Event                              | Measurements        | Metadata                                   |
  |-------------------------------------|----------------------|---------------------------------------------|
  | `[:rondo, :run, :start]`            | `%{}`                | `run_id`, `adapter`                          |
  | `[:rondo, :run, :stop]`             | `%{duration}` (ms, may be `nil`) | `run_id`, `status`, `adapter`  |
  | `[:rondo, :gate, :stop]`            | `%{duration}` (ms)   | `run_id`, `gate`, `status`                   |
  | `[:rondo, :clean_eval, :stop]`      | `%{}`                | `run_id`, `status`                           |
  | `[:rondo, :final_report, :recorded]`| `%{}`                | `run_id`, `status`                           |
  | `[:rondo, :escalation, :decision]`  | `%{}`                | `run_id`, `decision`, plus decision-specific keys (`reason` for `:pause`, `next_tier` for `:escalate`) |

  All `status` values are strings (e.g. `"completed"`, `"failed"`, `"pass"`,
  `"fail"`, `"error"`, `"timeout"`, `"valid"`, `"invalid"`, `"missing"`) so
  handlers do not need to pattern-match on both atoms and strings. `duration`
  measurements are milliseconds.
  """

  @type run_id :: String.t()
  @type status :: String.t() | atom()

  @doc "Emits `[:rondo, :run, :start]` for a newly created run ledger."
  @spec run_start(run_id(), map()) :: :ok
  def run_start(run_id, metadata \\ %{}) when is_binary(run_id) and is_map(metadata) do
    :telemetry.execute([:rondo, :run, :start], %{}, Map.put(metadata, :run_id, run_id))
  end

  @doc "Emits `[:rondo, :run, :stop]` when a run reaches a terminal ledger status."
  @spec run_stop(run_id(), non_neg_integer() | nil, status(), map()) :: :ok
  def run_stop(run_id, duration_ms, status, metadata \\ %{}) when is_binary(run_id) and is_map(metadata) do
    measurements = %{duration: duration_ms}

    metadata =
      metadata
      |> Map.put(:run_id, run_id)
      |> Map.put(:status, to_status_string(status))

    :telemetry.execute([:rondo, :run, :stop], measurements, metadata)
  end

  @doc "Emits `[:rondo, :gate, :stop]` for one gate result."
  @spec gate_stop(run_id(), String.t(), status(), non_neg_integer()) :: :ok
  def gate_stop(run_id, gate_name, status, duration_ms) when is_binary(run_id) and is_binary(gate_name) and is_integer(duration_ms) do
    :telemetry.execute(
      [:rondo, :gate, :stop],
      %{duration: duration_ms},
      %{run_id: run_id, gate: gate_name, status: to_status_string(status)}
    )
  end

  @doc "Emits `[:rondo, :clean_eval, :stop]` for a clean-eval outcome."
  @spec clean_eval_stop(run_id(), status()) :: :ok
  def clean_eval_stop(run_id, status) when is_binary(run_id) do
    :telemetry.execute([:rondo, :clean_eval, :stop], %{}, %{run_id: run_id, status: to_status_string(status)})
  end

  @doc "Emits `[:rondo, :final_report, :recorded]` when a final report validation is persisted."
  @spec final_report_recorded(run_id(), status()) :: :ok
  def final_report_recorded(run_id, status) when is_binary(run_id) do
    :telemetry.execute([:rondo, :final_report, :recorded], %{}, %{run_id: run_id, status: to_status_string(status)})
  end

  @doc """
  Emits `[:rondo, :escalation, :decision]` for a resolved `Rondo.Escalation` decision.

  Accepts the decision tuple returned by `Rondo.Escalation.after_attempt/3`
  directly so call sites do not need to destructure it themselves.
  """
  @spec escalation_decision(run_id(), Rondo.Escalation.decision()) :: :ok
  def escalation_decision(run_id, decision) when is_binary(run_id) do
    {kind, extra} = escalation_decision_metadata(decision)
    :telemetry.execute([:rondo, :escalation, :decision], %{}, Map.merge(%{run_id: run_id, decision: kind}, extra))
  end

  defp escalation_decision_metadata({:done, _chain}), do: {:done, %{}}
  defp escalation_decision_metadata({:pause, reason, _chain}), do: {:pause, %{reason: reason}}
  defp escalation_decision_metadata({:escalate, next_tier, _chain, _prompt}), do: {:escalate, %{next_tier: next_tier}}
  defp escalation_decision_metadata({:repair, _chain, _prompt}), do: {:repair, %{}}

  defp to_status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp to_status_string(status) when is_binary(status), do: status
end
