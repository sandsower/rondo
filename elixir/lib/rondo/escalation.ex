defmodule Rondo.Escalation do
  @moduledoc """
  Model-tier escalation and final-report repair policy for failed runs.

  Decides, after a run attempt finishes, whether to mark the run done, escalate
  to a stronger model tier in a fresh workspace, repair the same-tier final
  report, or pause because a ceiling is hit or the ladder is exhausted.

  The policy is configured in `workflow.md` under `escalation:` and can be
  overridden per execution in the source contract's `escalation` block.

  Decisions from this module are consumed by `Rondo.Orchestrator`; pure logic
  lives here so it can be tested in isolation.
  """

  alias Rondo.Config

  @default_tiers ["light", "standard", "heavy", "frontier"]
  @default_max_total_attempts 3
  @default_report_repair_attempts 2

  @typedoc """
  One entry in the attempt chain.
  """
  @type attempt_entry :: %{
          run_id: String.t(),
          tier: tier() | nil,
          reason: reason(),
          status: status(),
          failure_classification: String.t() | nil,
          gate_summary: map() | nil,
          final_report_status: String.t() | nil,
          token_spend: token_spend(),
          started_at: String.t() | nil,
          finished_at: String.t() | nil,
          run_dir: String.t() | nil
        }

  @type tier :: String.t()
  @type reason :: :initial | :escalation | :report_repair
  @type status :: :completed | :failed | :paused | :terminated
  @type token_spend :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @typedoc """
  Resolved escalation configuration for one chain of attempts.
  """
  @type config :: %{
          enabled: boolean(),
          tiers: [tier()],
          max_total_attempts: pos_integer(),
          token_budget: pos_integer() | nil,
          report_repair_attempts: pos_integer()
        }

  @typedoc """
  A decision returned after evaluating a finished attempt.
  """
  @type decision ::
          {:done, [attempt_entry()]}
          | {:escalate, tier(), [attempt_entry()], String.t()}
          | {:repair, [attempt_entry()], String.t()}
          | {:pause, String.t(), [attempt_entry()]}

  @doc """
  Merge the repo escalation config with an optional source-contract override.
  """
  @spec resolve_config(map() | nil) :: config()
  def resolve_config(source_contract_override \\ nil) do
    repo = repo_config()

    override =
      case source_contract_override do
        %{escalation: escalation} when is_map(escalation) -> escalation
        %{"escalation" => escalation} when is_map(escalation) -> escalation
        _ -> %{}
      end

    %{
      enabled: boolean_value(Map.get(override, :enabled, Map.get(override, "enabled", repo.enabled))),
      tiers: tier_list(Map.get(override, :tiers, Map.get(override, "tiers", repo.tiers))),
      max_total_attempts:
        positive_integer(
          Map.get(
            override,
            :max_total_attempts,
            Map.get(override, "max_total_attempts", repo.max_total_attempts)
          )
        ),
      token_budget: optional_positive_integer(Map.get(override, :token_budget, Map.get(override, "token_budget", repo.token_budget))),
      report_repair_attempts:
        report_repair_attempts_value(
          Map.get(
            override,
            :report_repair_attempts,
            Map.get(override, "report_repair_attempts", repo.report_repair_attempts)
          )
        )
    }
  end

  @doc """
  Evaluate a finished attempt and decide what to do next.

  The manifest is the ledger manifest for the attempt that just finished.
  `chain` is the list of previous attempts (not including the current one).
  """
  @spec after_attempt(map(), [attempt_entry()], map() | nil) :: decision()
  def after_attempt(manifest, chain, source_contract_override \\ nil) do
    config = resolve_config(source_contract_override)

    if config.enabled do
      decide_next_attempt(manifest, chain, config)
    else
      return_done_or_pause(manifest, chain, "escalation_disabled")
    end
  end

  @doc """
  Build a short evidence prompt to seed an escalated or repair attempt.
  """
  @spec evidence_prompt([attempt_entry()], :escalate | :repair) :: String.t()
  def evidence_prompt(chain, mode), do: evidence_prompt(chain, mode, nil)

  @spec evidence_prompt([attempt_entry()], :escalate, tier() | nil) :: String.t()
  @spec evidence_prompt([attempt_entry()], :repair, tier() | nil) :: String.t()
  def evidence_prompt(chain, :escalate, target_tier) when is_binary(target_tier) do
    latest = List.last(chain) || %{}

    """
    This is an escalated attempt at tier `#{target_tier}`. You are starting in a fresh, clean worktree seeded only with the diagnosis from the previous attempt.

    Previous attempt summary:
    - run_id: #{Map.get(latest, :run_id) || "unknown"}
    - tier: #{Map.get(latest, :tier) || "unknown"}
    - reason: #{Map.get(latest, :reason) || "initial"}
    - status: #{Map.get(latest, :status) || "unknown"}
    - failure_classification: #{Map.get(latest, :failure_classification) || "none"}
    - final_report_status: #{Map.get(latest, :final_report_status) || "none"}
    - gate summary: #{summarize_gate(Map.get(latest, :gate_summary))}

    Do not resume or copy the previous workspace state. Use the evidence above, then implement the ticket from the base ref. Preserve the action policy: do not widen allowed/ask/deny boundaries.
    """
    |> String.trim()
  end

  def evidence_prompt(chain, :repair, _target_tier) do
    latest = List.last(chain) || %{}

    """
    This is a same-tier repair attempt for the final report only. Do not edit code, do not run commands, and do not start a new implementation. Re-read the report schema `rondo.final_report/v0` and emit a valid final report from your own run evidence.

    Previous attempt summary:
    - run_id: #{Map.get(latest, :run_id) || "unknown"}
    - tier: #{Map.get(latest, :tier) || "unknown"}
    - final_report_status: #{Map.get(latest, :final_report_status) || "missing"}
    - final_report_errors: #{format_final_report_errors(Map.get(latest, :failure_classification), Map.get(latest, :final_report_status))}
    - failure_classification: #{Map.get(latest, :failure_classification) || "none"}

    Produce only the final report. The delivery bundle cannot be assembled without it.
    """
    |> String.trim()
  end

  # --- Pure decision helpers ---

  defp decide_next_attempt(manifest, chain, config) do
    entry = attempt_entry_from_manifest(manifest)
    chain = Enum.reject(chain, &(&1.run_id == entry.run_id)) ++ [entry]

    check_success(entry, chain) ||
      check_ceiling(chain, config) ||
      recover_from_failure(entry, chain, config)
  end

  defp recover_from_failure(entry, chain, config) do
    if final_report_failure?(entry) do
      handle_final_report(chain, config)
    else
      check_escalate(entry, chain, config) || {:pause, "no_recovery_path", chain}
    end
  end

  defp return_done_or_pause(manifest, chain, pause_reason) do
    entry = attempt_entry_from_manifest(manifest)
    chain = chain ++ [entry]

    if successful?(entry) do
      {:done, chain}
    else
      {:pause, pause_reason, chain}
    end
  end

  defp check_success(entry, chain) do
    if successful?(entry) do
      {:done, chain}
    end
  end

  defp check_ceiling(chain, config) do
    cond do
      length(chain) >= config.max_total_attempts ->
        {:pause, "max_total_attempts_exceeded", chain}

      exceeded_token_budget?(chain, config.token_budget) ->
        {:pause, "token_budget_exceeded", chain}

      true ->
        nil
    end
  end

  defp exceeded_token_budget?(_chain, nil), do: false

  defp exceeded_token_budget?(chain, budget) when is_integer(budget) and budget > 0 do
    total =
      chain
      |> Enum.map(&(get_in(&1, [:token_spend, :total_tokens]) || 0))
      |> Enum.sum()

    total >= budget
  end

  defp handle_final_report(chain, config) do
    if repair_attempts_used(chain) < config.report_repair_attempts do
      {:repair, chain, evidence_prompt(chain, :repair, nil)}
    else
      {:pause, "report_repair_exhausted", chain}
    end
  end

  defp check_escalate(entry, chain, config) do
    with {:ok, current_tier} <- effective_tier(entry, config.tiers),
         {:ok, next_tier} <- next_tier(config.tiers, current_tier) do
      {:escalate, next_tier, chain, evidence_prompt(chain, :escalate, next_tier)}
    else
      :top -> {:pause, "ladder_exhausted", chain}
    end
  end

  defp effective_tier(%{tier: tier}, ladder) when is_binary(tier) and tier != "" do
    if tier in ladder, do: {:ok, tier}, else: {:ok, List.first(ladder)}
  end

  defp effective_tier(_entry, ladder), do: {:ok, List.first(ladder)}

  defp next_tier(ladder, current_tier) do
    case Enum.find_index(ladder, &(&1 == current_tier)) do
      index ->
        case Enum.at(ladder, index + 1) do
          nil -> :top
          tier -> {:ok, tier}
        end
    end
  end

  defp successful?(%{status: :completed, final_report_status: "valid"} = entry) do
    is_nil(Map.get(entry, :failure_classification))
  end

  defp successful?(_entry), do: false

  defp final_report_failure?(%{failure_classification: "final_report_missing"}), do: true
  defp final_report_failure?(%{failure_classification: "final_report_invalid"}), do: true
  defp final_report_failure?(_entry), do: false

  defp repair_attempts_used(chain) do
    Enum.count(chain, &(&1.reason == :report_repair))
  end

  # --- Manifest parsing ---

  defp attempt_entry_from_manifest(manifest) when is_map(manifest) do
    agent = Map.get(manifest, "agent") || %{}
    timestamps = Map.get(manifest, "timestamps") || %{}
    routing = agent["model_routing"] || %{}

    %{
      run_id: manifest["run_id"],
      tier: routing["requested_tier"] || tier_from_model(Map.get(routing, "resolved")),
      reason: attempt_reason(manifest),
      status: attempt_status(manifest["status"]),
      failure_classification: manifest["failure_classification"],
      gate_summary: manifest["latest_gate"] || get_in(manifest, ["interrupt", "gate"]),
      final_report_status: get_in(manifest, ["final_report", "status"]),
      token_spend: token_spend(agent["usage"]),
      started_at: timestamps["started_at"],
      finished_at: timestamps["finished_at"],
      run_dir: manifest["run_dir"]
    }
    |> drop_nil_values()
  end

  defp tier_from_model(%{"model" => _model}), do: nil
  defp tier_from_model(_resolved), do: nil

  defp attempt_reason(manifest) do
    case get_in(manifest, ["escalation", "current_attempt", "reason"]) do
      "escalation" -> :escalation
      "report_repair" -> :report_repair
      "initial" -> :initial
      nil -> :initial
      other -> String.to_atom(other)
    end
  end

  defp attempt_status("completed"), do: :completed
  defp attempt_status("failed"), do: :failed
  defp attempt_status("paused"), do: :paused
  defp attempt_status("terminated"), do: :terminated
  defp attempt_status(_other), do: :failed

  defp token_spend(%{"input_tokens" => i, "output_tokens" => o, "total_tokens" => t}) do
    %{input_tokens: to_int(i), output_tokens: to_int(o), total_tokens: to_int(t)}
  end

  defp token_spend(%{input_tokens: i, output_tokens: o, total_tokens: t}) do
    %{input_tokens: to_int(i), output_tokens: to_int(o), total_tokens: to_int(t)}
  end

  defp token_spend(_other) do
    %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end

  defp to_int(value) when is_integer(value), do: max(value, 0)
  defp to_int(_other), do: 0

  # --- Config parsing ---

  defp repo_config do
    %{
      enabled: Config.escalation_enabled?(),
      tiers: Config.escalation_tiers(),
      max_total_attempts: Config.escalation_max_total_attempts(),
      token_budget: Config.escalation_token_budget(),
      report_repair_attempts: Config.escalation_report_repair_attempts()
    }
  end

  defp boolean_value(true), do: true
  defp boolean_value("true"), do: true
  defp boolean_value(_other), do: false

  defp tier_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_tier/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> @default_tiers
      tiers -> tiers
    end
  end

  defp tier_list(_other), do: @default_tiers

  defp normalize_tier(value) when is_binary(value) do
    trimmed = String.trim(String.downcase(value))
    if trimmed in @default_tiers, do: trimmed, else: nil
  end

  defp normalize_tier(value) when is_atom(value), do: normalize_tier(Atom.to_string(value))
  defp normalize_tier(_other), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value),
    do: parse_pos_integer(value) || @default_max_total_attempts

  defp positive_integer(_other), do: @default_max_total_attempts

  defp report_repair_attempts_value(value) when is_integer(value) and value > 0, do: value

  defp report_repair_attempts_value(value) when is_binary(value),
    do: parse_pos_integer(value) || @default_report_repair_attempts

  defp report_repair_attempts_value(_other), do: @default_report_repair_attempts

  defp optional_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp optional_positive_integer(value) when is_binary(value), do: parse_pos_integer(value)
  defp optional_positive_integer(_other), do: nil

  defp parse_pos_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp format_final_report_errors("final_report_invalid", status) when is_binary(status) do
    status
  end

  defp format_final_report_errors("final_report_invalid", status) when is_atom(status) do
    Atom.to_string(status)
  end

  defp format_final_report_errors(_classification, _status), do: "none"

  defp summarize_gate(nil), do: "none"

  defp summarize_gate(summary) when is_map(summary) do
    status = Map.get(summary, "status") || Map.get(summary, :status)

    failed =
      (Map.get(summary, "failed") || [])
      |> Enum.map_join(", ", & &1["name"])

    case {status, failed} do
      {nil, ""} -> "none"
      {status, ""} -> "status #{status}"
      {status, failed} -> "status #{status}; failed gates: #{failed}"
    end
  end

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
