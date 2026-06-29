defmodule Rondo.SideEffectPolicy do
  @moduledoc """
  Shared action-policy boundary for Rondo-owned side effects.

  This module keeps Beislið as the policy decision source while translating
  `ask`/`deny` outcomes into Rondo guidance metadata that can be persisted and
  surfaced in the dashboard before any side effect runs.
  """

  alias Rondo.{ActionPolicy, Interrupt, RunLedger}

  @skip_behaviors ["continue", "block", "abort"]

  @type side_effect :: %{
          required(:action) => String.t(),
          required(:classes) => [String.t()],
          optional(:label) => String.t(),
          optional(:operation) => term(),
          optional(:command) => String.t(),
          optional(:required) => boolean(),
          optional(:resume_safe) => boolean(),
          optional(:skip_behavior) => String.t(),
          optional(:side_effect_id) => String.t()
        }

  @type decision :: %{
          required(:side_effect_status) => :allowed | :blocked,
          required(:envelope) => map() | nil,
          required(:interrupt) => map() | nil,
          optional(:block_reason) => term()
        }

  @spec evaluate(side_effect(), keyword()) :: {:ok, decision()} | {:blocked, decision()}
  def evaluate(side_effect, opts \\ []) when is_map(side_effect) do
    action = Map.fetch!(side_effect, :action)
    classes = Map.get(side_effect, :classes, [])
    evaluator = Keyword.get(opts, :evaluator, &ActionPolicy.evaluate/3)

    case evaluator.(action, classes, opts) do
      {:ok, %{"decision" => "allow"} = envelope} ->
        {:ok, record_policy_decision(%{side_effect_status: :allowed, envelope: envelope, interrupt: nil}, opts)}

      {:ok, %{"decision" => "ask"} = envelope} ->
        {:blocked,
         record_policy_decision(
           %{
             side_effect_status: :blocked,
             block_reason: :action_policy_requires_guidance,
             envelope: envelope,
             interrupt: guidance_interrupt(side_effect, envelope, opts)
           },
           opts
         )}

      {:ok, %{"decision" => "deny"} = envelope} ->
        {:blocked,
         record_policy_decision(
           %{
             side_effect_status: :blocked,
             block_reason: :action_policy_denied,
             envelope: envelope,
             interrupt: guidance_interrupt(side_effect, envelope, opts)
           },
           opts
         )}

      {:ok, envelope} ->
        {:blocked,
         %{
           side_effect_status: :blocked,
           block_reason: {:action_policy_failed, :invalid_evaluator_envelope},
           envelope: envelope,
           interrupt: nil
         }}

      {:error, reason} ->
        {:blocked,
         %{
           side_effect_status: :blocked,
           block_reason: {:action_policy_failed, reason},
           envelope: nil,
           interrupt: nil
         }}
    end
  end

  defp record_policy_decision(%{envelope: envelope, side_effect_status: status} = decision, opts) when is_map(envelope) do
    case Keyword.get(opts, :ledger) do
      %RunLedger{} = ledger ->
        case RunLedger.record_action_policy_decision(ledger, envelope, side_effect_status: status) do
          {:ok, ledger} -> Map.put(decision, :ledger, ledger)
          {:error, _reason} -> Map.put(decision, :ledger, ledger)
        end

      _other ->
        decision
    end
  end

  @spec guidance_interrupt(side_effect(), map(), keyword()) :: map()
  def guidance_interrupt(side_effect, envelope, opts \\ []) when is_map(side_effect) and is_map(envelope) do
    Interrupt.action_policy_guidance_required(%{
      timestamp: Keyword.get(opts, :now, DateTime.utc_now()),
      guidance_severity: guidance_severity(side_effect, envelope),
      blocked_side_effect: blocked_side_effect_payload(side_effect),
      policy: envelope,
      suggested_responses: suggested_responses(side_effect),
      upcoming_transitions: upcoming_transitions(side_effect),
      resume: resume_payload(side_effect, opts)
    })
  end

  @spec guidance_severity(side_effect(), map()) :: String.t()
  def guidance_severity(side_effect, envelope) when is_map(side_effect) and is_map(envelope) do
    cond do
      Map.get(envelope, "log_level") == "error" -> "critical"
      destructive?(side_effect) -> "critical"
      remote_write?(side_effect) -> "warning"
      Map.get(side_effect, :required, true) -> "warning"
      true -> "info"
    end
  end

  defp blocked_side_effect_payload(side_effect) do
    %{
      action: Map.fetch!(side_effect, :action),
      label: Map.get(side_effect, :label, Map.fetch!(side_effect, :action)),
      operation: Map.get(side_effect, :operation),
      command: Map.get(side_effect, :command),
      classes: Map.get(side_effect, :classes, []),
      required: Map.get(side_effect, :required, true),
      resume_safe: Map.get(side_effect, :resume_safe, false),
      skip_behavior: skip_behavior(side_effect)
    }
    |> drop_nil_values()
  end

  defp suggested_responses(side_effect) do
    side_effect
    |> approve_once_response()
    |> Kernel.++([abort_run_response()])
  end

  defp approve_once_response(%{resume_safe: true}) do
    [
      %{
        id: "approve_once",
        label: "Approve once",
        guidance: "approve_once",
        deterministic: true,
        quick: true
      }
    ]
  end

  defp approve_once_response(_side_effect), do: []

  defp abort_run_response do
    %{
      id: "abort_run",
      label: "Abort run",
      guidance: "abort_run",
      deterministic: true,
      quick: false
    }
  end

  defp upcoming_transitions(side_effect) do
    %{
      approve_once: approve_once_transition(side_effect),
      abort_run: "Rondo will mark the run aborted and keep the workspace and run ledger."
    }
    |> drop_nil_values()
  end

  defp approve_once_transition(%{resume_safe: true}) do
    "Rondo will execute this side effect once, record the approval, and continue when the continuation is still available."
  end

  defp approve_once_transition(_side_effect), do: nil

  defp resume_payload(side_effect, opts) do
    opts
    |> Keyword.get(:resume, %{})
    |> Map.put_new(:side_effect_id, Map.get(side_effect, :side_effect_id, Map.fetch!(side_effect, :action)))
  end

  defp skip_behavior(side_effect) do
    case Map.get(side_effect, :skip_behavior, "block") do
      behavior when behavior in @skip_behaviors -> behavior
      _other -> "block"
    end
  end

  defp destructive?(side_effect) do
    classes = Map.get(side_effect, :classes, [])
    action = Map.get(side_effect, :action, "")

    Enum.any?(classes, &(&1 in ["destructive", "workspace-destructive"])) or
      String.contains?(action, "remove") or String.contains?(action, "cleanup")
  end

  defp remote_write?(side_effect) do
    classes = Map.get(side_effect, :classes, [])
    action = Map.get(side_effect, :action, "")

    Enum.any?(classes, &(&1 in ["git-remote", "tracker-write", "pr-write"])) or
      String.starts_with?(action, "tracker.") or String.starts_with?(action, "git.") or String.starts_with?(action, "pr.")
  end

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
