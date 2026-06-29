defmodule Rondo.RunTimeline do
  # credo:disable-for-this-file
  @moduledoc """
  Normalizes active and archived runs into a chronological timeline.

  Prefers ledger checkpoints when present and falls back to archived run event
  logs or terminal metadata for older ledgers.
  """

  alias Rondo.{Orchestrator, RunLedger}

  @checkpoint_kinds MapSet.new([
                      "dispatch",
                      "action_policy_decision",
                      "workspace_ready",
                      "turn_started",
                      "turn_completed",
                      "turn_failed",
                      "turn_cancelled",
                      "edit_batch",
                      "gates_completed",
                      "gates_reused",
                      "final_report_validated",
                      "interrupt_created",
                      "run_decision",
                      "completed",
                      "failed",
                      "terminated"
                    ])

  @event_to_step_kind %{
    "claude_starting" => "workspace_ready",
    "session_started" => "turn_started",
    "result" => "turn_completed",
    "invocation_completed" => "turn_completed",
    "invocation_failed" => "turn_failed",
    "gates_completed" => "gates_completed",
    "gates_reused" => "gates_reused"
  }

  @tool_event_kinds MapSet.new([
                      "assistant",
                      "assistant_message",
                      "tool",
                      "tool_use",
                      "tool_started",
                      "tool_updated",
                      "tool_completed",
                      "bash",
                      "read",
                      "write",
                      "edit",
                      "grep",
                      "agent",
                      "linear",
                      "github"
                    ])

  @decision_kinds MapSet.new(["continue", "stop", "retry", "pause", "fail", "terminate"])
  @terminal_kinds MapSet.new(["completed", "failed", "terminated"])

  @type run_entry :: map()
  @type run_projection :: map()

  @spec project([run_entry()], [run_entry()], keyword()) :: [run_projection()]
  def project(running, archived, opts \\ []) when is_list(running) and is_list(archived) do
    archived_loader = Keyword.get(opts, :archived_loader, &Orchestrator.load_archived_run/2)

    (Enum.map(running, &project_run(&1, opts)) ++
       Enum.map(archived, &project_archived_run(&1, archived_loader, opts)))
    |> Enum.sort_by(&sortable_started_at/1, {:asc, DateTime})
  end

  @spec project_run(run_entry(), keyword()) :: run_projection()
  def project_run(run, opts \\ []) when is_map(run) do
    run = maybe_load_archived_run(run, opts)
    manifest = manifest_for_run(run)
    checkpoints = checkpoint_steps(run, manifest)
    events = event_steps(run, checkpoints)
    synthetic = synthetic_steps(run, manifest, checkpoints ++ events)

    timeline =
      checkpoints
      |> Kernel.++(events)
      |> Kernel.++(synthetic)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&step_sort_key/1)
      |> annotate_durations(run)

    %{
      identifier: entry_value(run, :identifier),
      run_id: entry_value(run, :run_id),
      run_dir: entry_value(run, :run_dir),
      session_id: entry_value(run, :session_id),
      status: run_status(run, manifest),
      archived: archived_run?(run, manifest),
      started_at: iso8601(entry_value(run, :started_at)),
      finished_at: iso8601(entry_value(run, :finished_at)),
      exit_reason: entry_value(run, :exit_reason),
      turn_count: entry_value(run, :turn_count) || 0,
      timeline: timeline
    }
    |> drop_nil_values()
  end

  @spec project_archived_run(run_entry(), (String.t(), String.t() -> {:ok, map()} | {:error, term()}), keyword()) :: run_projection()
  def project_archived_run(run, archived_loader, opts) when is_map(run) and is_function(archived_loader, 2) do
    run
    |> maybe_load_archived_run(load_archive?: true, archived_loader: archived_loader)
    |> project_run(opts)
    |> Map.put_new(:archived, true)
  end

  defp maybe_load_archived_run(run, opts) when is_list(opts) do
    load_archive? = Keyword.get(opts, :load_archive?, false)
    archived_loader = Keyword.get(opts, :archived_loader)

    if load_archive? and is_function(archived_loader, 2) and is_binary(entry_value(run, :identifier)) and not is_nil(entry_value(run, :started_at)) do
      identifier = entry_value(run, :identifier)
      filename = archive_filename(entry_value(run, :started_at))

      case archived_loader.(identifier, filename) do
        {:ok, loaded} when is_map(loaded) ->
          Map.merge(loaded, run, fn _key, loaded_value, run_value ->
            if is_nil(loaded_value), do: run_value, else: loaded_value
          end)

        _ ->
          run
      end
    else
      run
    end
  end

  defp manifest_for_run(run) do
    case entry_value(run, :run_dir) do
      run_dir when is_binary(run_dir) ->
        case RunLedger.load_manifest(run_dir) do
          {:ok, manifest} -> manifest
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp checkpoint_steps(run, manifest) when is_map(manifest) do
    run_dir = entry_value(run, :run_dir)

    manifest
    |> Map.get("checkpoints", [])
    |> Enum.map(&checkpoint_step(run_dir, &1, run, manifest))
    |> Enum.reject(&is_nil/1)
  end

  defp checkpoint_steps(_run, _manifest), do: []

  defp checkpoint_step(run_dir, meta, run, manifest) when is_map(meta) do
    kind = Map.get(meta, "kind") || Map.get(meta, :kind)

    if MapSet.member?(@checkpoint_kinds, kind) do
      timestamp = Map.get(meta, "timestamp") || Map.get(meta, :timestamp)
      checkpoint_rel_path = Map.get(meta, "path") || Map.get(meta, :path)
      checkpoint_file = checkpoint_file_path(run_dir, checkpoint_rel_path)
      payload = checkpoint_payload(checkpoint_file, meta)

      case kind do
        "dispatch" ->
          build_step("dispatch", timestamp, payload, run, source_kind: "checkpoint", checkpoint_path: checkpoint_rel_path, manifest: manifest)

        "action_policy_decision" ->
          build_step("action_policy_decision", timestamp, payload, run, source_kind: "checkpoint", checkpoint_path: checkpoint_rel_path, manifest: manifest)

        "workspace_ready" ->
          build_step("workspace_ready", timestamp, payload, run, source_kind: "checkpoint", checkpoint_path: checkpoint_rel_path, manifest: manifest)

        "turn_started" ->
          build_step("turn_started", timestamp, payload, run, source_kind: "checkpoint", checkpoint_path: checkpoint_rel_path, manifest: manifest)

        "turn_completed" ->
          build_step("turn_completed", timestamp, payload, run, source_kind: "checkpoint", checkpoint_path: checkpoint_rel_path, manifest: manifest)

        "turn_failed" ->
          build_step("turn_failed", timestamp, payload, run, source_kind: "checkpoint", checkpoint_path: checkpoint_rel_path, manifest: manifest)

        "turn_cancelled" ->
          build_step("turn_cancelled", timestamp, payload, run, source_kind: "checkpoint", checkpoint_path: checkpoint_rel_path, manifest: manifest)

        "edit_batch" ->
          build_step("tool_activity", timestamp, payload, run,
            source_kind: "checkpoint",
            checkpoint_path: checkpoint_rel_path,
            status: "completed",
            outcome: "edit_batch",
            phase: "tool",
            manifest: manifest
          )

        "gates_completed" ->
          build_step("gates_completed", timestamp, payload, run, source_kind: "checkpoint", checkpoint_path: checkpoint_rel_path, manifest: manifest)

        "gates_reused" ->
          build_step("gates_reused", timestamp, payload, run, source_kind: "checkpoint", checkpoint_path: checkpoint_rel_path, manifest: manifest)

        "final_report_validated" ->
          build_step("final_report_validated", timestamp, payload, run, source_kind: "checkpoint", checkpoint_path: checkpoint_rel_path, manifest: manifest)

        "interrupt_created" ->
          build_step("interrupt_created", timestamp, payload, run, source_kind: "checkpoint", checkpoint_path: checkpoint_rel_path, manifest: manifest)

        "run_decision" ->
          build_run_decision_step(timestamp, payload, run, checkpoint_rel_path, manifest)

        "completed" ->
          build_terminal_step("completed", timestamp, payload, run, checkpoint_rel_path,
            source_kind: "checkpoint",
            checkpoint_path: checkpoint_rel_path,
            manifest: manifest
          )

        "failed" ->
          build_terminal_step("failed", timestamp, payload, run, checkpoint_rel_path,
            source_kind: "checkpoint",
            checkpoint_path: checkpoint_rel_path,
            manifest: manifest
          )

        "terminated" ->
          build_terminal_step("terminated", timestamp, payload, run, checkpoint_rel_path,
            source_kind: "checkpoint",
            checkpoint_path: checkpoint_rel_path,
            manifest: manifest
          )
      end
    else
      nil
    end
  end

  defp checkpoint_payload(nil, meta), do: Map.get(meta, "payload") || Map.get(meta, :payload) || %{}

  defp checkpoint_payload(file, meta) do
    case read_json_file(file) do
      {:ok, decoded} -> Map.get(decoded, "payload", %{})
      _ -> Map.get(meta, "payload") || Map.get(meta, :payload) || %{}
    end
  end

  defp event_steps(run, checkpoints) do
    event_log_entries(run)
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> event_log_step(entry, index, run, checkpoints == []) end)
    |> Enum.reject(&is_nil/1)
  end

  defp event_log_entries(run) do
    case entry_value(run, :event_log, []) do
      log when is_list(log) -> log
      _ -> []
    end
  end

  defp event_log_step(entry, index, run, primary?) when is_map(entry) do
    event = normalize_string(entry_value(entry, :event))

    cond do
      not primary? and Map.has_key?(@event_to_step_kind, event) ->
        nil

      step_kind = Map.get(@event_to_step_kind, event) ->
        build_step(step_kind, entry_value(entry, :at) || entry_value(entry, :timestamp), %{"summary" => entry_value(entry, :message)}, run,
          source_kind: "event_log",
          event_index: index,
          status: default_status(step_kind, %{}),
          outcome: entry_value(entry, :message),
          usage: entry_value(entry, :usage),
          accounted_usage: entry_value(entry, :tokens) || entry_value(entry, :accounted_usage),
          accounted_usage_delta: entry_value(entry, :tokens) || entry_value(entry, :accounted_usage),
          phase: phase_for_kind(step_kind)
        )

      tool_event?(event) ->
        build_step("tool_activity", entry_value(entry, :at) || entry_value(entry, :timestamp), %{"summary" => entry_value(entry, :message)}, run,
          source_kind: "event_log",
          event_index: index,
          status: "completed",
          outcome: event,
          usage: entry_value(entry, :usage),
          accounted_usage: entry_value(entry, :tokens) || entry_value(entry, :accounted_usage),
          accounted_usage_delta: entry_value(entry, :tokens) || entry_value(entry, :accounted_usage),
          phase: "tool"
        )

      true ->
        nil
    end
  end

  defp event_log_step(_entry, _index, _run, _primary?), do: nil

  defp synthetic_steps(run, manifest, steps) do
    status = run_status(run, manifest)
    pause_present? = Enum.any?(steps, &(&1.kind in ["pause", "interrupt_created"]))
    terminal_present? = Enum.any?(steps, &(&1.kind in ["completed", "failed", "terminated"]))

    cond do
      status == "paused" and not pause_present? ->
        [
          build_step(
            "interrupt_created",
            entry_value(run, :paused_at) || manifest_timestamp(manifest, "paused_at") || entry_value(run, :finished_at),
            manifest_interrupt(manifest) || entry_value(run, :interrupt) || %{},
            run,
            source_kind: "manifest",
            phase: "interrupt",
            status: "paused",
            outcome: "paused",
            summary: interrupt_summary(manifest_interrupt(manifest) || entry_value(run, :interrupt) || %{}),
            manifest: manifest
          )
        ]

      status in ["completed", "failed", "terminated"] and not terminal_present? ->
        [build_terminal_step(status, entry_value(run, :finished_at) || manifest_timestamp(manifest, "finished_at"), %{"status" => status}, run, nil, source_kind: "manifest", manifest: manifest)]

      true ->
        []
    end
  end

  defp build_run_decision_step(timestamp, payload, run, checkpoint_path, manifest) do
    decision_kind = normalize_decision_kind(payload)

    build_step(decision_kind, timestamp, payload, run,
      source_kind: "checkpoint",
      checkpoint_path: checkpoint_path,
      checkpoint_kind: "run_decision",
      phase: "decision",
      status: decision_kind,
      outcome: payload_value(payload, :reason_code) || decision_kind,
      summary: payload_value(payload, :summary) || decision_summary(decision_kind, payload),
      manifest: manifest
    )
  end

  defp build_terminal_step(kind, timestamp, payload, run, checkpoint_path, opts) when kind in ["completed", "failed", "terminated"] do
    build_step(
      kind,
      timestamp,
      payload,
      run,
      Keyword.merge(opts,
        checkpoint_path: checkpoint_path,
        checkpoint_kind: kind,
        phase: "terminal",
        status: kind,
        outcome: payload_value(payload, :reason) || payload_value(payload, :phase) || kind,
        summary: payload_value(payload, :summary) || "run #{kind}"
      )
    )
  end

  defp build_step(kind, timestamp, payload, run, opts) when is_list(opts) do
    kind = normalize_string(kind)
    phase = Keyword.get(opts, :phase, phase_for_kind(kind))
    status = Keyword.get(opts, :status, default_status(kind, payload))
    outcome = Keyword.get(opts, :outcome, default_outcome(kind, payload))
    summary = Keyword.get(opts, :summary, summary_for_kind(kind, payload, run))
    checkpoint_path = Keyword.get(opts, :checkpoint_path)
    source_kind = Keyword.get(opts, :source_kind, "checkpoint")
    event_index = Keyword.get(opts, :event_index)
    manifest = Keyword.get(opts, :manifest)

    %{
      at: iso8601(timestamp),
      timestamp: iso8601(timestamp),
      phase: phase,
      kind: kind,
      status: normalize_string(status),
      outcome: normalize_string(outcome),
      summary: normalize_string(summary),
      run_id: entry_value(run, :run_id),
      run_dir: entry_value(run, :run_dir),
      issue_id: entry_value(run, :issue_id),
      identifier: entry_value(run, :identifier),
      session_id: entry_value(run, :session_id),
      turn_number: turn_number_for(kind, payload, run),
      retry_attempt: entry_value(payload, :retry_attempt) || entry_value(run, :retry_attempt),
      usage: Keyword.get(opts, :usage) || payload_value(payload, :usage),
      accounted_usage:
        Keyword.get(opts, :accounted_usage) ||
          Keyword.get(opts, :accounted_usage_delta) ||
          payload_value(payload, :accounted_usage) ||
          payload_value(payload, :accounted_usage_delta),
      accounted_usage_delta:
        Keyword.get(opts, :accounted_usage_delta) ||
          Keyword.get(opts, :accounted_usage) ||
          payload_value(payload, :accounted_usage_delta) ||
          payload_value(payload, :accounted_usage),
      artifacts: artifact_refs(kind, checkpoint_path, payload, run, manifest),
      source:
        %{
          kind: source_kind,
          checkpoint_kind: Keyword.get(opts, :checkpoint_kind, kind),
          event_index: event_index,
          path: checkpoint_path
        }
        |> drop_nil_values()
    }
    |> drop_nil_values()
  end

  defp artifact_refs(kind, checkpoint_path, payload, run, manifest) do
    []
    |> add_artifact(checkpoint_path, "checkpoint")
    |> add_artifact(event_log_path(entry_value(run, :run_dir)), "agent_events")
    |> add_artifact(payload_value(payload, :results_path), "gate_results")
    |> add_artifact(payload_value(payload, :state_path), "gate_state")
    |> add_artifact(payload_value(payload, :diff_source), "diff_source")
    |> add_artifact(final_report_path(kind, manifest), "final_report")
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp add_artifact(refs, nil, _kind), do: refs
  defp add_artifact(refs, path, kind), do: refs ++ [%{kind: kind, path: path, status: "present"}]

  defp final_report_path("final_report_validated", manifest) when is_map(manifest) do
    get_in(manifest, ["final_report", "path"]) || RunLedger.final_report_relative_path()
  end

  defp final_report_path(_, _), do: nil

  defp event_log_path(nil), do: nil
  defp event_log_path(run_dir), do: Path.join(run_dir, "artifacts/agent-events.ndjson")

  defp decision_kind?(kind), do: MapSet.member?(@decision_kinds, kind)
  defp terminal_kind?(kind), do: MapSet.member?(@terminal_kinds, kind)

  defp phase_for_kind(kind) when kind in ["dispatch"], do: "dispatch"
  defp phase_for_kind(kind) when kind in ["action_policy_decision"], do: "policy"
  defp phase_for_kind(kind) when kind in ["workspace_ready"], do: "workspace"
  defp phase_for_kind(kind) when kind in ["turn_started", "turn_completed", "turn_failed", "turn_cancelled"], do: "turn"
  defp phase_for_kind(kind) when kind in ["tool_activity", "edit_batch"], do: "tool"
  defp phase_for_kind(kind) when kind in ["gates_completed", "gates_reused"], do: "gates"
  defp phase_for_kind(kind) when kind in ["final_report_validated"], do: "final_report"
  defp phase_for_kind(kind) when kind in ["interrupt_created", "pause"], do: "interrupt"
  defp phase_for_kind(kind) when kind in ["completed", "failed", "terminated"], do: "terminal"

  defp phase_for_kind(kind) when kind in ["continue", "stop", "retry", "pause", "fail", "terminate"], do: "decision"

  defp summary_for_kind("dispatch", payload, _run), do: payload_value(payload, :summary) || "dispatch"
  defp summary_for_kind("action_policy_decision", payload, _run), do: payload_value(payload, :summary) || decision_summary(payload_value(payload, :decision_kind), payload)
  defp summary_for_kind("workspace_ready", payload, _run), do: payload_value(payload, :summary) || "workspace ready"
  defp summary_for_kind("turn_started", payload, _run), do: payload_value(payload, :summary) || turn_summary("started", payload)
  defp summary_for_kind("turn_completed", payload, _run), do: payload_value(payload, :summary) || turn_summary("completed", payload)
  defp summary_for_kind("turn_failed", payload, _run), do: payload_value(payload, :summary) || turn_summary("failed", payload)
  defp summary_for_kind("turn_cancelled", payload, _run), do: payload_value(payload, :summary) || turn_summary("cancelled", payload)
  defp summary_for_kind("tool_activity", payload, _run), do: payload_value(payload, :summary) || "tool activity"
  defp summary_for_kind("gates_completed", payload, _run), do: payload_value(payload, :summary) || gate_summary(payload)
  defp summary_for_kind("gates_reused", _payload, _run), do: "gates reused"
  defp summary_for_kind("final_report_validated", payload, _run), do: payload_value(payload, :summary) || final_report_summary(payload)
  defp summary_for_kind("interrupt_created", payload, _run), do: payload_value(payload, :summary) || interrupt_summary(payload)

  defp summary_for_kind(kind, payload, _run) do
    cond do
      decision_kind?(kind) -> payload_value(payload, :summary) || decision_summary(kind, payload)
      terminal_kind?(kind) -> "run #{kind}"
    end
  end

  defp default_status("dispatch", _payload), do: "completed"
  defp default_status("action_policy_decision", _payload), do: "completed"
  defp default_status("workspace_ready", _payload), do: "ready"
  defp default_status("turn_started", _payload), do: "started"
  defp default_status("turn_completed", _payload), do: "completed"
  defp default_status("turn_failed", _payload), do: "failed"
  defp default_status("turn_cancelled", _payload), do: "cancelled"
  defp default_status("tool_activity", _payload), do: "completed"
  defp default_status("gates_completed", payload), do: payload_value(payload, :status) || "completed"
  defp default_status("gates_reused", _payload), do: "completed"
  defp default_status("final_report_validated", payload), do: payload_value(payload, :status) || "completed"
  defp default_status("interrupt_created", _payload), do: "paused"

  defp default_status(kind, _payload) do
    cond do
      decision_kind?(kind) -> kind
      terminal_kind?(kind) -> kind
    end
  end

  defp default_outcome("dispatch", payload), do: payload_value(payload, :reason_code) || payload_value(payload, :summary)
  defp default_outcome("action_policy_decision", payload), do: payload_value(payload, :reason_code) || payload_value(payload, :status)
  defp default_outcome("workspace_ready", _payload), do: nil
  defp default_outcome("turn_started", _payload), do: "started"
  defp default_outcome("turn_completed", payload), do: payload_value(payload, :status) || payload_value(payload, :summary)
  defp default_outcome("turn_failed", payload), do: payload_value(payload, :status) || payload_value(payload, :summary)
  defp default_outcome("turn_cancelled", payload), do: payload_value(payload, :status) || payload_value(payload, :summary)
  defp default_outcome("tool_activity", payload), do: payload_value(payload, :reason_code) || payload_value(payload, :summary)
  defp default_outcome("gates_completed", payload), do: payload_value(payload, :status) || payload_value(payload, :summary)
  defp default_outcome("gates_reused", _payload), do: "reused"
  defp default_outcome("final_report_validated", payload), do: payload_value(payload, :status)
  defp default_outcome("interrupt_created", payload), do: payload_value(payload, :reason)

  defp default_outcome(kind, payload) do
    cond do
      decision_kind?(kind) -> payload_value(payload, :reason_code) || kind
      terminal_kind?(kind) -> kind
    end
  end

  defp turn_summary(status, payload) do
    case payload_value(payload, :turn_number) do
      nil -> "turn #{status}"
      turn_number -> "turn #{turn_number} #{status}"
    end
  end

  defp gate_summary(payload), do: "gates #{payload_value(payload, :status) || "completed"}"
  defp final_report_summary(payload), do: "final report #{payload_value(payload, :status) || "validated"}"
  defp interrupt_summary(payload), do: payload_value(payload, :summary) || payload_value(payload, :question) || payload_value(payload, :reason) || "interrupt created"

  defp decision_summary(kind, payload) do
    case payload_value(payload, :reason_code) do
      nil -> kind
      reason_code -> "#{kind} because #{reason_code}"
    end
  end

  defp normalize_decision_kind(payload) do
    case payload_value(payload, :decision_kind) do
      decision_kind when is_binary(decision_kind) and decision_kind != "" -> decision_kind
      _ -> "continue"
    end
  end

  defp turn_number_for(kind, payload, run) do
    payload_value(payload, :turn_number) ||
      case kind do
        "turn_started" -> entry_value(run, :turn_count)
        "turn_completed" -> entry_value(run, :turn_count)
        "turn_failed" -> entry_value(run, :turn_count)
        _ -> nil
      end
  end

  defp run_status(run, manifest) do
    manifest_status = manifest && Map.get(manifest, "status")
    exit_reason = entry_value(run, :exit_reason)

    cond do
      is_binary(manifest_status) and manifest_status != "running" -> manifest_status
      exit_reason in ["completed", "terminated", "failed"] -> exit_reason
      is_binary(exit_reason) and String.starts_with?(exit_reason, "exited") -> "failed"
      exit_reason == "handed_off" -> "paused"
      entry_value(run, :paused_at) || manifest_timestamp(manifest, "paused_at") -> "paused"
      true -> "running"
    end
  end

  defp archived_run?(run, manifest) do
    run_status(run, manifest) != "running" or is_binary(entry_value(run, :exit_reason))
  end

  defp manifest_timestamp(nil, _key), do: nil
  defp manifest_timestamp(manifest, key) when is_map(manifest), do: get_in(manifest, ["timestamps", key])

  defp manifest_interrupt(manifest), do: Map.get(manifest || %{}, "interrupt")

  defp checkpoint_file_path(run_dir, rel_path) when is_binary(run_dir) and is_binary(rel_path), do: Path.join(run_dir, rel_path)
  defp checkpoint_file_path(_run_dir, rel_path), do: rel_path

  defp read_json_file(path) do
    with {:ok, json} <- File.read(path),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    end
  end

  defp payload_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp entry_value(entry, key, default \\ nil) when is_map(entry) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key)) || default
  end

  defp tool_event?(event), do: MapSet.member?(@tool_event_kinds, event)

  defp normalize_string(nil), do: nil
  defp normalize_string(value), do: to_string(value)

  defp sortable_started_at(%{started_at: started_at}), do: sortable_dt(started_at)
  defp sortable_started_at(_), do: ~U[1970-01-01 00:00:00Z]

  defp sortable_dt(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> ~U[1970-01-01 00:00:00Z]
    end
  end

  defp sortable_dt(_), do: ~U[1970-01-01 00:00:00Z]

  defp step_sort_key(step) do
    {sortable_dt(step_timestamp(step)), Map.get(step, :source, %{}) |> Map.get(:event_index, 0)}
  end

  defp step_timestamp(step), do: Map.get(step, :timestamp) || Map.get(step, "timestamp") || Map.get(step, :at) || Map.get(step, "at")

  defp annotate_durations([], _run), do: []
  defp annotate_durations([step], run), do: [Map.put(step, :duration_ms, duration_to_finish(step, run))]

  defp annotate_durations([current, next | rest], run) do
    [Map.put(current, :duration_ms, duration_between(current, next)) | annotate_durations([next | rest], run)]
  end

  defp duration_between(current, next) do
    with {:ok, current_dt} <- parse_datetime(step_timestamp(current)),
         {:ok, next_dt} <- parse_datetime(step_timestamp(next)) do
      max(DateTime.diff(next_dt, current_dt, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp duration_to_finish(step, run) do
    with {:ok, start_dt} <- parse_datetime(step_timestamp(step)),
         {:ok, finish_dt} <- parse_datetime(entry_value(run, :finished_at)) do
      max(DateTime.diff(finish_dt, start_dt, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> :error
    end
  end

  defp parse_datetime(_), do: :error

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(ts) when is_binary(ts), do: ts
  defp iso8601(other), do: if(other, do: to_string(other), else: nil)

  defp drop_nil_values(map) when is_map(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  defp archive_filename(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[:\.]/, "-")
    |> Kernel.<>(".json")
  end

  defp archive_filename(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> archive_filename(dt)
      _ -> String.replace(ts, ~r/[:\.]/, "-") <> ".json"
    end
  end
end
