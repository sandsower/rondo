defmodule Rondo.RunDecision do
  @moduledoc """
  Helpers for explicit run control-flow decision records and synthetic updates.
  """

  alias Rondo.Linear.Issue

  @type kind :: :continue | :stop | :retry | :pause | :fail | :terminate

  @spec checkpoint_payload(kind(), String.t(), String.t(), keyword()) :: map()
  def checkpoint_payload(kind, reason_code, summary, opts \\ [])
      when kind in [:continue, :stop, :retry, :pause, :fail, :terminate] and
             is_binary(reason_code) and is_binary(summary) do
    %{
      "decision_kind" => Atom.to_string(kind),
      "reason_code" => reason_code,
      "summary" => summary,
      "input_signals" => Keyword.get(opts, :input_signals, %{}),
      "evidence" => Keyword.get(opts, :evidence, %{}),
      "turn_number" => Keyword.get(opts, :turn_number),
      "retry_attempt" => Keyword.get(opts, :retry_attempt),
      "run_id" => Keyword.get(opts, :run_id),
      "run_dir" => Keyword.get(opts, :run_dir),
      "session_id" => Keyword.get(opts, :session_id),
      "run_ref" => Keyword.get(opts, :run_ref),
      "issue" => issue_snapshot(Keyword.get(opts, :issue)),
      "timestamp" => timestamp(Keyword.get(opts, :timestamp))
    }
    |> drop_nil_values()
  end

  @spec synthetic_update(kind(), String.t(), String.t(), keyword()) :: map()
  def synthetic_update(kind, reason_code, summary, opts \\ []) do
    checkpoint = checkpoint_payload(kind, reason_code, summary, opts)

    %{
      event: :run_decision,
      method: "run_decision",
      payload: summary,
      message: summary,
      decision_kind: Atom.to_string(kind),
      reason_code: reason_code,
      input_signals: Keyword.get(opts, :input_signals, %{}),
      evidence: Keyword.get(opts, :evidence, %{}),
      turn_number: Keyword.get(opts, :turn_number),
      retry_attempt: Keyword.get(opts, :retry_attempt),
      run_id: Keyword.get(opts, :run_id),
      run_dir: Keyword.get(opts, :run_dir),
      session_id: Keyword.get(opts, :session_id),
      run_ref: Keyword.get(opts, :run_ref),
      timestamp: checkpoint["timestamp"],
      raw: checkpoint
    }
    |> drop_nil_values()
  end

  defp issue_snapshot(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "state" => issue.state,
      "url" => issue.url
    }
    |> drop_nil_values()
  end

  defp issue_snapshot(issue) when is_map(issue) do
    %{
      "id" => Map.get(issue, :id) || Map.get(issue, "id"),
      "identifier" => Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      "title" => Map.get(issue, :title) || Map.get(issue, "title"),
      "state" => Map.get(issue, :state) || Map.get(issue, "state"),
      "url" => Map.get(issue, :url) || Map.get(issue, "url")
    }
    |> drop_nil_values()
  end

  defp issue_snapshot(_issue), do: %{}

  defp timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp timestamp(value) when is_binary(value), do: value
  defp timestamp(_value), do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
