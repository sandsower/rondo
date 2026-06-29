defmodule Rondo.Interrupt do
  @moduledoc """
  Builders for durable human interrupt payloads.

  Interrupt payloads are plain string-keyed maps so they can be written into the
  run ledger and later resumed without depending on process-local state.
  """

  alias Rondo.Linear.Issue

  @type payload :: map()

  @spec repeated_gate_failure(map()) :: payload()
  def repeated_gate_failure(context) when is_map(context) do
    %{
      "reason" => "repeated_gate_failure",
      "state" => "paused",
      "created_at" => timestamp(context),
      "question" => "Configured gates failed repeatedly. How should Rondo proceed?",
      "options" => [
        %{"id" => "resume", "label" => "Resume with operator guidance"},
        %{"id" => "abort", "label" => "Abort this run"},
        %{"id" => "defer", "label" => "Keep paused and decide later"}
      ],
      "recommendation" => "Review the gate artifacts, then resume with operator guidance.",
      "issue" => issue_payload(Map.get(context, :issue) || Map.get(context, "issue")),
      "gate" => normalize_value(Map.get(context, :gate) || Map.get(context, "gate") || %{}),
      "resume" => resume_payload(context)
    }
    |> drop_nil_values()
  end

  @spec action_policy_guidance_required(map()) :: payload()
  def action_policy_guidance_required(context) when is_map(context) do
    %{
      "reason" => "action_policy_guidance_required",
      "state" => "paused",
      "guidance_severity" => value(context, :guidance_severity) || "warning",
      "created_at" => timestamp(context),
      "question" =>
        value(context, :question) ||
          "Rondo needs operator guidance before continuing. The side effect below has not been executed.",
      "blocked_side_effect" => normalize_value(value(context, :blocked_side_effect) || %{}),
      "policy" => policy_summary(value(context, :policy) || %{}),
      "suggested_responses" => normalize_value(value(context, :suggested_responses) || []),
      "upcoming_transitions" => normalize_value(value(context, :upcoming_transitions) || %{}),
      "resume" => normalize_value(value(context, :resume) || %{})
    }
    |> drop_nil_values()
  end

  @spec final_report_invalid(map()) :: payload()
  def final_report_invalid(context) when is_map(context) do
    classification = value(context, :classification) || "final_report_unparsed"

    %{
      "reason" => "final_report_invalid",
      "state" => "paused",
      "classification" => classification,
      "created_at" => timestamp(context),
      "question" => final_report_question(classification),
      "final_report" => final_report_summary(context),
      "suggested_responses" => normalize_value(value(context, :suggested_responses) || []),
      "resume" => normalize_value(value(context, :resume) || %{})
    }
    |> drop_nil_values()
  end

  defp final_report_question("blocked_state_unparsed") do
    "The last assistant message reported a blocked state, but it was not valid rondo.final_report/v0 JSON."
  end

  defp final_report_question("terminal_state_unparsed") do
    "The last assistant message reported a terminal state, but it was not valid rondo.final_report/v0 JSON."
  end

  defp final_report_question("repeated_final_report") do
    "The assistant repeated the same final report across continuations. Rondo paused to avoid a loop."
  end

  defp final_report_question(_classification) do
    "The last assistant message was not valid rondo.final_report/v0 JSON."
  end

  defp final_report_summary(context) do
    %{
      "status" => value(context, :final_report_status) || "invalid",
      "errors" => normalize_value(value(context, :errors) || []),
      "reported_next_state" => value(context, :reported_next_state),
      "continuation_count" => value(context, :continuation_count),
      "fingerprint" => value(context, :fingerprint),
      "excerpt" => value(context, :excerpt)
    }
    |> drop_nil_values()
  end

  defp timestamp(context) do
    context
    |> value(:timestamp)
    |> case do
      %DateTime{} = datetime -> DateTime.to_iso8601(DateTime.truncate(datetime, :second))
      timestamp when is_binary(timestamp) -> timestamp
      _other -> DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  end

  defp issue_payload(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "state" => issue.state,
      "url" => issue.url
    }
    |> drop_nil_values()
  end

  defp issue_payload(issue) when is_map(issue) do
    %{
      "id" => value(issue, :id),
      "identifier" => value(issue, :identifier),
      "title" => value(issue, :title),
      "state" => value(issue, :state),
      "url" => value(issue, :url)
    }
    |> drop_nil_values()
  end

  defp issue_payload(_issue), do: %{}

  defp policy_summary(policy) when is_map(policy) do
    %{
      "decision" => value(policy, :decision),
      "reason" => value(policy, :reason),
      "log_level" => value(policy, :log_level),
      "requires_human" => value(policy, :requires_human),
      "matched_rules" => normalize_value(value(policy, :matched_rules) || [])
    }
    |> drop_nil_values()
  end

  defp policy_summary(_policy), do: %{}

  defp resume_payload(context) do
    %{
      "run_id" => value(context, :run_id),
      "run_dir" => value(context, :run_dir),
      "workspace" => value(context, :workspace),
      "session_id" => value(context, :session_id),
      "run_ref" => normalize_value(value(context, :run_ref)),
      "retry_attempt" => value(context, :retry_attempt),
      "model_routing_context" => normalize_value(value(context, :model_routing_context))
    }
    |> drop_nil_values()
  end

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_value(%DateTime{} = datetime), do: DateTime.to_iso8601(DateTime.truncate(datetime, :second))
  defp normalize_value(value) when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)

  defp normalize_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {normalize_key(key), normalize_value(nested_value)} end)
  end

  defp normalize_value(value), do: inspect(value)

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
