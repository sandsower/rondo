defmodule RondoWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias Rondo.{Config, ModelUsage, Orchestrator}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Map.get(snapshot, :running, [])
        retrying = Map.get(snapshot, :retrying, [])
        archived = Map.get(snapshot, :archived, [])
        paused = Map.get(snapshot, :paused, [])
        needs_guidance = Enum.filter(paused, &guidance_entry?/1)

        %{
          generated_at: generated_at,
          counts: %{
            running: length(running),
            retrying: length(retrying),
            paused: length(paused),
            needs_guidance: length(needs_guidance)
          },
          running: Enum.map(running, &running_entry_payload/1),
          retrying: Enum.map(retrying, &retry_entry_payload/1),
          needs_guidance: Enum.map(needs_guidance, &needs_guidance_entry_payload/1),
          paused: Enum.map(paused, &paused_entry_payload/1),
          archived: group_archived_by_ticket(archived),
          model_usage: ModelUsage.aggregate(running, archived),
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
        paused = snapshot |> Map.get(:paused, []) |> Enum.find(&(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(paused) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, paused)}
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

  defp issue_payload_body(issue_identifier, running, retry, paused) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, paused),
      status: issue_status(running, retry, paused),
      workspace: workspace_payload(issue_identifier, paused),
      attempts: attempts_payload(retry),
      running: maybe_running_issue_payload(running),
      retry: maybe_retry_issue_payload(retry),
      paused: maybe_paused_issue_payload(paused),
      logs: logs_payload(running),
      recent_events: recent_events_for(running),
      last_error: retry_error(retry),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, paused),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (paused && paused.issue_id)

  defp workspace_payload(issue_identifier, paused) do
    %{path: paused_workspace(paused) || Path.join(Config.workspace_root(), issue_identifier)}
  end

  defp paused_workspace(nil), do: nil
  defp paused_workspace(paused), do: Map.get(paused, :workspace)

  defp attempts_payload(retry) do
    %{
      restart_count: restart_count(retry),
      current_retry_attempt: retry_attempt(retry)
    }
  end

  defp maybe_running_issue_payload(nil), do: nil
  defp maybe_running_issue_payload(running), do: running_issue_payload(running)

  defp maybe_retry_issue_payload(nil), do: nil
  defp maybe_retry_issue_payload(retry), do: retry_issue_payload(retry)

  defp maybe_paused_issue_payload(nil), do: nil
  defp maybe_paused_issue_payload(paused), do: paused_issue_payload(paused)

  defp logs_payload(nil), do: %{claude_session_logs: []}
  defp logs_payload(running), do: %{claude_session_logs: format_event_log(Map.get(running, :event_log, []))}

  defp recent_events_for(nil), do: []
  defp recent_events_for(running), do: recent_events_payload(running)

  defp retry_error(nil), do: nil
  defp retry_error(retry), do: retry.error

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(nil, nil, _paused), do: "paused"
  defp issue_status(_running, nil, _paused), do: "running"
  defp issue_status(nil, _retry, _paused), do: "retrying"
  defp issue_status(_running, _retry, _paused), do: "running"

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
      latest_gate: gate_payload(Map.get(entry, :latest_gate)),
      model_routing: Map.get(entry, :model_routing),
      model_fallback: Map.get(entry, :model_fallback),
      tokens: %{
        input_tokens: entry.claude_input_tokens,
        output_tokens: entry.claude_output_tokens,
        total_tokens: entry.claude_total_tokens
      },
      model_routing: Map.get(entry, :model_routing),
      adapter: Map.get(entry, :adapter),
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

  defp paused_entry_payload(entry) do
    %{
      issue_id: entry_value(entry, :issue_id),
      issue_identifier: entry_value(entry, :identifier),
      state: entry_value(entry, :state),
      session_id: entry_value(entry, :session_id),
      run_id: Map.get(entry, :run_id),
      run_dir: Map.get(entry, :run_dir),
      workspace: Map.get(entry, :workspace),
      paused_at: timestamp_payload(Map.get(entry, :paused_at)),
      retry_attempt: Map.get(entry, :retry_attempt),
      tracker_visibility: Map.get(entry, :tracker_visibility),
      blocks_dispatch: Map.get(entry, :blocks_dispatch, true),
      blocked_dispatch_reason: Map.get(entry, :blocked_dispatch_reason),
      stale_reason: Map.get(entry, :stale_reason),
      revalidated_at: timestamp_payload(Map.get(entry, :revalidated_at)),
      latest_gate: gate_payload(Map.get(entry, :latest_gate)),
      model_routing: Map.get(entry, :model_routing),
      model_fallback: Map.get(entry, :model_fallback),
      interrupt: interrupt_payload(Map.get(entry, :interrupt)),
      tokens: %{
        input_tokens: Map.get(entry, :claude_input_tokens, 0),
        output_tokens: Map.get(entry, :claude_output_tokens, 0),
        total_tokens: Map.get(entry, :claude_total_tokens, 0)
      },
      event_log: format_event_log(Map.get(entry, :event_log, []))
    }
  end

  defp needs_guidance_entry_payload(entry) do
    paused = paused_entry_payload(entry)
    interrupt = Map.get(paused, :interrupt, %{}) || %{}

    paused
    |> Map.take([
      :issue_id,
      :issue_identifier,
      :state,
      :session_id,
      :run_id,
      :run_dir,
      :workspace,
      :paused_at,
      :retry_attempt,
      :tracker_visibility,
      :blocks_dispatch,
      :blocked_dispatch_reason,
      :stale_reason,
      :revalidated_at,
      :tokens,
      :event_log
    ])
    |> Map.merge(%{
      guidance_severity: Map.get(interrupt, :guidance_severity),
      blocked_side_effect: Map.get(interrupt, :blocked_side_effect),
      suggested_responses: Map.get(interrupt, :suggested_responses, []),
      upcoming_transitions: Map.get(interrupt, :upcoming_transitions, %{}),
      interrupt: interrupt
    })
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
      latest_gate: gate_payload(Map.get(running, :latest_gate)),
      model_routing: Map.get(running, :model_routing),
      model_fallback: Map.get(running, :model_fallback),
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

  defp paused_issue_payload(paused) do
    paused
    |> paused_entry_payload()
    |> Map.delete(:issue_identifier)
  end

  defp entry_value(entry, key) when is_map(entry) and is_atom(key) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp interrupt_payload(nil), do: nil

  defp interrupt_payload(interrupt) when is_map(interrupt) do
    suggested_responses = payload_value(interrupt, :suggested_responses) || payload_value(interrupt, :options) || []

    %{
      reason: payload_value(interrupt, :reason),
      state: payload_value(interrupt, :state),
      question: payload_value(interrupt, :question),
      options: normalize_payload_list(payload_value(interrupt, :options) || []),
      recommendation: payload_value(interrupt, :recommendation),
      guidance_severity: payload_value(interrupt, :guidance_severity),
      blocked_side_effect: normalize_payload_map(payload_value(interrupt, :blocked_side_effect)),
      policy: normalize_payload_map(payload_value(interrupt, :policy)),
      suggested_responses: normalize_payload_list(suggested_responses),
      upcoming_transitions: normalize_payload_map(payload_value(interrupt, :upcoming_transitions)),
      resume: normalize_payload_map(payload_value(interrupt, :resume)),
      gate: payload_value(interrupt, :gate)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp interrupt_payload(_interrupt), do: nil

  defp payload_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp guidance_entry?(entry) when is_map(entry) do
    interrupt = Map.get(entry, :interrupt, Map.get(entry, "interrupt", %{}))

    if is_map(interrupt) do
      interrupt
      |> payload_value(:reason)
      |> case do
        reason when is_binary(reason) and reason != "" -> true
        _ -> false
      end
    else
      false
    end
  end

  defp guidance_entry?(_entry), do: false

  defp normalize_payload_list(values) when is_list(values), do: Enum.map(values, &normalize_payload_map/1)
  defp normalize_payload_list(_values), do: []

  defp normalize_payload_map(nil), do: nil

  defp normalize_payload_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_payload_key(key), normalize_payload_value(value)} end)
  end

  defp normalize_payload_map(value), do: value

  defp normalize_payload_value(value) when is_map(value), do: normalize_payload_map(value)
  defp normalize_payload_value(value) when is_list(value), do: Enum.map(value, &normalize_payload_value/1)
  defp normalize_payload_value(value), do: value

  defp normalize_payload_key(key) when is_atom(key), do: key
  defp normalize_payload_key(key) when is_binary(key), do: String.to_atom(key)
  defp normalize_payload_key(key), do: key

  defp gate_payload(nil), do: nil

  defp gate_payload(gate) when is_map(gate) do
    failed =
      case Map.get(gate, :failed, Map.get(gate, "failed", [])) do
        failures when is_list(failures) -> Enum.map(failures, &gate_failure_payload/1)
        _other -> []
      end

    %{
      status: Map.get(gate, :status) || Map.get(gate, "status"),
      results_path: Map.get(gate, :results_path) || Map.get(gate, "results_path"),
      state_path: Map.get(gate, :state_path) || Map.get(gate, "state_path"),
      workspace_identity: Map.get(gate, :workspace_identity) || Map.get(gate, "workspace_identity"),
      gate_signature: Map.get(gate, :gate_signature) || Map.get(gate, "gate_signature"),
      reused_from: Map.get(gate, :reused_from) || Map.get(gate, "reused_from"),
      failed: failed
    }
  end

  defp gate_payload(_gate), do: nil

  defp gate_failure_payload(failure) when is_map(failure) do
    %{
      name: Map.get(failure, :name) || Map.get(failure, "name"),
      status: Map.get(failure, :status) || Map.get(failure, "status"),
      exit_status: Map.get(failure, :exit_status) || Map.get(failure, "exit_status")
    }
  end

  defp gate_failure_payload(failure), do: %{name: to_string(failure), status: nil, exit_status: nil}

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
      non_active_state: Map.get(entry, :non_active_state),
      turn_count: entry.turn_count,
      latest_gate: gate_payload(Map.get(entry, :latest_gate)),
      tokens: entry.tokens,
      model_routing: Map.get(entry, :model_routing),
      adapter: Map.get(entry, :adapter),
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
      {:ok, dt, _} ->
        run_filename(dt)

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
      message = summarize_message(entry[:message])
      event = refine_event_from_message(entry[:event], message)

      %{at: iso8601(entry[:at]), event: event, message: message}
    end)
  end

  defp format_event_log(_), do: []

  defp refine_event_from_message(event, message)
       when event in [:assistant, "assistant"] and is_binary(message) do
    cond do
      linear_message?(message) -> :linear
      github_message?(message) -> :github
      String.starts_with?(message, "$ ") -> :bash
      true -> prefixed_event_label(message) || :assistant
    end
  end

  defp refine_event_from_message(event, _message), do: event

  defp linear_message?(message), do: String.contains?(message, "linear") or String.contains?(message, "Linear")

  defp github_message?(message), do: String.starts_with?(message, "$ gh ") or String.starts_with?(message, "$ git ")

  defp prefixed_event_label(message) do
    Enum.find_value(event_prefixes(), fn {prefix, event} ->
      if String.starts_with?(message, prefix), do: event
    end)
  end

  defp event_prefixes do
    [
      {"Read ", :read},
      {"Write ", :write},
      {"Edit ", :edit},
      {"Grep ", :grep},
      {"Glob ", :glob},
      {"Agent", :agent},
      {"ToolSearch", :tool},
      {"mcp__", :tool}
    ]
  end

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

  defp timestamp_payload(%DateTime{} = datetime), do: iso8601(datetime)
  defp timestamp_payload(timestamp) when is_binary(timestamp), do: timestamp
  defp timestamp_payload(_timestamp), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  # --- Chart data projections ---

  @spec token_timeseries() :: map()
  def token_timeseries do
    samples = Rondo.TimeSeries.read()

    labels =
      Enum.map(samples, fn s ->
        case s.at do
          %DateTime{} = dt -> Calendar.strftime(dt, "%H:%M:%S")
          _ -> ""
        end
      end)

    %{
      labels: labels,
      input: Enum.map(samples, & &1.input_tokens),
      output: Enum.map(samples, & &1.output_tokens)
    }
  end

  @spec session_timeseries() :: map()
  def session_timeseries do
    samples = Rondo.TimeSeries.read()

    labels =
      Enum.map(samples, fn s ->
        case s.at do
          %DateTime{} = dt -> Calendar.strftime(dt, "%H:%M:%S")
          _ -> ""
        end
      end)

    %{
      labels: labels,
      running: Enum.map(samples, & &1.running),
      retrying: Enum.map(samples, & &1.retrying)
    }
  end

  @spec run_outcomes(list()) :: map()
  def run_outcomes(archived_groups) when is_list(archived_groups) do
    %{
      labels: Enum.map(archived_groups, & &1.issue_identifier),
      values: Enum.map(archived_groups, & &1.total_tokens),
      colors: Enum.map(archived_groups, & &1.latest_result)
    }
  end

  def run_outcomes(_), do: %{labels: [], values: [], colors: []}

  @spec run_token_comparison(list()) :: map()
  def run_token_comparison(runs) when is_list(runs) do
    %{
      labels:
        runs
        |> Enum.with_index(1)
        |> Enum.map(fn {r, i} -> run_label(r, i) end),
      input: Enum.map(runs, fn r -> get_in(r, [:tokens, :input_tokens]) || 0 end),
      output: Enum.map(runs, fn r -> get_in(r, [:tokens, :output_tokens]) || 0 end)
    }
  end

  def run_token_comparison(_), do: %{labels: [], input: [], output: []}

  @spec run_duration_comparison(list()) :: map()
  def run_duration_comparison(runs) when is_list(runs) do
    %{
      labels:
        runs
        |> Enum.with_index(1)
        |> Enum.map(fn {r, i} -> run_label(r, i) end),
      durations:
        Enum.map(runs, fn r ->
          case {r[:started_at], r[:finished_at]} do
            {s, f} when is_binary(s) and is_binary(f) ->
              with {:ok, s_dt, _} <- DateTime.from_iso8601(s),
                   {:ok, f_dt, _} <- DateTime.from_iso8601(f) do
                DateTime.diff(f_dt, s_dt, :second)
              else
                _ -> 0
              end

            _ ->
              0
          end
        end)
    }
  end

  def run_duration_comparison(_), do: %{labels: [], durations: []}

  defp run_label(run, index) do
    case run[:started_at] do
      timestamp when is_binary(timestamp) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, dt, _} -> "Run #{index} (#{Calendar.strftime(dt, "%H:%M")})"
          _ -> "Run #{index}"
        end

      _ ->
        "Run #{index}"
    end
  end
end
