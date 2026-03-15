defmodule RondoWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias Rondo.{Config, Orchestrator}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Map.get(snapshot, :running, [])
        retrying = Map.get(snapshot, :retrying, [])
        archived = Map.get(snapshot, :archived, [])

        %{
          generated_at: generated_at,
          counts: %{
            running: length(running),
            retrying: length(retrying)
          },
          running: Enum.map(running, &running_entry_payload/1),
          retrying: Enum.map(retrying, &retry_entry_payload/1),
          archived: group_archived_by_ticket(archived),
          claude_totals: Map.get(snapshot, :claude_totals, %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}),
          rate_limits: Map.get(snapshot, :rate_limits)
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload when is_map(payload) ->
        case Map.get(payload, :requested_at) do
          %DateTime{} = dt -> {:ok, Map.put(payload, :requested_at, DateTime.to_iso8601(dt))}
          _ -> {:ok, payload}
        end
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: Path.join(Config.workspace_root(), issue_identifier)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        claude_session_logs: (running && format_event_log(Map.get(running, :event_log, []))) || []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_claude_event,
      last_message: summarize_message(entry.last_claude_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_claude_timestamp),
      tokens: %{
        input_tokens: entry.claude_input_tokens,
        output_tokens: entry.claude_output_tokens,
        total_tokens: entry.claude_total_tokens
      },
      event_log: format_event_log(Map.get(entry, :event_log, []))
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error
    }
  end

  defp running_issue_payload(running) do
    %{
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_claude_event,
      last_message: summarize_message(running.last_claude_message),
      last_event_at: iso8601(running.last_claude_timestamp),
      tokens: %{
        input_tokens: running.claude_input_tokens,
        output_tokens: running.claude_output_tokens,
        total_tokens: running.claude_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error
    }
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_claude_timestamp),
        event: running.last_claude_event,
        message: summarize_message(running.last_claude_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp group_archived_by_ticket(archived) do
    archived
    |> Enum.map(&archived_entry_payload/1)
    |> Enum.group_by(& &1.issue_identifier)
    |> Enum.map(fn {identifier, runs} ->
      sorted_runs = Enum.sort_by(runs, & &1.started_at, :asc)
      latest = List.last(sorted_runs)

      %{
        issue_identifier: identifier,
        latest_result: latest.exit_reason,
        latest_finished_at: latest.finished_at,
        total_tokens: Enum.reduce(runs, 0, fn r, acc -> acc + r.tokens.total_tokens end),
        run_count: length(runs),
        runs: sorted_runs
      }
    end)
    |> Enum.sort_by(& &1.latest_finished_at, :desc)
  end

  defp archived_entry_payload(entry) do
    started_at = iso8601(entry.started_at) || to_string(entry.started_at)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      session_id: entry.session_id,
      state: entry.state,
      started_at: started_at,
      finished_at: iso8601(entry.finished_at) || to_string(entry.finished_at),
      exit_reason: entry.exit_reason,
      turn_count: entry.turn_count,
      tokens: entry.tokens,
      filename: run_filename(entry.started_at)
    }
  end

  defp run_filename(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[:\.]/, "-")
    |> Kernel.<>(".json")
  end

  defp run_filename(started_at) when is_binary(started_at) do
    # Parse and truncate to match the file naming (seconds only, no microseconds)
    case DateTime.from_iso8601(started_at) do
      {:ok, dt, _} -> run_filename(dt)
      _ ->
        started_at
        |> String.replace(~r/[:\.]/, "-")
        |> Kernel.<>(".json")
    end
  end

  defp run_filename(_), do: "unknown.json"

  @spec format_event_log_public(list()) :: list()
  def format_event_log_public(log), do: format_event_log(log)

  defp format_event_log(log) when is_list(log) do
    log
    |> Enum.reverse()
    |> Enum.map(fn entry ->
      %{
        at: iso8601(entry[:at]),
        event: entry[:event],
        message: summarize_message(entry[:message])
      }
    end)
  end

  defp format_event_log(_), do: []

  defp summarize_message(%{message: message}) when is_binary(message), do: message
  defp summarize_message(message) when is_binary(message), do: message
  defp summarize_message(_message), do: nil

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
