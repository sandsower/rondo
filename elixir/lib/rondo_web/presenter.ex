defmodule RondoWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias Rondo.{Config, ModelUsage, Orchestrator, RunLedger, RunTimeline}

  @dialyzer {:nowarn_function, archived_cost: 1}

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
        archived_table = archived_runs_table(archived)

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
          archived: group_archived_by_ticket(archived_table),
          archived_table: archived_table,
          run_timelines:
            RunTimeline.project(
              running,
              timeline_archived_runs(archived),
              archived_loader: &Orchestrator.load_archived_run/2
            ),
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
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path) || Map.get(entry, :workspace),
      model: display_model(entry),
      provider: provider_from_entry(entry),
      cost: log_cost(entry),
      tokens: %{
        input_tokens: entry.claude_input_tokens,
        output_tokens: entry.claude_output_tokens,
        total_tokens: entry.claude_total_tokens
      },
      adapter: Map.get(entry, :adapter),
      links: entry_links(entry),
      event_log: format_event_log(Map.get(entry, :event_log, []))
    }
  end

  defp retry_entry_payload(entry) do
    payload = %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error
    }

    maybe_put_release_loop(payload, entry_value(entry, :release_loop))
  end

  defp paused_entry_payload(entry) do
    interrupt = interrupt_payload(Map.get(entry, :interrupt)) || %{}
    tracker_state = entry_value(entry, :tracker_state) || entry_value(entry, :state)
    paused_state = entry_value(entry, :paused_state) || entry_value(entry, :state)

    %{
      issue_id: entry_value(entry, :issue_id),
      issue_identifier: entry_value(entry, :identifier),
      state: entry_value(entry, :state),
      paused_state: paused_state,
      tracker_state: tracker_state,
      tracker_state_mismatch: state_mismatch?(paused_state, tracker_state),
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
      links: entry_links(entry),
      suggested_responses: guidance_responses_from_interrupt(interrupt),
      upcoming_transitions: Map.get(interrupt, :upcoming_transitions, %{}),
      interrupt: interrupt,
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
      :paused_state,
      :tracker_state,
      :tracker_state_mismatch,
      :paused_at,
      :retry_attempt,
      :tracker_visibility,
      :blocks_dispatch,
      :blocked_dispatch_reason,
      :stale_reason,
      :revalidated_at,
      :tokens,
      :links,
      :event_log
    ])
    |> Map.merge(%{
      guidance_severity: Map.get(interrupt, :guidance_severity),
      blocked_side_effect: Map.get(interrupt, :blocked_side_effect),
      suggested_responses: guidance_responses_from_interrupt(interrupt),
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
      links: entry_links(running),
      tokens: %{
        input_tokens: running.claude_input_tokens,
        output_tokens: running.claude_output_tokens,
        total_tokens: running.claude_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    payload = %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error
    }

    maybe_put_release_loop(payload, entry_value(retry, :release_loop))
  end

  defp maybe_put_release_loop(payload, release_loop) do
    case release_loop_retry_payload(release_loop) do
      nil -> payload
      release_loop_payload -> Map.put(payload, :release_loop, release_loop_payload)
    end
  end

  defp release_loop_retry_payload(nil), do: nil

  defp release_loop_retry_payload(release_loop) when is_map(release_loop) do
    %{
      phase: release_loop_value(release_loop, :phase),
      action: release_loop_value(release_loop, :action),
      blocked_reason: release_loop_value(release_loop, :blocked_reason),
      wait_interval_seconds: release_loop_value(release_loop, :wait_interval_seconds),
      recovery_kind: release_loop_value(release_loop, :recovery_kind),
      closeout_state: release_loop_value(release_loop, :closeout_state),
      feedback_count: release_loop_value(release_loop, :feedback_count),
      feedback_comment_ids: release_loop_value(release_loop, :feedback_comment_ids),
      mergeable: release_loop_value(release_loop, :mergeable),
      merge_state_status: release_loop_value(release_loop, :merge_state_status),
      pr: release_loop_pr_payload(release_loop_value(release_loop, :pr)),
      checks: normalize_payload_map(release_loop_value(release_loop, :checks))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp release_loop_retry_payload(_release_loop), do: nil

  defp release_loop_pr_payload(nil), do: nil

  defp release_loop_pr_payload(pr) when is_map(pr) do
    %{
      number: release_loop_value(pr, :number),
      url: release_loop_value(pr, :url),
      title: release_loop_value(pr, :title),
      head_ref_name: release_loop_value(pr, :head_ref_name),
      base_ref_name: release_loop_value(pr, :base_ref_name),
      is_draft: release_loop_value(pr, :is_draft)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp release_loop_pr_payload(_pr), do: nil

  defp release_loop_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp paused_issue_payload(paused) do
    paused
    |> paused_entry_payload()
    |> Map.delete(:issue_identifier)
  end

  defp entry_value(entry, key) when is_map(entry) and is_atom(key) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp entry_links(entry) do
    manifest = entry_manifest(entry)
    issue_links = issue_links(entry, manifest)
    review_links = review_links(entry, manifest)

    %{
      tracker: issue_links,
      review: review_links
    }
  end

  defp entry_manifest(%{ledger: %RunLedger{manifest: manifest}}) when is_map(manifest), do: manifest

  defp entry_manifest(entry) do
    case entry_value(entry, :run_dir) do
      run_dir when is_binary(run_dir) and run_dir != "" ->
        case RunLedger.load_manifest(run_dir) do
          {:ok, manifest} when is_map(manifest) -> manifest
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp issue_links(entry, manifest) do
    issue_urls =
      [
        entry_value(entry, :issue_url),
        entry_issue_url(entry),
        get_in(manifest || %{}, ["issue", "url"]),
        get_in(manifest || %{}, ["source_contract", "issue", "url"]),
        get_in(manifest || %{}, ["source_contract", "source_issue_url"]),
        get_in(manifest || %{}, ["issue", "source_issue_url"]),
        get_in(manifest || %{}, ["issue", "source_url"]),
        get_in(manifest || %{}, ["source_issue", "url"])
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    available =
      issue_urls
      |> Enum.map(&issue_link_item/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.url)

    %{
      available: available,
      unavailable: issue_link_unavailable_items(available)
    }
  end

  defp issue_link_unavailable_items(available) do
    kinds = MapSet.new(Enum.map(available, & &1.kind))

    cond do
      MapSet.member?(kinds, :linear_issue) and MapSet.member?(kinds, :github_issue) ->
        []

      MapSet.member?(kinds, :linear_issue) ->
        []

      MapSet.member?(kinds, :github_issue) ->
        []

      available == [] ->
        [%{kind: :issue, label: "Issue", icon: "?", url: nil, reason: "tracker metadata unavailable"}]

      true ->
        []
    end
  end

  defp issue_link_item(url) when is_binary(url) do
    case link_kind_for_url(url) do
      {:linear_issue, label} -> %{kind: :linear_issue, label: label, icon: "L", url: url}
      {:github_issue, label} -> %{kind: :github_issue, label: label, icon: "GH", url: url}
      {:generic_issue, label} -> %{kind: :issue, label: label, icon: "↗", url: url}
    end
  end

  defp issue_link_item(_url), do: nil

  defp review_links(entry, manifest) do
    pr = get_in(manifest || %{}, ["agent", "pr"]) || %{}
    pr_url = pr_url(pr)
    branch_name = branch_name(entry, manifest)
    final_report_path = final_report_path(manifest)

    candidates =
      [
        pr_link_item(pr),
        branch_link_item(branch_name, manifest),
        final_report_link_item(entry, final_report_path)
      ]
      |> Enum.reject(&is_nil/1)

    {available, unavailable} = Enum.split_with(candidates, &link_available?/1)

    available = Enum.uniq_by(available, &{&1.kind, &1.url})
    unavailable = Enum.reject(unavailable, &is_nil/1)

    unavailable =
      if available == [] and unavailable == [] do
        [
          %{
            kind: :review,
            label: "PR / review",
            icon: "PR",
            url: nil,
            reason: review_unavailable_reason(branch_name, pr_url, final_report_path, entry, manifest)
          }
        ]
      else
        unavailable
      end

    %{available: available, unavailable: unavailable}
  end

  defp pr_link_item(%{} = pr) do
    case pr_url(pr) do
      url when is_binary(url) and url != "" ->
        number = Map.get(pr, "number") || Map.get(pr, :number)
        label = if is_integer(number) or is_binary(number), do: "PR ##{number}", else: "PR"
        %{kind: :pull_request, label: label, icon: "PR", url: url}

      _ ->
        nil
    end
  end

  defp branch_link_item(nil, _manifest), do: nil

  defp branch_link_item(branch_name, _manifest) when is_binary(branch_name) do
    case Config.tracker_repo() do
      repo when is_binary(repo) and repo != "" ->
        %{kind: :branch, label: "Branch #{branch_name}", icon: "BR", url: "https://github.com/#{repo}/tree/#{URI.encode(branch_name)}"}

      _ ->
        %{kind: :branch, label: "Branch #{branch_name}", icon: "BR", url: nil, reason: "tracker repo unavailable"}
    end
  end

  defp final_report_link_item(entry, final_report_path) when is_binary(final_report_path) and final_report_path != "" do
    case entry_value(entry, :run_dir) do
      run_dir when is_binary(run_dir) and run_dir != "" ->
        absolute_path = Path.join(run_dir, final_report_path)

        if File.exists?(absolute_path) do
          %{kind: :final_report, label: "Final report", icon: "FR", url: "file://#{absolute_path}"}
        else
          %{kind: :final_report, label: "Final report", icon: "FR", url: nil, reason: "final report artifact missing"}
        end

      _ ->
        %{kind: :final_report, label: "Final report", icon: "FR", url: nil, reason: "run directory unavailable"}
    end
  end

  defp final_report_link_item(_entry, _final_report_path), do: nil

  defp review_unavailable_reason(_branch_name, pr_url, _final_report_path, _entry, _manifest) do
    if is_binary(pr_url) and pr_url != "" do
      nil
    else
      "no branch, PR attachment, GitHub URL, or final report link"
    end
  end

  defp link_available?(item) do
    is_binary(Map.get(item, :url)) and Map.get(item, :url) != ""
  end

  defp branch_name(entry, manifest) do
    entry_branch_name(entry) ||
      get_in(manifest || %{}, ["agent", "pr", "head_ref_name"]) ||
      get_in(manifest || %{}, ["agent", "branch_name"])
  end

  defp entry_branch_name(entry) do
    case entry_value(entry, :issue) do
      %{} = issue -> Map.get(issue, :branch_name) || Map.get(issue, "branch_name")
      _ -> entry_value(entry, :branch_name)
    end
  end

  defp final_report_path(manifest) do
    get_in(manifest || %{}, ["final_report", "path"])
  end

  defp pr_url(%{} = pr) do
    Map.get(pr, :url) || Map.get(pr, "url")
  end

  defp entry_issue_url(entry) do
    case entry_value(entry, :issue) do
      %{} = issue -> Map.get(issue, :url) || Map.get(issue, "url")
      _ -> nil
    end
  end

  defp link_kind_for_url(url) when is_binary(url) do
    cond do
      String.contains?(url, "linear.app") -> {:linear_issue, "Linear issue"}
      String.contains?(url, "github.com") -> {:github_issue, "GitHub issue"}
      true -> {:generic_issue, "Issue"}
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false

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

  @timeline_recent_limit 10
  @timeline_failure_limit 10
  @archived_table_recent_limit 500
  @archived_table_failure_limit 100

  defp timeline_archived_runs(archived) do
    recent = Enum.take(archived, @timeline_recent_limit)

    failures =
      archived
      |> Enum.filter(&(archived_status(Map.get(&1, :exit_reason)) == "failed"))
      |> Enum.take(@timeline_failure_limit)

    (recent ++ failures)
    |> Enum.uniq_by(&{Map.get(&1, :identifier), Map.get(&1, :started_at)})
  end

  @spec archived_runs_table([map()]) :: [map()]
  def archived_runs_table(archived) when is_list(archived) do
    defaults = %{project: Config.linear_project_slug(), repo: Config.tracker_repo()}

    archived
    |> archived_table_window()
    |> Enum.map(&archived_entry_payload(&1, defaults))
    |> Enum.sort_by(&(&1.finished_at || &1.started_at || ""), :desc)
  end

  defp archived_table_window(archived) do
    recent = Enum.take(archived, @archived_table_recent_limit)

    failures =
      archived
      |> Enum.filter(&(archived_status(Map.get(&1, :exit_reason)) == "failed"))
      |> Enum.take(@archived_table_failure_limit)

    (recent ++ failures)
    |> Enum.uniq_by(&{Map.get(&1, :identifier), Map.get(&1, :started_at)})
  end

  defp group_archived_by_ticket(archived_rows) do
    archived_rows
    |> Enum.group_by(& &1.issue_identifier)
    |> Enum.map(fn {identifier, runs} ->
      sorted_runs = Enum.sort_by(runs, & &1.started_at, :asc)
      latest = List.last(sorted_runs)

      %{
        issue_identifier: identifier,
        issue_title: latest.issue_title,
        latest_result: latest.exit_reason,
        latest_finished_at: latest.finished_at,
        total_tokens: Enum.reduce(runs, 0, fn r, acc -> acc + total_tokens(r) end),
        run_count: length(runs),
        links: Map.get(latest, :links),
        runs: sorted_runs
      }
    end)
    |> Enum.sort_by(& &1.latest_finished_at, :desc)
  end

  defp archived_entry_payload(entry, defaults) do
    started_value = Map.get(entry, :started_at)
    finished_value = Map.get(entry, :finished_at)
    started_at = timestamp_payload(started_value)
    finished_at = timestamp_payload(finished_value)
    outcome = Map.get(entry, :exit_reason)

    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      issue_title: Map.get(entry, :issue_title),
      issue_url: Map.get(entry, :issue_url),
      linear_url: Map.get(entry, :issue_url),
      pr_url: Map.get(entry, :pr_url),
      project: Map.get(entry, :project) || defaults.project,
      repo: Map.get(entry, :repo) || defaults.repo,
      workspace: Map.get(entry, :workspace),
      session_id: Map.get(entry, :session_id),
      state: Map.get(entry, :state),
      status: archived_status(outcome),
      outcome: outcome,
      started_at: started_at,
      finished_at: finished_at,
      duration_ms: duration_ms(started_value, finished_value),
      exit_reason: outcome,
      non_active_state: Map.get(entry, :non_active_state),
      turn_count: Map.get(entry, :turn_count),
      latest_gate: gate_payload(Map.get(entry, :latest_gate)),
      tokens: normalize_tokens(Map.get(entry, :tokens, %{})),
      cost: archived_cost_or_log(entry),
      model: display_model(entry),
      provider: provider_from_entry(entry),
      model_routing: Map.get(entry, :model_routing),
      adapter: Map.get(entry, :adapter),
      last_meaningful_result: last_meaningful_result(entry, outcome),
      links: entry_links(entry),
      filename: run_filename(Map.get(entry, :started_at))
    }
  end

  defp normalize_tokens(tokens) when is_map(tokens) do
    %{
      input_tokens: Map.get(tokens, :input_tokens) || Map.get(tokens, "input_tokens") || 0,
      output_tokens: Map.get(tokens, :output_tokens) || Map.get(tokens, "output_tokens") || 0,
      total_tokens: Map.get(tokens, :total_tokens) || Map.get(tokens, "total_tokens") || 0
    }
  end

  defp normalize_tokens(_tokens), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp total_tokens(run), do: get_in(run, [:tokens, :total_tokens]) || 0

  defp archived_status(outcome) when is_binary(outcome) do
    cond do
      outcome == "completed" -> "completed"
      outcome == "terminated" -> "terminated"
      outcome == "handed_off" -> "handed_off"
      String.starts_with?(outcome, "exited") -> "failed"
      true -> outcome
    end
  end

  defp archived_status(_outcome), do: "unknown"

  defp last_meaningful_result(entry, outcome) do
    latest_gate = Map.get(entry, :latest_gate) || %{}

    cond do
      gate_status = Map.get(latest_gate, :status) || Map.get(latest_gate, "status") -> "gates #{gate_status}"
      is_binary(outcome) -> outcome
      true -> "n/a"
    end
  end

  defp duration_ms(%DateTime{} = started_at, %DateTime{} = finished_at) do
    max(DateTime.diff(finished_at, started_at, :millisecond), 0)
  end

  defp duration_ms(started_at, finished_at) when is_binary(started_at) and is_binary(finished_at) do
    with {:ok, started, _} <- DateTime.from_iso8601(started_at),
         {:ok, finished, _} <- DateTime.from_iso8601(finished_at) do
      max(DateTime.diff(finished, started, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp duration_ms(_started_at, _finished_at), do: nil

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

      %{
        at: iso8601(entry[:at]),
        event: event,
        message: message,
        tokens: normalize_event_tokens(Map.get(entry, :tokens)),
        model_change: model_change_from_message(message)
      }
    end)
  end

  defp format_event_log(_), do: []

  defp normalize_event_tokens(nil), do: nil

  defp normalize_event_tokens(tokens) when is_map(tokens) do
    cache_read_tokens = normalize_token_integer(tokens, [:cache_read_tokens, "cache_read_tokens", :cached_input_tokens, "cached_input_tokens"])
    cache_write_tokens = normalize_token_integer(tokens, [:cache_write_tokens, "cache_write_tokens"])

    %{
      input_tokens: normalize_token_integer(tokens, [:input_tokens, "input_tokens"]) || 0,
      output_tokens: normalize_token_integer(tokens, [:output_tokens, "output_tokens"]) || 0,
      total_tokens: normalize_token_integer(tokens, [:total_tokens, "total_tokens"]) || 0,
      cache_read_tokens: cache_read_tokens || 0,
      cache_write_tokens: cache_write_tokens || 0,
      cached_tokens: (cache_read_tokens || 0) + (cache_write_tokens || 0),
      cost: normalize_token_number(tokens, [:cost, "cost"])
    }
  end

  defp normalize_event_tokens(_tokens), do: nil

  defp normalize_token_integer(tokens, keys) when is_map(tokens) and is_list(keys) do
    keys
    |> Enum.find_value(&Map.get(tokens, &1))
    |> normalize_integer_value()
  end

  defp normalize_token_integer(_tokens, _keys), do: nil

  defp normalize_token_number(tokens, keys) when is_map(tokens) and is_list(keys) do
    keys
    |> Enum.find_value(&Map.get(tokens, &1))
    |> normalize_number_value()
  end

  defp normalize_token_number(_tokens, _keys), do: nil

  defp normalize_integer_value(value) when is_integer(value), do: value

  defp normalize_integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer_value(_value), do: nil

  defp normalize_number_value(value) when is_number(value), do: value

  defp normalize_number_value(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_number_value(_value), do: nil

  defp model_change_from_message(message) when is_binary(message) do
    case Regex.run(~r/^model changed:\s*([^\/]+)\/(.+)$/i, message) do
      [_, provider, model] -> %{provider: String.trim(provider), model: String.trim(model)}
      _ -> nil
    end
  end

  defp model_change_from_message(_message), do: nil

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

  defp display_model(entry) when is_map(entry) do
    case Map.get(entry, :model_routing) do
      %{} = model_routing ->
        resolved = Map.get(model_routing, :resolved) || Map.get(model_routing, "resolved") || %{}
        Map.get(resolved, :model) || Map.get(resolved, "model") || Map.get(entry, :adapter)

      _ ->
        Map.get(entry, :adapter)
    end
  end

  defp provider_from_entry(entry) when is_map(entry) do
    display_model(entry)
    |> ModelUsage.provider_from_model()
  end

  defp archived_cost_or_log(entry) do
    case archived_cost(entry) do
      nil -> log_cost(entry)
      cost -> cost
    end
  end

  defp archived_cost(entry) do
    if is_map(entry) do
      cond do
        Map.has_key?(entry, :cost) -> normalize_explicit_cost(Map.get(entry, :cost))
        Map.has_key?(entry, "cost") -> normalize_explicit_cost(Map.get(entry, "cost"))
        true -> nil
      end
    else
      nil
    end
  end

  defp normalize_explicit_cost(cost) when is_number(cost), do: Float.round(cost / 1.0, 6)

  defp normalize_explicit_cost(cost) when is_binary(cost) do
    case Float.parse(cost) do
      {parsed, ""} -> Float.round(parsed, 6)
      _ -> nil
    end
  end

  defp normalize_explicit_cost(_cost), do: nil

  defp log_cost(entry) when is_map(entry) do
    entry
    |> Map.get(:event_log, [])
    |> Enum.reduce(0.0, fn log_entry, total -> total + token_cost(log_entry) end)
    |> normalize_cost()
  end

  defp token_cost(%{tokens: tokens}) when is_map(tokens), do: token_cost(tokens)
  defp token_cost(%{"tokens" => tokens}) when is_map(tokens), do: token_cost(tokens)

  defp token_cost(tokens) when is_map(tokens) do
    case Map.get(tokens, :cost) || Map.get(tokens, "cost") do
      value when is_number(value) -> value
      _ -> 0
    end
  end

  defp token_cost(_tokens), do: 0

  defp normalize_cost(cost) when is_number(cost) do
    rounded = Float.round(cost, 6)
    if rounded == 0.0, do: nil, else: rounded
  end

  defp normalize_cost(_cost), do: nil

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp guidance_responses_from_interrupt(interrupt) when is_map(interrupt) do
    Map.get(interrupt, :suggested_responses) || Map.get(interrupt, :options) || []
  end

  defp guidance_responses_from_interrupt(_interrupt), do: []

  defp state_mismatch?(paused_state, tracker_state) when is_binary(paused_state) and is_binary(tracker_state),
    do: paused_state != tracker_state

  defp state_mismatch?(_paused_state, _tracker_state), do: false

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
