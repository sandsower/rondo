defmodule Rondo.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Claude Code agent workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias Rondo.Agent.Adapter, as: AgentAdapter
  alias Rondo.AgentRunner
  alias Rondo.Config
  alias Rondo.Escalation
  alias Rondo.Interrupt
  alias Rondo.Linear.Issue
  alias Rondo.ReleaseLoop
  alias Rondo.RunLedger
  alias Rondo.SideEffectPolicy
  alias Rondo.StatusDashboard
  alias Rondo.Tracker
  alias Rondo.Workspace

  @dialyzer {:nowarn_function, handle_release_loop_dispatch: 7}
  @dialyzer {:nowarn_function, transition_issue_to_release_state: 2}
  @dialyzer {:nowarn_function, parse_repo_slug: 1}

  @timeseries_sample_interval_ms 10_000
  @continuation_retry_delay_ms 1_000
  @poll_retry_delay_ms 5_000
  @slot_wait_delay_ms 5_000
  @failure_retry_base_ms 10_000
  @event_log_max_entries 100
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @missing_issue_terminate_threshold 3
  @empty_claude_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      paused_interrupts: %{},
      claude_totals: nil,
      claude_rate_limits: nil,
      archived_runs: []
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    paused_interrupts = load_paused_interrupts()

    state = %State{
      poll_interval_ms: Config.poll_interval_ms(),
      max_concurrent_agents: Config.max_concurrent_agents(),
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      claimed: MapSet.new(Map.keys(paused_interrupts)),
      retry_attempts: %{},
      paused_interrupts: paused_interrupts,
      claude_totals: @empty_claude_totals,
      claude_rate_limits: nil,
      archived_runs: load_archived_runs()
    }

    Process.flag(:trap_exit, true)
    Rondo.TimeSeries.init()
    schedule_timeseries_sample()
    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def terminate(reason, %{running: running}) do
    running
    |> Map.values()
    |> Enum.each(fn running_entry ->
      try do
        terminate_run_ledger_on_shutdown(running_entry, reason)
        terminate_running_child(running_entry)
      rescue
        error ->
          Logger.error(
            "Shutdown cleanup failed #{running_entry_context(running_entry)} " <>
              "error=#{Exception.message(error)} stacktrace=#{inspect(__STACKTRACE__)}"
          )
      end
    end)

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp terminate_run_ledger_on_shutdown(%{ledger: %RunLedger{} = ledger} = running_entry, reason) do
    complete_run_ledger(ledger, :terminated, %{
      exit_reason: "orchestrator shutdown: #{inspect(reason)}",
      session_id: Map.get(running_entry, :session_id),
      turn_count: Map.get(running_entry, :turn_count, 0)
    })

    :ok
  end

  defp terminate_run_ledger_on_shutdown(_running_entry, _reason), do: :ok

  defp terminate_running_child(%{pid: pid}) when is_pid(pid) do
    terminate_task(pid)
  end

  defp terminate_running_child(_running_entry), do: :ok

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    Logger.debug("Orchestrator ignored bare :tick (no token)")
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        running_entry = refresh_running_entry_state(running_entry)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          cond do
            reason == :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state
              |> archive_running_entry(running_entry, reason)
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                delay_type: :continuation
              })

            action_policy_guidance_exit?(reason) ->
              Logger.warning("Agent task paused for issue_id=#{issue_id} session_id=#{session_id} reason=action_policy_guidance")
              pause_running_entry(state, issue_id, running_entry, reason)

            final_report_invalid_exit?(reason) ->
              Logger.warning("Agent task paused for issue_id=#{issue_id} session_id=#{session_id} reason=final_report_invalid")
              pause_running_entry(state, issue_id, running_entry, reason)

            pause_after_gate_failure?(running_entry, reason) ->
              Logger.warning("Agent task paused for issue_id=#{issue_id} session_id=#{session_id} reason=repeated_gate_failure")
              pause_running_entry(state, issue_id, running_entry, reason)

            model_routing_exhausted_exit?(reason) ->
              Logger.warning("Agent task paused for issue_id=#{issue_id} session_id=#{session_id} reason=model_routing_exhausted")
              pause_running_entry(state, issue_id, running_entry, reason)

            true ->
              handle_run_completion(state, issue_id, running_entry, reason, session_id)
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:claude_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_claude_update(running_entry, update)
        accounted_update = put_accounted_usage(update, token_delta)
        updated_running_entry = record_ledger_claude_update(updated_running_entry, accounted_update)

        state =
          state
          |> apply_claude_token_delta(token_delta)
          |> apply_claude_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:claude_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(:timeseries_sample, state) do
    schedule_timeseries_sample()

    snapshot = %{
      running: Map.values(state.running),
      retrying: Map.values(state.retry_attempts),
      claude_totals: state.claude_totals
    }

    Rondo.TimeSeries.record(snapshot)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_paused_interrupts()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, :missing_claude_command} ->
        Logger.error("Claude command missing in WORKFLOW.md")
        state

      {:error, {:invalid_workflow_config, _path, _errors} = reason} ->
        Logger.error(Config.format_validation_error(reason))
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from tracker: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_paused_interrupts(%State{paused_interrupts: paused_interrupts} = state)
       when map_size(paused_interrupts) == 0,
       do: state

  defp reconcile_paused_interrupts(%State{} = state) do
    paused_ids = Map.keys(state.paused_interrupts)

    case Tracker.fetch_issue_states_by_ids(paused_ids) do
      {:ok, issues} ->
        issues_by_id = Map.new(issues, &{&1.id, &1})

        Enum.reduce(state.paused_interrupts, state, fn {issue_id, paused_entry}, state_acc ->
          issue = Map.get(issues_by_id, issue_id)
          reconcile_paused_interrupt(state_acc, issue_id, paused_entry, issue)
        end)

      {:error, reason} ->
        Logger.debug("Failed to refresh paused issue states: #{inspect(reason)}; keeping paused claims")
        state
    end
  end

  defp reconcile_paused_interrupt(state, issue_id, paused_entry, nil) do
    mark_paused_entry_revalidated(state, issue_id, paused_entry, %{
      tracker_visibility: "missing",
      stale_reason: "issue_not_visible"
    })
  end

  defp reconcile_paused_interrupt(%State{} = state, issue_id, paused_entry, %Issue{} = issue) do
    terminal_states = terminal_state_set()
    active_states = active_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        release_stale_paused_interrupt(state, issue_id, paused_entry, "issue_terminal")

      !active_issue_state?(issue.state, active_states) ->
        release_stale_paused_interrupt(state, issue_id, paused_entry, "issue_not_active")

      action_policy_guidance_interrupt?(paused_entry) ->
        reconcile_action_policy_paused_interrupt(state, issue_id, paused_entry, issue)

      true ->
        mark_paused_entry_revalidated(state, issue_id, paused_entry, %{
          issue: issue,
          state: issue.state,
          tracker_visibility: "known",
          stale_reason: nil
        })
    end
  end

  defp reconcile_action_policy_paused_interrupt(state, issue_id, paused_entry, issue) do
    case revalidate_paused_side_effect(paused_entry) do
      {:ok, %{"decision" => "allow"}} ->
        release_stale_paused_interrupt(state, issue_id, paused_entry, "action_policy_now_allows")

      {:ok, envelope} ->
        paused_entry = put_in(paused_entry, [:interrupt, "policy"], envelope)

        mark_paused_entry_revalidated(state, issue_id, paused_entry, %{
          issue: issue,
          state: issue.state,
          tracker_visibility: "known",
          stale_reason: nil
        })

      {:error, reason} ->
        mark_paused_entry_revalidated(state, issue_id, paused_entry, %{
          issue: issue,
          state: issue.state,
          tracker_visibility: "known",
          stale_reason: "policy_revalidation_failed: #{inspect(reason)}"
        })
    end
  end

  defp action_policy_guidance_interrupt?(paused_entry) do
    get_in(paused_entry, [:interrupt, "reason"]) == "action_policy_guidance_required"
  end

  defp revalidate_paused_side_effect(paused_entry) do
    side_effect = get_in(paused_entry, [:interrupt, "blocked_side_effect"])
    action = map_value(side_effect, :action)
    classes = map_value(side_effect, :classes) || []

    if is_binary(action) and is_list(classes) do
      Rondo.ActionPolicy.evaluate(action, classes, workspace: Map.get(paused_entry, :workspace))
    else
      {:error, :invalid_paused_side_effect}
    end
  end

  defp release_stale_paused_interrupt(%State{} = state, issue_id, paused_entry, reason) do
    ledger = Map.get(paused_entry, :ledger)

    ledger =
      complete_run_ledger(ledger, :aborted, %{
        reason: "stale paused claim released: #{reason}",
        stale_reason: reason
      })

    _ledger = ledger

    Logger.info(
      "Released stale paused claim issue_id=#{issue_id} " <>
        "issue_identifier=#{Map.get(paused_entry, :identifier)} " <>
        "session_id=#{Map.get(paused_entry, :session_id) || "n/a"} reason=#{reason}"
    )

    %{
      state
      | paused_interrupts: Map.delete(state.paused_interrupts, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id)
    }
  end

  defp mark_paused_entry_revalidated(%State{} = state, issue_id, paused_entry, updates) do
    paused_entry =
      paused_entry
      |> Map.merge(updates)
      |> Map.put(:revalidated_at, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())

    %{state | paused_interrupts: Map.put(state.paused_interrupts, issue_id, paused_entry)}
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true, issue.state, :terminated)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, issue.state, :terminated)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, issue.state, :handoff)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        clear_missing_count(state_acc, issue_id)
      else
        missing_count = get_missing_count(state_acc, issue_id) + 1
        state_acc = set_missing_count(state_acc, issue_id, missing_count)

        handle_missing_running_issue(state_acc, issue_id, missing_count)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp handle_missing_running_issue(state, issue_id, missing_count)
       when missing_count >= @missing_issue_terminate_threshold do
    log_missing_running_issue(state, issue_id)

    state
    |> clear_missing_count(issue_id)
    |> terminate_running_issue(issue_id, false)
  end

  defp handle_missing_running_issue(state, issue_id, missing_count) do
    Logger.debug("Issue not visible during running-state refresh: issue_id=#{issue_id} missing_count=#{missing_count}/#{@missing_issue_terminate_threshold}")
    state
  end

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp get_missing_count(%State{running: running}, issue_id) do
    case Map.get(running, issue_id) do
      %{} = entry -> Map.get(entry, :missing_count, 0)
      _ -> 0
    end
  end

  defp set_missing_count(%State{running: running} = state, issue_id, count) do
    case Map.get(running, issue_id) do
      %{} = entry ->
        %{state | running: Map.put(running, issue_id, Map.put(entry, :missing_count, count))}

      _ ->
        state
    end
  end

  defp clear_missing_count(%State{running: running} = state, issue_id) do
    case Map.get(running, issue_id) do
      %{} = entry ->
        %{state | running: Map.put(running, issue_id, Map.delete(entry, :missing_count))}

      _ ->
        state
    end
  end

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, final_state \\ nil, reason \\ :terminated) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        running_entry = set_running_entry_final_state(running_entry, final_state)

        state = record_session_completion_totals(state, running_entry)
        state = archive_running_entry(state, running_entry, reason)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, Map.get(running_entry, :ledger))
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp set_running_entry_final_state(running_entry, nil), do: running_entry

  defp set_running_entry_final_state(running_entry, final_state) do
    update_in(running_entry, [:issue], fn
      %Issue{} = issue -> %{issue | state: final_state}
      other -> other
    end)
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.claude_stall_timeout_ms()

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without claude activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_claude_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(Rondo.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.tracker_terminal_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.tracker_active_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt) do
    recipient = self()
    attempt_metadata = attempt_metadata(attempt)
    {ledger, dispatch_payload} = create_run_ledger(issue, attempt)
    ledger = write_run_ledger_checkpoint(ledger, :dispatch, dispatch_payload)

    case transition_issue_to_in_progress(issue, ledger) do
      {:ok, issue, ledger} ->
        maybe_dispatch_release_loop(state, issue, attempt, attempt_metadata, recipient, ledger)

      {:paused, interrupt, ledger} ->
        pause_action_policy_guidance(state, issue, interrupt, ledger)

      {:blocked, reason, ledger} ->
        ledger = complete_run_ledger(ledger, :failed, %{phase: "action_policy", reason: inspect(reason)})
        _ledger = ledger

        Logger.warning("Skipping dispatch; action policy blocked #{issue_context(issue)} reason=#{inspect(reason)}")

        schedule_issue_retry(state, issue.id, nil, %{
          identifier: issue.identifier,
          error: "action policy blocked dispatch: #{inspect(reason)}"
        })
    end
  end

  defp maybe_dispatch_release_loop(%State{} = state, issue, attempt, attempt_metadata, recipient, ledger) do
    case ReleaseLoop.inspect(issue,
           ledger: ledger,
           workspace: expected_workspace_for_issue(issue),
           repo: tracker_repo()
         ) do
      {:ok, decision, ledger} ->
        handle_release_loop_dispatch(state, issue, attempt, attempt_metadata, recipient, ledger, decision)

      {:skip, :disabled, ledger} ->
        start_agent_for_issue(state, issue, attempt, attempt_metadata, recipient, ledger)

      {:skip, :missing_branch, ledger} ->
        start_agent_for_issue(state, issue, attempt, attempt_metadata, recipient, ledger)

      {:skip, :no_pr, ledger} ->
        start_agent_for_issue(state, issue, attempt, attempt_metadata, recipient, ledger)

      {:skip, {:risk_above_threshold, assessment}, ledger} ->
        handle_release_loop_manual_review(state, issue, ledger, assessment, :risk_above_threshold)

      {:skip, {:risk_gate_unavailable, reason}, ledger} ->
        handle_release_loop_manual_review(state, issue, ledger, %{reason: reason}, :risk_gate_unavailable)

      {:skip, _reason, ledger} ->
        start_agent_for_issue(state, issue, attempt, attempt_metadata, recipient, ledger)

      {:error, reason, ledger} ->
        Logger.warning("Release loop inspection failed #{issue_context(issue)} reason=#{inspect(reason)}; continuing normal dispatch")
        start_agent_for_issue(state, issue, attempt, attempt_metadata, recipient, ledger)
    end
  end

  defp handle_release_loop_dispatch(%State{} = state, %Issue{} = issue, attempt, attempt_metadata, recipient, ledger, %{action: :fix} = decision) do
    issue = transition_issue_to_release_state(issue, release_loop_rework_state())

    agent_opts = [
      operator_guidance: Map.get(decision, :guidance),
      model_routing_context: %{stage: :turn, skill: "review-response", phase: "review"}
    ]

    ledger = write_run_ledger_checkpoint(ledger, :release_loop_action_selected, %{action: "fix", feedback_count: length(Map.get(decision, :feedback_queue, []))})
    start_agent_for_issue(state, issue, attempt, attempt_metadata, recipient, ledger, agent_opts)
  end

  defp handle_release_loop_dispatch(%State{} = state, %Issue{} = issue, _attempt, _attempt_metadata, _recipient, ledger, %{action: :wait} = decision) do
    issue = transition_issue_to_release_state(issue, release_loop_review_state())
    ledger = write_run_ledger_checkpoint(ledger, :release_loop_action_selected, %{action: "wait", wait_interval_seconds: Map.get(decision, :wait_interval_seconds)})
    _ledger = complete_run_ledger(ledger, :completed, %{phase: "release_loop_wait", wait_interval_seconds: Map.get(decision, :wait_interval_seconds)})

    state =
      schedule_issue_retry(state, issue.id, nil, %{
        identifier: issue.identifier,
        delay_type: :release_loop_wait,
        error: "release loop waiting for PR checks or mergeability"
      })

    %{state | claimed: MapSet.put(state.claimed, issue.id)}
  end

  defp handle_release_loop_dispatch(
         %State{} = state,
         %Issue{} = issue,
         _attempt,
         _attempt_metadata,
         _recipient,
         ledger,
         %{action: :merge} = decision
       ) do
    issue = transition_issue_to_release_state(issue, release_loop_merge_state())

    case ReleaseLoop.execute_closeout(issue, decision,
           ledger: ledger,
           workspace: expected_workspace_for_issue(issue),
           repo: tracker_repo()
         ) do
      {:ok, _result, ledger} ->
        _ledger = complete_run_ledger(ledger, :completed, %{phase: "release_loop_closeout", action: "merge"})
        %{state | completed: MapSet.put(state.completed, issue.id)}

      {:skip, reason, ledger} ->
        _ledger = complete_run_ledger(ledger, :failed, %{phase: "release_loop_closeout", reason: inspect(reason)})

        state =
          schedule_issue_retry(state, issue.id, nil, %{
            identifier: issue.identifier,
            error: "release loop closeout skipped: #{inspect(reason)}"
          })

        %{state | claimed: MapSet.put(state.claimed, issue.id)}

      {:error, reason, ledger} ->
        _ledger = complete_run_ledger(ledger, :failed, %{phase: "release_loop_closeout", reason: inspect(reason)})

        state =
          schedule_issue_retry(state, issue.id, nil, %{
            identifier: issue.identifier,
            error: "release loop closeout failed: #{inspect(reason)}"
          })

        %{state | claimed: MapSet.put(state.claimed, issue.id)}
    end
  end

  defp handle_release_loop_dispatch(%State{} = state, issue, attempt, attempt_metadata, recipient, ledger, _decision) do
    start_agent_for_issue(state, issue, attempt, attempt_metadata, recipient, ledger)
  end

  defp handle_release_loop_manual_review(%State{} = state, %Issue{} = issue, ledger, assessment, reason) do
    issue = transition_issue_to_release_state(issue, release_loop_review_state())

    ledger =
      write_run_ledger_checkpoint(ledger, :release_loop_manual_review, %{
        reason: Atom.to_string(reason),
        risk_level: Map.get(assessment, :level),
        risk_threshold: Map.get(assessment, :threshold),
        risk_allowed: Map.get(assessment, :allowed),
        risk_source: Map.get(assessment, :source),
        risk_evidence: Map.get(assessment, :evidence)
      })

    _ledger =
      complete_run_ledger(ledger, :completed, %{
        phase: "release_loop_manual_review",
        reason: Atom.to_string(reason),
        risk_level: Map.get(assessment, :level),
        risk_threshold: Map.get(assessment, :threshold)
      })

    %{state | completed: MapSet.put(state.completed, issue.id)}
  end

  defp start_agent_for_issue(%State{} = state, issue, attempt, attempt_metadata, recipient, ledger, agent_opts \\ []) do
    merged_opts = Keyword.merge(escalation_agent_opts(attempt_metadata), agent_opts)

    case Task.Supervisor.start_child(Rondo.TaskSupervisor, fn ->
           base_opts = [
             attempt: normalize_retry_attempt(attempt),
             run_dir: run_ledger_dir(ledger),
             run_ledger: ledger
           ]

           AgentRunner.run(issue, recipient, Keyword.merge(base_opts, merged_opts))
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        ledger =
          write_run_ledger_checkpoint(ledger, :spawned, %{
            pid: inspect(pid),
            attempt: normalize_retry_attempt(attempt)
          })

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            session_id: nil,
            run_id: run_ledger_id(ledger),
            run_dir: run_ledger_dir(ledger),
            workspace: expected_workspace_for_issue(issue),
            ledger: ledger,
            run_ref: nil,
            last_claude_message: nil,
            last_claude_timestamp: nil,
            last_claude_event: nil,
            claude_input_tokens: 0,
            claude_output_tokens: 0,
            claude_total_tokens: 0,
            claude_last_reported_input_tokens: 0,
            claude_last_reported_output_tokens: 0,
            claude_last_reported_total_tokens: 0,
            claude_last_reported_cost: 0,
            claude_usage_accounting_ref: nil,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            retry_failure_reason: Keyword.get(attempt_metadata, :failure_reason),
            attempt_chain: Keyword.get(attempt_metadata, :attempt_chain, []),
            started_at: DateTime.utc_now(),
            latest_gate: nil,
            model_routing_context: Keyword.get(merged_opts, :model_routing_context),
            event_log: []
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        ledger = complete_run_ledger(ledger, :failed, %{phase: "spawn", reason: inspect(reason)})
        _ledger = ledger
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}"
        })
    end
  end

  defp escalation_agent_opts(metadata) do
    opts =
      case Keyword.get(metadata, :next_tier) do
        tier when is_binary(tier) ->
          [source_contract: %{"model_routing" => %{"tier" => tier, "mode" => "prefer"}}]

        _ ->
          []
      end

    opts =
      case Keyword.get(metadata, :evidence_prompt) do
        prompt when is_binary(prompt) -> Keyword.put(opts, :operator_guidance, prompt)
        _ -> opts
      end

    opts =
      if Keyword.get(metadata, :fresh_workspace, false) do
        Keyword.put(opts, :fresh_workspace, true)
      else
        opts
      end

    case Keyword.get(metadata, :max_turns) do
      n when is_integer(n) and n > 0 -> Keyword.put(opts, :max_turns, n)
      _ -> opts
    end
  end

  defp handle_run_completion(%State{} = state, issue_id, running_entry, reason, session_id) do
    has_ledger? = match?(%RunLedger{}, Map.get(running_entry, :ledger))
    escalation_enabled? = has_ledger? and Escalation.resolve_config(nil).enabled

    cond do
      reason == :normal ->
        handle_normal_completion(state, issue_id, running_entry, session_id, has_ledger?)

      not escalation_enabled? ->
        handle_non_escalation_exit(state, issue_id, running_entry, reason, session_id, has_ledger?)

      true ->
        Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; evaluating escalation policy")
        evaluate_escalation(state, issue_id, running_entry, reason)
    end
  end

  defp handle_normal_completion(%State{} = state, issue_id, running_entry, session_id, _has_ledger?) do
    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

    state
    |> archive_running_entry(running_entry, :normal)
    |> complete_issue(issue_id)
    |> schedule_issue_retry(issue_id, 1, %{
      identifier: running_entry.identifier,
      delay_type: :continuation
    })
  end

  defp handle_non_escalation_exit(%State{} = state, issue_id, running_entry, reason, session_id, has_ledger?) do
    cond do
      final_report_invalid_exit?(reason) ->
        Logger.warning("Agent task paused for issue_id=#{issue_id} session_id=#{session_id} reason=final_report_invalid")
        pause_running_entry(state, issue_id, running_entry, reason)

      pause_after_gate_failure?(running_entry, reason) ->
        Logger.warning("Agent task paused for issue_id=#{issue_id} session_id=#{session_id} reason=repeated_gate_failure")
        pause_running_entry(state, issue_id, running_entry, reason)

      true ->
        Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

        next_attempt = next_retry_attempt_from_running(running_entry)

        if has_ledger? do
          archive_running_entry(state, running_entry, reason)
        else
          state
        end
        |> schedule_issue_retry(issue_id, next_attempt, %{
          identifier: running_entry.identifier,
          error: "agent exited: #{inspect(reason)}",
          failure_reason: retry_failure_reason(running_entry, reason)
        })
    end
  end

  defp evaluate_escalation(%State{} = state, issue_id, running_entry, reason) do
    state = archive_running_entry(state, running_entry, reason)

    run_dir = Map.get(running_entry, :run_dir)
    attempt_chain = Map.get(running_entry, :attempt_chain, [])

    case load_run_manifest(run_dir) do
      {:ok, manifest} ->
        case Escalation.after_attempt(manifest, attempt_chain, nil) do
          {:done, _chain} ->
            complete_issue(state, issue_id)
            |> schedule_issue_retry(issue_id, 1, %{
              identifier: running_entry.identifier,
              delay_type: :continuation
            })

          {:pause, pause_reason, chain} ->
            pause_for_escalation(state, issue_id, running_entry, pause_reason, chain)

          {:escalate, next_tier, chain, prompt} ->
            schedule_issue_retry(state, issue_id, nil, %{
              identifier: running_entry.identifier,
              delay_type: :escalation,
              next_tier: next_tier,
              evidence_prompt: prompt,
              fresh_workspace: true,
              attempt_chain: chain
            })

          {:repair, chain, prompt} ->
            current_tier = chain |> List.last() |> Map.get(:tier)

            schedule_issue_retry(state, issue_id, nil, %{
              identifier: running_entry.identifier,
              delay_type: :repair,
              next_tier: current_tier,
              evidence_prompt: prompt,
              fresh_workspace: false,
              max_turns: 1,
              attempt_chain: chain
            })
        end

      {:error, load_reason} ->
        Logger.error("Escalation decision skipped for issue_id=#{issue_id}; could not load manifest: #{inspect(load_reason)}")

        schedule_issue_retry(state, issue_id, nil, %{
          identifier: running_entry.identifier,
          error: "escalation manifest load failed: #{inspect(load_reason)}"
        })
    end
  end

  defp load_run_manifest(nil), do: {:error, :missing_run_dir}

  defp load_run_manifest(run_dir) when is_binary(run_dir) do
    RunLedger.load_manifest(run_dir)
  end

  defp pause_for_escalation(state, issue_id, running_entry, reason, chain) do
    run_dir = Map.get(running_entry, :run_dir)

    ledger =
      case load_run_manifest(run_dir) do
        {:ok, manifest} ->
          manifest_path = Path.join(run_dir, "manifest.json")
          ledger = run_ledger_from_manifest(manifest, manifest_path)

          case RunLedger.record_attempt_chain(ledger, chain) do
            {:ok, ledger} -> ledger
            {:error, _} -> ledger
          end

        {:error, _} ->
          Map.get(running_entry, :ledger)
      end

    running_entry = Map.put(running_entry, :ledger, ledger)
    pause_running_entry(state, issue_id, running_entry, {:escalation_paused, reason, chain})
  end

  defp create_run_ledger(issue, attempt) do
    payload = %{
      issue_id: Map.get(issue, :id),
      issue_identifier: Map.get(issue, :identifier),
      attempt: normalize_retry_attempt(attempt)
    }

    case RunLedger.create_run(issue) do
      {:ok, ledger} ->
        {ledger, payload}

      {:error, reason} ->
        Logger.warning("Run ledger create failed for #{issue_context(issue)} reason=#{inspect(reason)}")
        {nil, payload}
    end
  end

  defp write_run_ledger_checkpoint(ledger, kind, payload, opts \\ [])
  defp write_run_ledger_checkpoint(nil, _kind, _payload, _opts), do: nil

  defp write_run_ledger_checkpoint(%RunLedger{} = ledger, kind, payload, opts) do
    case RunLedger.write_checkpoint(ledger, kind, payload, opts) do
      {:ok, ledger} ->
        ledger

      {:error, reason} ->
        Logger.warning("Run ledger checkpoint failed #{ledger_context(ledger)} kind=#{kind} reason=#{inspect(reason)}")
        ledger
    end
  end

  defp finalize_run_ledger_artifacts(nil, _status, _final_report), do: nil

  defp finalize_run_ledger_artifacts(%RunLedger{} = ledger, :completed, final_report) do
    ledger
    |> capture_run_ledger_patch()
    |> record_run_ledger_final_report(final_report)
  end

  defp finalize_run_ledger_artifacts(ledger, _status, _final_report), do: ledger

  defp capture_run_ledger_patch(%RunLedger{} = ledger) do
    case Rondo.PatchArtifact.capture(ledger) do
      {:ok, ledger, status} ->
        Logger.info("Run ledger patch artifact capture #{ledger_context(ledger)} status=#{status}")
        ledger

      {:error, reason} ->
        Logger.warning("Run ledger patch artifact capture failed #{ledger_context(ledger)} reason=#{inspect(reason)}")
        ledger
    end
  end

  defp record_run_ledger_final_report(%RunLedger{} = ledger, final_report) do
    final_report = final_report || get_in(ledger.manifest, ["agent", "final_report"])

    case RunLedger.record_final_report(ledger, final_report) do
      {:ok, ledger, status} ->
        Logger.info("Run ledger final report validation #{ledger_context(ledger)} status=#{status}")
        ledger

      {:error, reason} ->
        Logger.warning("Run ledger final report record failed #{ledger_context(ledger)} reason=#{inspect(reason)}")
        ledger
    end
  end

  defp complete_run_ledger(nil, _status, _payload), do: nil

  defp complete_run_ledger(%RunLedger{} = ledger, status, payload) do
    case RunLedger.complete_run(ledger, status, payload) do
      {:ok, ledger} ->
        ledger

      {:error, reason} ->
        Logger.warning("Run ledger completion failed #{ledger_context(ledger)} status=#{status} reason=#{inspect(reason)}")
        ledger
    end
  end

  defp pause_run_ledger(nil, _interrupt, _session_id), do: nil

  defp pause_run_ledger(%RunLedger{} = ledger, interrupt, session_id) do
    case RunLedger.pause_run(ledger, interrupt) do
      {:ok, ledger} ->
        ledger

      {:error, reason} ->
        Logger.warning("Run ledger pause failed #{ledger_context(ledger, session_id)} reason=#{inspect(reason)}")
        ledger
    end
  end

  defp link_run_ledger_archive(nil, _archive_path), do: nil

  defp link_run_ledger_archive(%RunLedger{} = ledger, archive_path) when not is_binary(archive_path),
    do: ledger

  defp link_run_ledger_archive(%RunLedger{} = ledger, archive_path) do
    case RunLedger.link_archive(ledger, archive_path) do
      {:ok, ledger} ->
        ledger

      {:error, reason} ->
        Logger.warning("Run ledger archive link failed #{ledger_context(ledger)} reason=#{inspect(reason)}")
        ledger
    end
  end

  defp link_run_ledger_gate_artifacts(%RunLedger{} = ledger, %{event: event, raw: raw})
       when event in [:gates_completed, :gates_reused] and is_map(raw) do
    artifacts = gate_artifacts(raw)

    case RunLedger.link_artifacts(ledger, artifacts) do
      {:ok, ledger} ->
        ledger

      {:error, reason} ->
        Logger.warning("Run ledger gate artifact link failed #{ledger_context(ledger)} reason=#{inspect(reason)}")
        ledger
    end
  end

  defp link_run_ledger_gate_artifacts(ledger, _update), do: ledger

  defp gate_artifacts(raw) when is_map(raw) do
    results_artifact = artifact_from_path("gate_results", map_value(raw, :results_path))
    state_artifact = artifact_from_path("gate_state", map_value(raw, :state_path))

    result_artifacts =
      raw
      |> map_value(:results)
      |> case do
        results when is_list(results) -> Enum.flat_map(results, &gate_result_artifacts/1)
        _ -> []
      end

    [results_artifact, state_artifact | result_artifacts]
    |> Enum.reject(&is_nil/1)
  end

  defp gate_result_artifacts(result) when is_map(result) do
    name = map_value(result, :name) || "gate"

    [
      artifact_from_path("gate_stdout", map_value(result, :stdout_path), name),
      artifact_from_path("gate_stderr", map_value(result, :stderr_path), name)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp gate_result_artifacts(_result), do: []

  defp pause_after_gate_failure?(running_entry, reason) do
    previous_failure = Map.get(running_entry, :retry_failure_reason)
    previous_failure == :gate_failed and gate_failure_reason?(reason) and failed_gate?(Map.get(running_entry, :latest_gate))
  end

  defp action_policy_guidance_exit?({:action_policy_guidance_required, interrupt}) when is_map(interrupt), do: true
  defp action_policy_guidance_exit?(_reason), do: false

  defp final_report_invalid_exit?({:final_report_invalid, interrupt}) when is_map(interrupt), do: true
  defp final_report_invalid_exit?(_reason), do: false

  defp model_routing_exhausted_exit?({:model_routing_exhausted, interrupt}) when is_map(interrupt), do: true
  defp model_routing_exhausted_exit?(_reason), do: false

  defp retry_failure_reason(running_entry, reason) do
    if gate_failure_reason?(reason) and failed_gate?(Map.get(running_entry, :latest_gate)), do: :gate_failed
  end

  defp gate_failure_reason?(reason), do: reason |> inspect() |> String.contains?("gate_failed")

  defp failed_gate?(%{status: status}) when status in [:pass, "pass", nil], do: false
  defp failed_gate?(%{status: _status}), do: true
  defp failed_gate?(_gate), do: false

  defp pause_action_policy_guidance(%State{} = state, %Issue{} = issue, interrupt, ledger) when is_map(interrupt) do
    ledger = pause_run_ledger(ledger, interrupt, nil)
    paused_entry = paused_entry_from_issue(issue, interrupt, ledger)

    Logger.warning(
      "Paused run for action-policy guidance #{issue_context(issue)} " <>
        "run_dir=#{Map.get(paused_entry, :run_dir) || "n/a"} question=#{interrupt["question"]}"
    )

    %{
      state
      | paused_interrupts: Map.put(state.paused_interrupts, issue.id, paused_entry),
        claimed: MapSet.put(state.claimed, issue.id),
        retry_attempts: Map.delete(state.retry_attempts, issue.id)
    }
  end

  defp pause_running_entry(state, issue_id, running_entry, reason) do
    interrupt = pause_interrupt_for_reason(running_entry, reason)
    ledger = pause_run_ledger(Map.get(running_entry, :ledger), interrupt, Map.get(running_entry, :session_id))
    paused_entry = paused_entry_from_running(issue_id, running_entry, interrupt, ledger)

    Logger.warning(
      "Paused run for issue_id=#{issue_id} issue_identifier=#{Map.get(paused_entry, :identifier)} " <>
        "run_dir=#{Map.get(paused_entry, :run_dir) || "n/a"} question=#{interrupt["question"]}"
    )

    %{
      state
      | paused_interrupts: Map.put(state.paused_interrupts, issue_id, paused_entry),
        claimed: MapSet.put(state.claimed, issue_id)
    }
  end

  defp pause_interrupt_for_reason(_running_entry, {:action_policy_guidance_required, interrupt}) when is_map(interrupt), do: interrupt
  defp pause_interrupt_for_reason(_running_entry, {:final_report_invalid, interrupt}) when is_map(interrupt), do: interrupt
  defp pause_interrupt_for_reason(running_entry, {:escalation_paused, reason, chain}) do
    Interrupt.escalation_paused(
      Map.merge(interrupt_context(running_entry), %{
        reason: reason,
        attempt_chain: chain
      })
    )
  end

  defp pause_interrupt_for_reason(_running_entry, {:model_routing_exhausted, interrupt}) when is_map(interrupt), do: interrupt
  defp pause_interrupt_for_reason(running_entry, _reason), do: Interrupt.repeated_gate_failure(interrupt_context(running_entry))

  defp interrupt_context(running_entry) do
    %{
      issue: Map.get(running_entry, :issue),
      gate: gate_summary_for_interrupt(running_entry),
      run_id: Map.get(running_entry, :run_id),
      run_dir: Map.get(running_entry, :run_dir),
      workspace: running_entry_workspace(running_entry),
      session_id: Map.get(running_entry, :session_id),
      run_ref: running_entry_run_ref(running_entry),
      retry_attempt: Map.get(running_entry, :retry_attempt),
      model_routing_context: Map.get(running_entry, :model_routing_context)
    }
  end

  defp gate_summary_for_interrupt(%{last_claude_message: %{event: :gates_completed, message: message}}) when is_map(message), do: message
  defp gate_summary_for_interrupt(%{last_claude_message: %{message: message}}) when is_map(message), do: message
  defp gate_summary_for_interrupt(running_entry), do: Map.get(running_entry, :latest_gate) || %{}

  defp paused_entry_from_running(issue_id, running_entry, interrupt, ledger) do
    issue = Map.get(running_entry, :issue) || %Issue{id: issue_id, identifier: Map.get(running_entry, :identifier)}
    ledger = ledger || Map.get(running_entry, :ledger)

    %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier),
      issue: issue,
      state: Map.get(issue, :state),
      session_id: Map.get(running_entry, :session_id),
      run_id: run_ledger_id(ledger) || Map.get(running_entry, :run_id),
      run_dir: run_ledger_dir(ledger) || Map.get(running_entry, :run_dir),
      workspace: running_entry_workspace(running_entry),
      paused_at: interrupt["created_at"],
      retry_attempt: Map.get(running_entry, :retry_attempt),
      turn_count: Map.get(running_entry, :turn_count, 0),
      continuation_count: get_in(interrupt, ["final_report", "continuation_count"]) || 0,
      latest_gate: Map.get(running_entry, :latest_gate),
      model_routing_context: Map.get(running_entry, :model_routing_context) || get_in(interrupt, ["resume", "model_routing_context"]),
      interrupt: interrupt,
      tracker_visibility: "known",
      ledger: ledger
    }
  end

  defp apply_guidance_response(state, issue_id, paused_entry, "approve_once") do
    interrupt = Map.get(paused_entry, :interrupt, %{})
    side_effect_id = get_in(interrupt, ["resume", "side_effect_id"])

    if is_binary(side_effect_id) and String.starts_with?(side_effect_id, "tracker-transition:") do
      approve_tracker_transition_guidance(state, issue_id, paused_entry)
    else
      {{:error, :unsupported_guidance_response}, state}
    end
  end

  defp apply_guidance_response(state, issue_id, paused_entry, guidance) when guidance in ["abort_run", "abort"] do
    ledger = Map.get(paused_entry, :ledger)
    ledger = complete_run_ledger(ledger, :aborted, %{reason: "operator guidance abort"})
    _ledger = ledger

    state = %{
      state
      | paused_interrupts: Map.delete(state.paused_interrupts, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id)
    }

    {{:ok, %{status: :aborted, issue_id: issue_id}}, state}
  end

  defp apply_guidance_response(state, _issue_id, _paused_entry, ""), do: {{:error, :empty_guidance}, state}

  defp apply_guidance_response(state, issue_id, paused_entry, guidance),
    do: resume_with_operator_guidance(state, issue_id, paused_entry, guidance)

  defp resume_with_operator_guidance(state, issue_id, paused_entry, guidance) do
    ledger = Map.get(paused_entry, :ledger)

    with {:ok, issue} <- paused_entry_issue(issue_id, paused_entry),
         {:ok, run_ref} <- paused_entry_run_ref(paused_entry) do
      ledger = write_run_ledger_checkpoint(ledger, :guidance_submitted, %{response: "operator_guidance", guidance: guidance})

      state = %{
        state
        | paused_interrupts: Map.delete(state.paused_interrupts, issue_id),
          claimed: MapSet.delete(state.claimed, issue_id)
      }

      state =
        start_agent_for_issue(state, issue, Map.get(paused_entry, :retry_attempt, 0), [], self(), ledger,
          initial_run_ref: run_ref,
          operator_guidance: guidance,
          model_routing_context: Map.get(paused_entry, :model_routing_context)
        )

      {{:ok, %{status: :resumed, issue_id: issue_id}}, state}
    else
      {:error, reason} ->
        {{:error, {:guidance_resume_failed, reason}}, state}
    end
  end

  defp paused_entry_issue(issue_id, paused_entry) do
    case Map.get(paused_entry, :issue) do
      %Issue{} = issue -> {:ok, issue}
      issue when is_map(issue) -> {:ok, issue_from_manifest(Map.new(issue, fn {key, value} -> {to_string(key), value} end))}
      _other -> {:ok, %Issue{id: issue_id, identifier: Map.get(paused_entry, :identifier), state: Map.get(paused_entry, :state)}}
    end
  end

  defp paused_entry_run_ref(paused_entry) do
    interrupt = Map.get(paused_entry, :interrupt, %{}) || %{}
    ledger = Map.get(paused_entry, :ledger)

    [
      Map.get(paused_entry, :run_ref),
      get_in(interrupt, ["resume", "run_ref"]),
      get_in(interrupt, [:resume, :run_ref]),
      get_in(ledger_manifest(ledger), ["agent", "run_ref"])
    ]
    |> Enum.find(& &1)
    |> case do
      nil -> run_ref_from_session(paused_entry, interrupt)
      run_ref -> normalize_run_ref(run_ref)
    end
  end

  defp ledger_manifest(%RunLedger{manifest: manifest}) when is_map(manifest), do: manifest
  defp ledger_manifest(_ledger), do: %{}

  defp run_ref_from_session(paused_entry, interrupt) do
    session_id = Map.get(paused_entry, :session_id) || get_in(interrupt, ["resume", "session_id"]) || get_in(interrupt, [:resume, :session_id])

    if is_binary(session_id) and String.trim(session_id) != "" do
      {:ok, AgentAdapter.run_ref(Config.agent_adapter(), session_id, "session_id", true)}
    else
      {:error, :missing_resume_ref}
    end
  end

  defp normalize_run_ref(run_ref) when is_map(run_ref) do
    provider_ref = map_value(run_ref, :provider_ref)
    provider_ref_kind = map_value(run_ref, :provider_ref_kind)
    resumable? = Map.get(run_ref, :resumable?, Map.get(run_ref, "resumable?"))

    cond do
      !is_binary(provider_ref) or String.trim(provider_ref) == "" ->
        {:error, :invalid_resume_ref}

      resumable? == false ->
        {:error, :resume_ref_not_resumable}

      true ->
        {:ok,
         AgentAdapter.run_ref(
           map_value(run_ref, :adapter) || Config.agent_adapter(),
           provider_ref,
           provider_ref_kind,
           true
         )}
    end
  end

  defp normalize_run_ref(_run_ref), do: {:error, :invalid_resume_ref}

  defp approve_tracker_transition_guidance(state, issue_id, paused_entry) do
    ledger = Map.get(paused_entry, :ledger)

    with {:ok, issue} <- revalidate_tracker_transition_guidance(issue_id, paused_entry),
         :ok <- Tracker.update_issue_state(issue_id, "In Progress") do
      ledger = write_run_ledger_checkpoint(ledger, :guidance_submitted, %{response: "approve_once", side_effect: "tracker.issue.transition"})
      issue = %{issue | state: "In Progress"}

      state = %{
        state
        | paused_interrupts: Map.delete(state.paused_interrupts, issue_id),
          claimed: MapSet.delete(state.claimed, issue_id)
      }

      state = start_agent_for_issue(state, issue, Map.get(paused_entry, :retry_attempt, 0), [], self(), ledger)
      {{:ok, %{status: :resumed, issue_id: issue_id}}, state}
    else
      {:error, reason} ->
        {{:error, {:guidance_side_effect_failed, reason}}, state}
    end
  end

  defp revalidate_tracker_transition_guidance(issue_id, paused_entry) do
    paused_identifier = Map.get(paused_entry, :identifier)
    terminal_states = terminal_state_set()

    with {:ok, [%Issue{} = issue | _]} <- Tracker.fetch_issue_states_by_ids([issue_id]),
         :ok <- ensure_guidance_issue_matches(issue, paused_identifier),
         :ok <- ensure_guidance_issue_still_todo(issue),
         true <- retry_candidate_issue?(issue, terminal_states) do
      {:ok, issue}
    else
      {:ok, []} -> {:error, :guidance_issue_not_visible}
      false -> {:error, :guidance_issue_not_dispatchable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_guidance_issue_matches(%Issue{identifier: identifier}, identifier), do: :ok
  defp ensure_guidance_issue_matches(%Issue{}, nil), do: :ok
  defp ensure_guidance_issue_matches(%Issue{}, _identifier), do: {:error, :guidance_issue_changed}

  defp ensure_guidance_issue_still_todo(%Issue{state: state}) do
    if normalize_issue_state(state) == "todo", do: :ok, else: {:error, :guidance_issue_not_todo}
  end

  defp paused_entry_from_issue(%Issue{} = issue, interrupt, ledger) do
    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      state: issue.state,
      session_id: nil,
      run_id: run_ledger_id(ledger),
      run_dir: run_ledger_dir(ledger),
      workspace: expected_workspace_for_issue(issue),
      paused_at: interrupt["created_at"],
      retry_attempt: 0,
      turn_count: 0,
      continuation_count: 0,
      latest_gate: nil,
      model_routing_context: get_in(interrupt, ["resume", "model_routing_context"]),
      interrupt: interrupt,
      tracker_visibility: "known",
      event_log: [],
      ledger: ledger
    }
  end

  defp running_entry_workspace(%{workspace: workspace}) when is_binary(workspace), do: workspace

  defp running_entry_workspace(%{ledger: %RunLedger{manifest: %{"repo" => %{"workspace" => workspace}}}}) when is_binary(workspace),
    do: workspace

  defp running_entry_workspace(%{issue: %Issue{} = issue}), do: expected_workspace_for_issue(issue)
  defp running_entry_workspace(%{identifier: identifier}) when is_binary(identifier), do: Path.join(Config.workspace_root(), identifier)
  defp running_entry_workspace(_running_entry), do: nil

  defp running_entry_run_ref(%{run_ref: run_ref}) when not is_nil(run_ref), do: run_ref
  defp running_entry_run_ref(%{ledger: %RunLedger{manifest: %{"agent" => %{"run_ref" => run_ref}}}}), do: run_ref
  defp running_entry_run_ref(_running_entry), do: nil

  defp expected_workspace_for_issue(%Issue{identifier: identifier}) when is_binary(identifier), do: Path.join(Config.workspace_root(), identifier)
  defp expected_workspace_for_issue(_issue), do: nil

  defp artifact_from_path(_kind, nil), do: nil
  defp artifact_from_path(kind, path) when is_binary(path), do: %{"kind" => kind, "path" => path}

  defp artifact_from_path(kind, path, name) when is_binary(path),
    do: %{"kind" => kind, "path" => path, "name" => to_string(name)}

  defp artifact_from_path(_kind, _path, _name), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp run_ledger_id(%RunLedger{run_id: run_id}), do: run_id
  defp run_ledger_id(_ledger), do: nil

  defp run_ledger_dir(%RunLedger{run_dir: run_dir}), do: run_dir
  defp run_ledger_dir(_ledger), do: nil

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            failure_reason: Map.get(metadata, :failure_reason),
            delay_type: Map.get(metadata, :delay_type),
            next_tier: Map.get(metadata, :next_tier),
            evidence_prompt: Map.get(metadata, :evidence_prompt),
            fresh_workspace: Map.get(metadata, :fresh_workspace),
            max_turns: Map.get(metadata, :max_turns),
            attempt_chain: Map.get(metadata, :attempt_chain)
          })
    }
  end

  @retry_metadata_fields [
    :identifier,
    :error,
    :failure_reason,
    :delay_type,
    :next_tier,
    :evidence_prompt,
    :fresh_workspace,
    :max_turns,
    :attempt_chain
  ]

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = extract_retry_metadata(retry_entry)

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp extract_retry_metadata(retry_entry) do
    @retry_metadata_fields
    |> Enum.reduce(%{}, fn field, acc ->
      case Map.fetch(retry_entry, field) do
        {:ok, value} when not is_nil(value) -> Map.put(acc, field, value)
        _ -> acc
      end
    end)
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}", delay_type: :poll_retry})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, Map.get(metadata, :ledger))
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata, terminal_states)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, ledger \\ nil)

  defp cleanup_issue_workspace(identifier, ledger) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, ledger: ledger)
  end

  defp cleanup_issue_workspace(_identifier, _ledger), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.tracker_terminal_states()) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata, terminal_states) do
    if retry_candidate_issue?(issue, terminal_states) and
         dispatch_slots_available?(issue, state) do
      {:noreply, dispatch_issue(state, issue, {attempt, metadata})}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots",
           delay_type: :slot_wait
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(1, %{delay_type: :continuation}), do: @continuation_retry_delay_ms
  defp retry_delay(_attempt, %{delay_type: :escalation}), do: 0
  defp retry_delay(_attempt, %{delay_type: :repair}), do: 0
  defp retry_delay(_attempt, %{delay_type: :poll_retry}), do: @poll_retry_delay_ms
  defp retry_delay(_attempt, %{delay_type: :slot_wait}), do: @slot_wait_delay_ms

  defp retry_delay(_attempt, %{delay_type: :release_loop_wait}),
    do: Config.release_loop_wait_interval_seconds() * 1_000

  defp retry_delay(attempt, _metadata) when is_integer(attempt) and attempt > 0,
    do: failure_retry_delay(attempt)

  defp retry_delay(_attempt, _metadata), do: failure_retry_delay(1)

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.max_retry_backoff_ms())
  end

  defp normalize_retry_attempt({attempt, _metadata}), do: normalize_retry_attempt(attempt)
  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp attempt_metadata({_attempt, metadata}) when is_map(metadata), do: Map.to_list(metadata)
  defp attempt_metadata(_attempt), do: []

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp running_entry_context(running_entry) do
    issue = Map.get(running_entry, :issue) || %{}
    issue_id = Map.get(issue, :id) || Map.get(running_entry, :issue_id) || "n/a"
    issue_identifier = Map.get(issue, :identifier) || Map.get(running_entry, :identifier) || "n/a"
    session_id = Map.get(running_entry, :session_id) || "n/a"

    "issue_id=#{issue_id} issue_identifier=#{issue_identifier} session_id=#{session_id}"
  end

  defp ledger_context(%RunLedger{} = ledger, session_id_override \\ nil) do
    issue = Map.get(ledger.manifest, "issue") || %{}
    agent = Map.get(ledger.manifest, "agent") || %{}

    issue_id = Map.get(issue, "id") || "n/a"
    issue_identifier = Map.get(issue, "identifier") || "n/a"
    session_id = session_id_override || Map.get(agent, "session_id") || "n/a"

    "run_id=#{ledger.run_id} issue_id=#{issue_id} issue_identifier=#{issue_identifier} session_id=#{session_id}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.max_concurrent_agents()) - map_size(state.running),
      0
    )
  end

  defp paused_interrupt_lookup(%State{paused_interrupts: paused_interrupts}, issue_ref) when is_binary(issue_ref) do
    Map.get(paused_interrupts, issue_ref)
    |> case do
      nil ->
        Enum.find(paused_interrupts, fn
          {_issue_id, paused_entry} -> Map.get(paused_entry, :identifier) == issue_ref
        end)

      paused_entry ->
        {issue_ref, paused_entry}
    end
  end

  defp paused_interrupt_lookup(_state, _issue_ref), do: nil

  defp paused_blocked_dispatch_reason(_metadata) do
    "paused_claim"
  end

  @spec submit_guidance(String.t(), String.t()) :: {:ok, map()} | {:error, term()} | :unavailable
  def submit_guidance(issue_id, guidance) do
    submit_guidance(__MODULE__, issue_id, guidance)
  end

  @spec submit_guidance(GenServer.server(), String.t(), String.t()) :: {:ok, map()} | {:error, term()} | :unavailable
  def submit_guidance(server, issue_id, guidance) when is_binary(issue_id) and is_binary(guidance) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, {:submit_guidance, issue_id, guidance})
        catch
          :exit, _reason -> :unavailable
        end

      _other ->
        :unavailable
    end
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :request_refresh)
        catch
          :exit, _reason -> :unavailable
        end

      _other ->
        :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :snapshot, timeout)
        catch
          :exit, {:timeout, _} -> :timeout
          :exit, _ -> :unavailable
        end

      _other ->
        :unavailable
    end
  end

  @impl true
  def handle_call({:submit_guidance, issue_ref, guidance}, _from, state) do
    case paused_interrupt_lookup(state, issue_ref) do
      nil ->
        {:reply, {:error, :guidance_interrupt_not_found}, state}

      {issue_id, paused_entry} ->
        {reply, state} = apply_guidance_response(state, issue_id, paused_entry, String.trim(guidance))
        notify_dashboard()
        {:reply, reply, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          session_id: metadata.session_id,
          run_id: Map.get(metadata, :run_id),
          run_dir: Map.get(metadata, :run_dir),
          claude_input_tokens: metadata.claude_input_tokens,
          claude_output_tokens: metadata.claude_output_tokens,
          claude_total_tokens: metadata.claude_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          continuation_count: max(Map.get(metadata, :turn_count, 0) - 1, 0),
          started_at: metadata.started_at,
          last_claude_timestamp: metadata.last_claude_timestamp,
          last_claude_message: metadata.last_claude_message,
          last_claude_event: metadata.last_claude_event,
          latest_gate: Map.get(metadata, :latest_gate),
          model_routing: Map.get(metadata, :model_routing),
          adapter: Map.get(metadata, :adapter),
          model_fallback: Map.get(metadata, :model_fallback),
          runtime_seconds: running_seconds(metadata.started_at, now),
          event_log: Map.get(metadata, :event_log, [])
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error)
        }
      end)

    paused =
      state.paused_interrupts
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          state: Map.get(metadata, :state),
          session_id: Map.get(metadata, :session_id),
          run_id: Map.get(metadata, :run_id),
          run_dir: Map.get(metadata, :run_dir),
          workspace: Map.get(metadata, :workspace),
          paused_at: Map.get(metadata, :paused_at),
          retry_attempt: Map.get(metadata, :retry_attempt),
          turn_count: Map.get(metadata, :turn_count, 0),
          continuation_count: Map.get(metadata, :continuation_count, max(Map.get(metadata, :turn_count, 0) - 1, 0)),
          latest_gate: Map.get(metadata, :latest_gate),
          model_routing: Map.get(metadata, :model_routing),
          adapter: Map.get(metadata, :adapter),
          model_fallback: Map.get(metadata, :model_fallback),
          interrupt: Map.get(metadata, :interrupt, %{}),
          final_report_status: get_in(metadata, [:interrupt, "final_report", "status"]),
          final_report_classification: get_in(metadata, [:interrupt, "classification"]),
          reported_next_state: get_in(metadata, [:interrupt, "final_report", "reported_next_state"]),
          tracker_visibility: Map.get(metadata, :tracker_visibility, "unknown"),
          blocks_dispatch: MapSet.member?(state.claimed, issue_id),
          blocked_dispatch_reason: paused_blocked_dispatch_reason(metadata),
          stale_reason: Map.get(metadata, :stale_reason),
          revalidated_at: Map.get(metadata, :revalidated_at),
          event_log: Map.get(metadata, :event_log, [])
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       paused: paused,
       archived: Map.get(state, :archived_runs, []),
       claude_totals: state.claude_totals,
       rate_limits: Map.get(state, :claude_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_claude_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    claude_input_tokens = Map.get(running_entry, :claude_input_tokens, 0)
    claude_output_tokens = Map.get(running_entry, :claude_output_tokens, 0)
    claude_total_tokens = Map.get(running_entry, :claude_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    message = extract_event_summary(event, update)
    refined_event = refine_event_label(event, message, update)

    event_log =
      if loggable_event?(refined_event, message) do
        log_entry = %{at: timestamp, event: refined_event, message: message, tokens: token_delta}

        running_entry
        |> Map.get(:event_log, [])
        |> append_to_event_log(log_entry, @event_log_max_entries)
      else
        Map.get(running_entry, :event_log, [])
      end

    {
      Map.merge(running_entry, %{
        adapter: adapter_for_update(Map.get(running_entry, :adapter), update),
        last_claude_timestamp: timestamp,
        last_claude_message: summarize_claude_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        run_ref: run_ref_for_update(Map.get(running_entry, :run_ref), update),
        final_report: final_report_for_update(Map.get(running_entry, :final_report), update),
        model_routing: model_routing_for_update(Map.get(running_entry, :model_routing), update),
        last_claude_event: event,
        claude_input_tokens: claude_input_tokens + token_delta.input_tokens,
        claude_output_tokens: claude_output_tokens + token_delta.output_tokens,
        claude_total_tokens: claude_total_tokens + token_delta.total_tokens,
        claude_last_reported_input_tokens: Map.get(token_delta, :input_reported, 0),
        claude_last_reported_output_tokens: Map.get(token_delta, :output_reported, 0),
        claude_last_reported_total_tokens: Map.get(token_delta, :total_reported, 0),
        claude_last_reported_cost: Map.get(token_delta, :cost_reported) || 0,
        claude_usage_accounting_ref: usage_accounting_ref(update) || Map.get(running_entry, :claude_usage_accounting_ref),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        latest_gate: latest_gate_for_update(running_entry, update),
        model_routing: model_routing_for_update(Map.get(running_entry, :model_routing), update),
        model_fallback: model_fallback_for_update(Map.get(running_entry, :model_fallback), update),
        event_log: event_log
      }),
      token_delta
    }
  end

  defp record_ledger_claude_update(%{ledger: %RunLedger{} = ledger} = running_entry, update) do
    case RunLedger.append_agent_event(ledger, update) do
      :ok ->
        :ok

      {:error, reason} ->
        session_id = Map.get(update, :session_id, Map.get(update, "session_id"))
        Logger.warning("Run ledger agent event append failed #{ledger_context(ledger, session_id)} reason=#{inspect(reason)}")
    end

    ledger = update_run_ledger_agent_metadata(ledger, update)

    ledger =
      case RunLedger.checkpoint_kind_for_agent_update(update) do
        nil ->
          ledger

        kind ->
          write_run_ledger_checkpoint(
            ledger,
            kind,
            RunLedger.checkpoint_payload_for_agent_update(update),
            source: RunLedger.checkpoint_source_for_agent_update(update)
          )
      end

    ledger = link_run_ledger_gate_artifacts(ledger, update)

    Map.merge(running_entry, %{ledger: ledger, run_id: run_ledger_id(ledger), run_dir: run_ledger_dir(ledger)})
  end

  defp record_ledger_claude_update(running_entry, _update), do: running_entry

  defp update_run_ledger_agent_metadata(%RunLedger{} = ledger, update) do
    metadata = RunLedger.agent_metadata_for_agent_update(update)

    case RunLedger.update_agent_metadata(ledger, metadata) do
      {:ok, ledger} ->
        ledger

      {:error, reason} ->
        Logger.warning("Run ledger agent metadata update failed #{ledger_context(ledger)} reason=#{inspect(reason)}")
        ledger
    end
  end

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp run_ref_for_update(_existing, %{run_ref: run_ref}) when not is_nil(run_ref), do: run_ref
  defp run_ref_for_update(_existing, %{"run_ref" => run_ref}) when not is_nil(run_ref), do: run_ref
  defp run_ref_for_update(existing, _update), do: existing

  defp adapter_for_update(_existing, %{adapter: adapter}) when is_binary(adapter), do: adapter
  defp adapter_for_update(_existing, %{"adapter" => adapter}) when is_binary(adapter), do: adapter
  defp adapter_for_update(existing, _update), do: existing

  defp model_routing_for_update(_existing, %{model_routing: routing}) when is_map(routing) and map_size(routing) > 0,
    do: routing

  defp model_routing_for_update(_existing, %{"model_routing" => routing}) when is_map(routing) and map_size(routing) > 0,
    do: routing

  defp model_routing_for_update(existing, _update), do: existing

  defp final_report_for_update(existing, update) do
    case Map.get(update, :final_report) || Map.get(update, "final_report") do
      nil -> existing
      final_report -> final_report
    end
  end

  defp latest_gate_for_update(_running_entry, %{event: event, raw: raw})
       when event in [:gates_completed, :gates_reused] and is_map(raw) do
    %{
      status: map_value(raw, :status),
      results_path: map_value(raw, :results_path),
      state_path: map_value(raw, :state_path),
      workspace_identity: map_value(raw, :workspace_identity),
      gate_signature: map_value(raw, :gate_signature),
      reused_from: map_value(raw, :reused_from),
      failed: gate_failed_results(map_value(raw, :results))
    }
  end

  defp latest_gate_for_update(running_entry, _update), do: Map.get(running_entry, :latest_gate)

  defp model_routing_for_update(_existing, %{model_routing: model_routing}) when is_map(model_routing), do: model_routing
  defp model_routing_for_update(_existing, %{"model_routing" => model_routing}) when is_map(model_routing), do: model_routing
  defp model_routing_for_update(existing, _update), do: existing

  defp model_fallback_for_update(_existing, %{model_routing: %{fallback: fallback}}) when is_map(fallback), do: fallback
  defp model_fallback_for_update(_existing, %{"model_routing" => %{"fallback" => fallback}}) when is_map(fallback), do: fallback
  defp model_fallback_for_update(existing, _update), do: existing

  defp gate_failed_results(results) when is_list(results) do
    results
    |> Enum.reject(fn result -> map_value(result, :status) in [:pass, "pass"] end)
    |> Enum.map(fn result ->
      %{
        name: map_value(result, :name),
        status: map_value(result, :status),
        exit_status: map_value(result, :exit_status)
      }
    end)
  end

  defp gate_failed_results(_results), do: []

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_claude_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp refine_event_label(event, message, %{raw: raw}) when event in [:assistant, :assistant_message] and is_map(raw) do
    content = get_in_any(raw, ["message", "content"]) || Map.get(raw, "content") || Map.get(raw, :content)
    tool_name = extract_first_tool_name(content)

    tool_event_label(tool_name, message)
  end

  defp refine_event_label(event, message, %{raw: raw}) when event in [:tool_started, :tool_updated, :tool_completed] and is_map(raw) do
    tool_name = extract_tool_name(raw)
    tool_event_label(tool_name, message)
  end

  defp refine_event_label(event, _message, _update), do: event

  defp tool_event_label(tool_name, message) do
    cond do
      linear_event?(tool_name, message) -> :linear
      github_event?(tool_name, message) -> :github
      tool_atom(tool_name) != nil -> tool_atom(tool_name)
      tool_name != nil -> :tool
      is_binary(message) and message != "" -> :assistant
      true -> :assistant
    end
  end

  defp tool_atom(tool_name) when is_binary(tool_name) do
    case String.downcase(tool_name) do
      "bash" -> :bash
      "read" -> :read
      "write" -> :write
      "edit" -> :edit
      "grep" -> :grep
      "glob" -> :glob
      "agent" -> :agent
      _ -> nil
    end
  end

  defp tool_atom(_tool_name), do: nil

  defp extract_first_tool_name(content) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => type, "name" => name} when type in ["tool_use", "toolCall"] -> name
      %{type: type, name: name} when type in ["tool_use", "toolCall"] -> name
      _ -> nil
    end)
  end

  defp extract_first_tool_name(_), do: nil

  defp extract_tool_name(raw) when is_map(raw) do
    nested_content = get_in_any(raw, ["message", "content"])
    top_level_content = Map.get(raw, "content") || Map.get(raw, :content)

    Map.get(raw, "toolName") ||
      Map.get(raw, :toolName) ||
      Map.get(raw, "name") ||
      Map.get(raw, :name) ||
      get_in_any(raw, ["message", "toolName"]) ||
      get_in_any(raw, ["message", "name"]) ||
      extract_first_tool_name(nested_content) ||
      extract_first_tool_name(top_level_content)
  end

  defp linear_event?(tool_name, message) do
    tool_name_str = to_string(tool_name)
    message_str = to_string(message)

    String.contains?(tool_name_str, "Linear") or
      String.contains?(tool_name_str, "linear") or
      (tool_name == "ToolSearch" and String.contains?(message_str, "linear"))
  end

  defp github_event?(tool_name, message) do
    message_str = to_string(message)

    github_command? =
      String.starts_with?(message_str, "$ gh ") or String.starts_with?(message_str, "$ git ")

    tool_name_str = to_string(tool_name) |> String.downcase()

    (tool_name_str == "bash" and github_command?) or
      (tool_name == "ToolSearch" and String.contains?(message_str, "github"))
  end

  # Filter noisy/empty events from the log
  defp loggable_event?(:unknown, _message), do: false
  defp loggable_event?(:assistant, nil), do: false
  defp loggable_event?(:assistant, ""), do: false
  defp loggable_event?(:assistant_message, nil), do: false
  defp loggable_event?(:assistant_message, ""), do: false
  defp loggable_event?(_event, _message), do: true

  defp extract_event_summary(event, update) when event in [:assistant, :assistant_message] do
    Map.get(update, :message) ||
      case Map.get(update, :raw) do
        raw when is_map(raw) ->
          raw
          |> get_in_any(["message", "content"])
          |> extract_content_text()

        _ ->
          nil
      end
  end

  defp extract_event_summary(:tool_use, %{raw: raw}) when is_map(raw) do
    tool_name = get_in_any(raw, ["tool", "name"]) || get_in_any(raw, ["content", "name"])
    tool_input = get_in_any(raw, ["tool", "input"]) || get_in_any(raw, ["content", "input"])

    cond do
      tool_name && tool_input -> "#{tool_name}: #{truncate_text(inspect(tool_input), 500)}"
      tool_name -> tool_name
      true -> nil
    end
  end

  defp extract_event_summary(event, update) when event in [:tool_started, :tool_updated, :tool_completed] do
    Map.get(update, :message) || summarize_pi_tool_event(Map.get(update, :raw))
  end

  defp extract_event_summary(:warning, update) do
    Map.get(update, :message) || summarize_warning_event(Map.get(update, :raw))
  end

  defp extract_event_summary(:result, %{raw: raw}) when is_map(raw) do
    subtype = Map.get(raw, "subtype") || Map.get(raw, :subtype) || "completed"
    "#{subtype}"
  end

  defp extract_event_summary(:session_started, %{session_id: sid}) when is_binary(sid) do
    "Session #{sid}"
  end

  defp extract_event_summary(:rate_limit, %{raw: raw}) when is_map(raw) do
    retry_after = get_in_any(raw, ["retryAfter"]) || get_in_any(raw, ["retry_after"])
    if retry_after, do: "retry after #{retry_after}s", else: "rate limited"
  end

  defp extract_event_summary(:system, %{raw: raw}) when is_map(raw) do
    Map.get(raw, "subtype") || Map.get(raw, :subtype)
  end

  defp extract_event_summary(:tracker_update_detected, update) do
    Map.get(update, :message) || Map.get(update, "message")
  end

  defp extract_event_summary(_event, _update), do: nil

  defp get_in_any(map, [key | rest]) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

    case rest do
      [] -> value
      _ when is_map(value) -> get_in_any(value, rest)
      _ -> value
    end
  rescue
    ArgumentError -> nil
  end

  defp summarize_pi_tool_event(raw) when is_map(raw) do
    tool_name = extract_tool_name(raw)
    content = event_content(raw)
    input = first_tool_input(content) || event_tool_input(raw)
    result = extract_content_text(content)

    case {tool_name, input, result} do
      {tool_name, input, _result} when is_binary(tool_name) and is_map(input) -> summarize_tool_use(tool_name, input)
      {tool_name, _input, result} when is_binary(tool_name) and is_binary(result) -> "#{tool_name}: #{truncate_text(result, 200)}"
      {tool_name, _input, _result} when is_binary(tool_name) -> tool_name
      _ -> nil
    end
  end

  defp summarize_pi_tool_event(_raw), do: nil

  defp event_content(raw), do: get_in_any(raw, ["message", "content"]) || Map.get(raw, "content") || Map.get(raw, :content)

  defp event_tool_input(raw) do
    Map.get(raw, "arguments") ||
      Map.get(raw, :arguments) ||
      Map.get(raw, "args") ||
      Map.get(raw, :args)
  end

  defp summarize_warning_event(%{"type" => "custom_message", "content" => content}) when is_binary(content), do: content
  defp summarize_warning_event(%{type: "custom_message", content: content}) when is_binary(content), do: content
  defp summarize_warning_event(%{"type" => "model_change", "provider" => provider, "modelId" => model}), do: "model changed: #{provider}/#{model}"
  defp summarize_warning_event(%{"type" => "thinking_level_change", "thinkingLevel" => level}), do: "thinking level: #{level}"
  defp summarize_warning_event(_raw), do: nil

  defp first_tool_input(content) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => type, "arguments" => input} when type in ["tool_use", "toolCall"] -> input
      %{"type" => type, "input" => input} when type in ["tool_use", "toolCall"] -> input
      %{type: type, arguments: input} when type in ["tool_use", "toolCall"] -> input
      %{type: type, input: input} when type in ["tool_use", "toolCall"] -> input
      _ -> nil
    end)
  end

  defp first_tool_input(_content), do: nil

  defp extract_content_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} -> [text]
      %{"type" => type, "name" => name, "arguments" => input} when type in ["tool_use", "toolCall"] -> [summarize_tool_use(name, input)]
      %{"type" => type, "name" => name, "input" => input} when type in ["tool_use", "toolCall"] -> [summarize_tool_use(name, input)]
      %{"type" => type, "name" => name} when type in ["tool_use", "toolCall"] -> [name]
      %{type: "text", text: text} -> [text]
      _ -> []
    end)
    |> Enum.join(" ")
    |> truncate_text(1000)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_content_text(_), do: nil

  defp summarize_tool_use("Bash", %{"command" => cmd}), do: "$ #{truncate_text(cmd, 200)}"
  defp summarize_tool_use("Read", %{"file_path" => path}), do: "Read #{path}"
  defp summarize_tool_use("Write", %{"file_path" => path}), do: "Write #{path}"
  defp summarize_tool_use("Edit", %{"file_path" => path}), do: "Edit #{path}"
  defp summarize_tool_use("Glob", %{"pattern" => pat}), do: "Glob #{pat}"
  defp summarize_tool_use("Grep", %{"pattern" => pat}), do: "Grep #{pat}"
  defp summarize_tool_use("Agent", %{"prompt" => p}), do: "Agent: #{truncate_text(p, 150)}"

  defp summarize_tool_use(name, %{"query" => q}), do: "#{name}: #{truncate_text(q, 200)}"
  defp summarize_tool_use(name, %{"command" => c}), do: "#{name}: #{truncate_text(c, 200)}"
  defp summarize_tool_use(name, %{"file_path" => p}), do: "#{name} #{p}"
  defp summarize_tool_use(name, %{"url" => u}), do: "#{name} #{truncate_text(u, 200)}"
  defp summarize_tool_use(name, input) when map_size(input) == 0, do: name

  defp summarize_tool_use(name, input) when is_map(input) do
    case Enum.take(input, 1) do
      [{k, v}] when is_binary(v) -> "#{name}: #{k}=#{truncate_text(v, 150)}"
      _ -> "#{name}: #{truncate_text(inspect(input), 200)}"
    end
  end

  defp truncate_text(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max) <> "..."
  end

  defp truncate_text(text, _max), do: text

  defp append_to_event_log(log, entry, max) when length(log) >= max do
    [entry | Enum.take(log, max - 1)]
  end

  defp append_to_event_log(log, entry, _max), do: [entry | log]

  defp refresh_running_entry_state(%{issue: %Issue{id: issue_id} = issue} = running_entry) do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{state: current_state} | _]} ->
        %{running_entry | issue: %{issue | state: current_state}}

      _ ->
        running_entry
    end
  rescue
    _ -> running_entry
  end

  defp refresh_running_entry_state(running_entry), do: running_entry

  defp archive_running_entry(state, running_entry, reason) do
    issue = Map.get(running_entry, :issue)
    identifier = Map.get(running_entry, :identifier)
    finished_at = DateTime.utc_now()

    archived_entry =
      %{
        issue_id: issue && issue.id,
        identifier: identifier,
        session_id: Map.get(running_entry, :session_id),
        state: issue && issue.state,
        started_at: Map.get(running_entry, :started_at),
        finished_at: finished_at,
        exit_reason: archive_exit_reason(reason),
        turn_count: Map.get(running_entry, :turn_count, 0),
        model_routing: Map.get(running_entry, :model_routing),
        adapter: Map.get(running_entry, :adapter),
        tokens: %{
          input_tokens: Map.get(running_entry, :claude_input_tokens, 0),
          output_tokens: Map.get(running_entry, :claude_output_tokens, 0),
          total_tokens: Map.get(running_entry, :claude_total_tokens, 0)
        },
        latest_gate: Map.get(running_entry, :latest_gate),
        event_log: Map.get(running_entry, :event_log, [])
      }
      |> maybe_put_non_active_state(reason, issue)

    archive_path = persist_archived_run(archived_entry)

    ledger_status = run_ledger_status(reason)

    running_entry
    |> Map.get(:ledger)
    |> finalize_run_ledger_artifacts(ledger_status, Map.get(running_entry, :final_report))
    |> complete_run_ledger(ledger_status, %{
      exit_reason: archive_exit_reason(reason),
      non_active_state: if(reason == :handoff, do: issue && issue.state, else: nil),
      session_id: Map.get(running_entry, :session_id),
      turn_count: Map.get(running_entry, :turn_count, 0)
    })
    |> link_run_ledger_archive(archive_path)

    # In-memory index: metadata only, no event_log
    index_entry = Map.delete(archived_entry, :event_log)
    existing = Map.get(state, :archived_runs, [])

    Rondo.Debug.log("Archived run for #{identifier}, now #{length(existing) + 1} in-memory entries")
    %{state | archived_runs: [index_entry | existing]}
  end

  defp archive_exit_reason(:normal), do: "completed"
  defp archive_exit_reason(:terminated), do: "terminated"
  defp archive_exit_reason(:handoff), do: "handed_off"
  defp archive_exit_reason(reason), do: "exited: #{inspect(reason)}"

  defp run_ledger_status(:normal), do: :completed
  defp run_ledger_status(:terminated), do: :terminated
  defp run_ledger_status(:handoff), do: :handed_off
  defp run_ledger_status(_reason), do: :failed

  defp maybe_put_non_active_state(entry, :handoff, %Issue{state: state}) when is_binary(state),
    do: Map.put(entry, :non_active_state, state)

  defp maybe_put_non_active_state(entry, :handoff, %{state: state}) when is_binary(state),
    do: Map.put(entry, :non_active_state, state)

  defp maybe_put_non_active_state(entry, _reason, _issue), do: entry

  # --- Per-run file persistence ---
  # Layout: <archive_root>/<IDENTIFIER>/<timestamp>.json

  defp archived_run_context(entry) do
    "issue_id=#{entry[:issue_id] || "n/a"} " <>
      "issue_identifier=#{entry[:identifier] || "n/a"} session_id=#{entry[:session_id] || "n/a"}"
  end

  defp persist_archived_run(entry) do
    identifier = entry[:identifier] || "unknown"
    timestamp = format_file_timestamp(entry[:started_at])
    dir = Path.join(archive_root(), identifier)
    path = Path.join(dir, "#{timestamp}.json")

    serializable =
      entry
      |> Map.update(:started_at, nil, &datetime_to_iso/1)
      |> Map.update(:finished_at, nil, &datetime_to_iso/1)
      |> Map.update(:event_log, [], fn log ->
        Enum.map(log, fn e -> Map.update(e, :at, nil, &datetime_to_iso/1) end)
      end)

    case Jason.encode(serializable) do
      {:ok, json} ->
        File.mkdir_p!(dir)
        File.write!(path, json)
        path

      {:error, reason} ->
        Logger.warning("Failed to persist archived run #{archived_run_context(entry)} reason=#{inspect(reason)}")

        nil
    end
  rescue
    error ->
      Logger.warning("Failed to persist archived run #{archived_run_context(entry)} error=#{Exception.message(error)}")

      nil
  end

  @doc false
  @spec load_archived_run(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load_archived_run(identifier, filename) do
    with true <- safe_archive_segment?(identifier),
         true <- safe_archive_segment?(filename),
         path = Path.join([archive_root(), identifier, filename]),
         {:ok, json} <- File.read(path),
         {:ok, entry} <- decode_archived_json(json) do
      {:ok, deserialize_archived_entry(entry)}
    else
      false -> {:error, :invalid_path}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :read_failed}
  end

  defp load_archived_runs do
    archive_root()
    |> load_archive_identifiers()
    |> Enum.flat_map(&load_archived_runs_for_identifier/1)
    |> Enum.sort_by(& &1[:started_at], :desc)
  rescue
    error ->
      Rondo.Debug.log("Failed to load archived runs: #{Exception.message(error)}")
      []
  end

  defp load_paused_interrupts do
    [Config.workspace_root(), ".rondo_runs", "*", "*", "manifest.json"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&load_paused_interrupt_manifest/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_issue_id, entry} -> Map.get(entry, :paused_at) || "" end)
    |> Map.new()
  rescue
    error ->
      Rondo.Debug.log("Failed to load paused interrupts: #{Exception.message(error)}")
      %{}
  end

  defp load_paused_interrupt_manifest(path) do
    with {:ok, manifest} <- RunLedger.load_manifest(path),
         "paused" <- Map.get(manifest, "status"),
         %{"id" => issue_id} = issue_snapshot when is_binary(issue_id) <- Map.get(manifest, "issue"),
         entry <- paused_entry_from_manifest(manifest, issue_snapshot, path) do
      {issue_id, entry}
    else
      _ -> nil
    end
  end

  defp paused_entry_from_manifest(manifest, issue_snapshot, manifest_path) do
    issue = issue_from_manifest(issue_snapshot)
    interrupt = Map.get(manifest, "interrupt", %{})
    ledger = run_ledger_from_manifest(manifest, manifest_path)

    %{
      issue_id: issue.id,
      identifier: issue.identifier || issue.id,
      issue: issue,
      state: issue.state,
      session_id: get_in(manifest, ["agent", "session_id"]) || get_in(interrupt, ["resume", "session_id"]),
      run_id: run_ledger_id(ledger) || Map.get(manifest, "run_id"),
      run_dir: run_ledger_dir(ledger) || Map.get(manifest, "run_dir"),
      workspace: get_in(manifest, ["repo", "workspace"]),
      paused_at: get_in(manifest, ["timestamps", "paused_at"]),
      retry_attempt: get_in(interrupt, ["resume", "retry_attempt"]),
      latest_gate: Map.get(interrupt, "gate"),
      model_routing_context: get_in(interrupt, ["resume", "model_routing_context"]),
      interrupt: interrupt,
      tracker_visibility: "unknown",
      ledger: ledger
    }
  end

  defp run_ledger_from_manifest(%{"run_id" => run_id, "run_dir" => run_dir} = manifest, manifest_path)
       when is_binary(run_id) and is_binary(run_dir) and is_binary(manifest_path) do
    %RunLedger{
      run_id: run_id,
      run_dir: run_dir,
      manifest_path: manifest_path,
      next_seq: next_run_ledger_sequence(Map.get(manifest, "checkpoints", [])),
      manifest: manifest
    }
  end

  defp run_ledger_from_manifest(_manifest, _manifest_path), do: nil

  defp next_run_ledger_sequence(checkpoints) when is_list(checkpoints) do
    checkpoints
    |> Enum.map(fn checkpoint -> Map.get(checkpoint, "seq") end)
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> 1
      sequences -> Enum.max(sequences) + 1
    end
  end

  defp next_run_ledger_sequence(_checkpoints), do: 1

  defp issue_from_manifest(issue_snapshot) do
    %Issue{
      id: map_value(issue_snapshot, :id),
      identifier: map_value(issue_snapshot, :identifier),
      title: map_value(issue_snapshot, :title),
      description: map_value(issue_snapshot, :description),
      priority: map_value(issue_snapshot, :priority),
      state: map_value(issue_snapshot, :state),
      url: map_value(issue_snapshot, :url),
      labels: map_value(issue_snapshot, :labels) || []
    }
  end

  defp load_archive_identifiers(root) do
    case File.ls(root) do
      {:ok, identifiers} -> Enum.map(identifiers, &Path.join(root, &1))
      {:error, _} -> []
    end
  end

  defp load_archived_runs_for_identifier(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&load_archived_run_file(Path.join(dir, &1)))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp decode_archived_json(json) do
    case Jason.decode(json) do
      {:ok, entry} when is_map(entry) -> {:ok, entry}
      _ -> {:error, :invalid_json}
    end
  end

  defp load_archived_run_file(path) do
    with {:ok, json} <- File.read(path),
         {:ok, entry} when is_map(entry) <- Jason.decode(json) do
      entry
      |> deserialize_archived_entry()
      |> Map.delete(:event_log)
    else
      _ -> nil
    end
  end

  @archive_keys ~w(issue_id identifier session_id state started_at finished_at exit_reason non_active_state turn_count tokens latest_gate event_log model_routing adapter)
  @token_keys ~w(input_tokens output_tokens total_tokens)
  @event_keys ~w(at event message tokens)

  defp deserialize_archived_entry(entry) when is_map(entry) do
    entry
    |> atomize_allowed_keys(@archive_keys)
    |> Map.update(:tokens, %{}, &deserialize_token_map/1)
    |> Map.update(:event_log, [], &deserialize_event_log/1)
    |> Map.update(:started_at, nil, &parse_datetime/1)
    |> Map.update(:finished_at, nil, &parse_datetime/1)
  end

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> ts
    end
  end

  defp parse_datetime(other), do: other

  defp deserialize_token_map(tokens) when is_map(tokens), do: atomize_allowed_keys(tokens, @token_keys)
  defp deserialize_token_map(tokens), do: tokens

  defp deserialize_event_log(log) when is_list(log), do: Enum.map(log, &deserialize_event_entry/1)
  defp deserialize_event_log(log), do: log

  defp deserialize_event_entry(entry) when is_map(entry) do
    entry
    |> atomize_allowed_keys(@event_keys)
    |> Map.update(:event, nil, &deserialize_event_label/1)
    |> Map.update(:tokens, %{}, &deserialize_token_map/1)
  end

  defp deserialize_event_entry(entry), do: entry

  defp deserialize_event_label(event) when is_binary(event) do
    String.to_existing_atom(event)
  rescue
    ArgumentError -> event
  end

  defp deserialize_event_label(event), do: event

  defp atomize_allowed_keys(map, allowed) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_atom(k, allowed), v}
      other -> other
    end)
  end

  defp safe_atom(key, allowed) when is_binary(key) do
    if key in allowed, do: String.to_atom(key), else: key
  end

  defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso(other), do: other

  defp format_file_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[:\.]/, "-")
  end

  defp format_file_timestamp(iso) when is_binary(iso) do
    String.replace(iso, ~r/[:\.]/, "-")
  end

  defp format_file_timestamp(_), do: "unknown"

  defp safe_archive_segment?(segment) when is_binary(segment) do
    segment not in ["", ".", ".."] and Path.basename(segment) == segment
  end

  defp safe_archive_segment?(_segment), do: false

  defp archive_root do
    Path.join(Config.workspace_root(), ".rondo_archive")
  end

  defp transition_issue_to_in_progress(%Issue{state: state} = issue, ledger) do
    if normalize_state(state) == "todo" do
      authorize_and_transition_todo_issue(issue, ledger)
    else
      {:ok, issue, ledger}
    end
  end

  defp authorize_and_transition_todo_issue(issue, ledger) do
    side_effect = tracker_transition_side_effect(issue)

    case SideEffectPolicy.evaluate(side_effect, ledger: ledger, workspace: expected_workspace_for_issue(issue)) do
      {:ok, decision} ->
        do_transition_issue_to_in_progress(issue, Map.get(decision, :ledger, ledger))

      {:blocked, %{block_reason: :action_policy_requires_guidance, interrupt: interrupt} = decision} ->
        {:paused, interrupt, Map.get(decision, :ledger, ledger)}

      {:blocked, %{block_reason: reason} = decision} ->
        {:blocked, reason, Map.get(decision, :ledger, ledger)}
    end
  end

  defp do_transition_issue_to_in_progress(%Issue{id: issue_id} = issue, ledger) do
    case Tracker.update_issue_state(issue_id, "In Progress") do
      :ok ->
        Logger.info("Transitioned #{issue_context(issue)} to In Progress")
        {:ok, %{issue | state: "In Progress"}, ledger}

      {:error, reason} ->
        Logger.warning("Failed to transition #{issue_context(issue)} to In Progress: #{inspect(reason)}")
        {:blocked, {:issue_transition_failed, reason}, ledger}
    end
  end

  defp transition_issue_to_release_state(%Issue{state: current_state} = issue, target_state) when is_binary(target_state) do
    if normalize_state(current_state) == normalize_state(target_state) do
      issue
    else
      case Tracker.update_issue_state(issue.id, target_state) do
        :ok ->
          Logger.info("Transitioned #{issue_context(issue)} to #{target_state}")
          %{issue | state: target_state}

        {:error, reason} ->
          Logger.warning("Failed to transition #{issue_context(issue)} to #{target_state}: #{inspect(reason)}")
          issue
      end
    end
  end

  defp transition_issue_to_release_state(issue, _target_state), do: issue

  defp release_loop_rework_state, do: Config.release_loop_rework_state()
  defp release_loop_review_state, do: Config.release_loop_review_state()
  defp release_loop_merge_state, do: Config.release_loop_merge_state()

  defp tracker_repo do
    Config.tracker_repo() || repo_slug_from_git()
  end

  defp repo_slug_from_git do
    case System.find_executable("git") do
      nil ->
        nil

      git ->
        case System.cmd(git, ["remote", "get-url", "origin"], stderr_to_stdout: true) do
          {output, 0} -> parse_repo_slug(String.trim(output))
          _ -> nil
        end
    end
  end

  defp parse_repo_slug(url) when is_binary(url) do
    cond do
      String.contains?(url, "github.com:") ->
        url
        |> String.split("github.com:", parts: 2)
        |> List.last()
        |> String.trim_trailing(".git")

      String.contains?(url, "github.com/") ->
        url
        |> String.split("github.com/", parts: 2)
        |> List.last()
        |> String.trim_trailing(".git")

      true ->
        nil
    end
  end

  defp parse_repo_slug(_url), do: nil

  defp tracker_transition_side_effect(%Issue{id: issue_id} = issue) do
    %{
      action: tracker_transition_action(),
      classes: tracker_write_classes(),
      label: "Tracker update",
      operation: "Change issue #{issue.identifier || issue_id} from Todo to In Progress",
      required: true,
      resume_safe: true,
      skip_behavior: "block",
      side_effect_id: "tracker-transition:#{issue_id}:in-progress"
    }
  end

  defp tracker_transition_action do
    case Config.tracker_kind() do
      "memory" -> "tracker.test.transition"
      _ -> "tracker.issue.transition"
    end
  end

  defp tracker_write_classes do
    case Config.tracker_kind() do
      "memory" -> ["test"]
      _ -> ["git-remote"]
    end
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp schedule_timeseries_sample do
    Process.send_after(self(), :timeseries_sample, @timeseries_sample_interval_ms)
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    claude_totals =
      apply_token_delta(
        state.claude_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | claude_totals: claude_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    %{
      state
      | poll_interval_ms: Config.poll_interval_ms(),
        max_concurrent_agents: Config.max_concurrent_agents()
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_claude_token_delta(
         %{claude_totals: claude_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | claude_totals: apply_token_delta(claude_totals, token_delta)}
  end

  defp apply_claude_token_delta(state, _token_delta), do: state

  defp apply_claude_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | claude_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_claude_rate_limits(state, _update), do: state

  defp apply_token_delta(claude_totals, token_delta) do
    input_tokens = Map.get(claude_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(claude_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(claude_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(claude_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  # Claude Code events are retained as additive per-event usage for compatibility
  # with existing adapter semantics. Pi emits cumulative/repeated snapshots, so
  # Rondo accounts only positive deltas while retaining the raw usage payload in
  # ledger events for diagnostics.
  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    usage = extract_token_usage(update)

    input = get_token_usage(usage, :input) || 0
    output = get_token_usage(usage, :output) || 0
    total = get_token_usage(usage, :total) || 0
    cost = get_token_cost(usage)

    if cumulative_usage_update?(update) do
      cumulative_token_delta(running_entry, update, input, output, total, cost)
    else
      %{
        input_tokens: input,
        output_tokens: output,
        total_tokens: total,
        cost: cost,
        input_reported: input,
        output_reported: output,
        total_reported: total,
        cost_reported: cost
      }
    end
  end

  defp cumulative_token_delta(running_entry, update, input, output, total, cost) do
    same_accounting_ref? = continue_cumulative_usage?(running_entry, update, total)
    last_input = if same_accounting_ref?, do: Map.get(running_entry, :claude_last_reported_input_tokens, 0), else: 0
    last_output = if same_accounting_ref?, do: Map.get(running_entry, :claude_last_reported_output_tokens, 0), else: 0
    last_total = if same_accounting_ref?, do: Map.get(running_entry, :claude_last_reported_total_tokens, 0), else: 0
    last_cost = if same_accounting_ref?, do: Map.get(running_entry, :claude_last_reported_cost, 0), else: 0

    %{
      input_tokens: positive_delta(input, last_input),
      output_tokens: positive_delta(output, last_output),
      total_tokens: positive_delta(total, last_total),
      cost: positive_number_delta(cost, last_cost),
      input_reported: input,
      output_reported: output,
      total_reported: total,
      cost_reported: cost
    }
  end

  defp cumulative_usage_update?(update), do: Map.get(update, :adapter, Map.get(update, "adapter")) == "pi"

  defp usage_accounting_ref(update) do
    session_id = Map.get(update, :session_id, Map.get(update, "session_id"))
    run_ref = Map.get(update, :run_ref, Map.get(update, "run_ref"))
    provider_ref = if is_map(run_ref), do: Map.get(run_ref, :provider_ref, Map.get(run_ref, "provider_ref"))
    adapter = Map.get(update, :adapter, Map.get(update, "adapter"))

    cond do
      is_binary(session_id) and session_id != "" -> {:session_id, session_id}
      is_binary(provider_ref) and provider_ref != "" -> {:run_ref, provider_ref}
      is_binary(adapter) and adapter != "" -> {:adapter, adapter}
      true -> nil
    end
  end

  defp continue_cumulative_usage?(running_entry, update, current_total) do
    previous_ref = Map.get(running_entry, :claude_usage_accounting_ref)
    current_ref = usage_accounting_ref(update)
    previous_total = Map.get(running_entry, :claude_last_reported_total_tokens, 0)

    ref_continues? =
      current_ref == previous_ref or fallback_to_stable_usage_ref_upgrade?(previous_ref, current_ref)

    ref_continues? and current_total >= previous_total
  end

  defp fallback_to_stable_usage_ref_upgrade?({:adapter, _}, {:session_id, _}), do: true
  defp fallback_to_stable_usage_ref_upgrade?({:adapter, _}, {:run_ref, _}), do: true
  defp fallback_to_stable_usage_ref_upgrade?(_, _), do: false

  defp positive_delta(current, previous) when is_integer(current) and is_integer(previous), do: max(0, current - previous)
  defp positive_delta(current, _previous) when is_integer(current), do: current
  defp positive_delta(_current, _previous), do: 0

  defp positive_number_delta(nil, _previous), do: nil

  defp positive_number_delta(current, previous) when is_number(current) and is_number(previous), do: max(0, current - previous)
  defp positive_number_delta(current, _previous) when is_number(current), do: current
  defp positive_number_delta(_current, _previous), do: nil

  defp put_accounted_usage(update, token_delta) do
    usage = extract_token_usage(update)

    if usage == %{} do
      update
    else
      accounted_usage =
        %{
          input_tokens: Map.get(token_delta, :input_tokens, 0),
          output_tokens: Map.get(token_delta, :output_tokens, 0),
          total_tokens: Map.get(token_delta, :total_tokens, 0)
        }
        |> maybe_put_cost(Map.get(token_delta, :cost))

      Map.put(update, :accounted_usage, accounted_usage)
    end
  end

  defp maybe_put_cost(accounted_usage, nil), do: accounted_usage
  defp maybe_put_cost(accounted_usage, cost) when is_number(cost), do: Map.put(accounted_usage, :cost, cost)

  defp extract_token_usage(update) do
    usage = Map.get(update, :usage) || Map.get(update, "usage") || %{}
    if is_map(usage), do: usage, else: %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp get_token_cost(usage) when is_map(usage) do
    case Map.get(usage, :cost, Map.get(usage, "cost")) do
      value when is_number(value) and value >= 0 -> value
      %{} = cost -> payload_number(cost, ["total", :total])
      _value -> nil
    end
  end

  defp get_token_cost(_usage), do: nil

  defp payload_get(payload, fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_number(payload, fields) do
    Enum.find_value(fields, fn field -> map_number_value(payload, field) end)
  end

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp map_number_value(payload, field) do
    case Map.get(payload, field) do
      value when is_number(value) and value >= 0 -> value
      _other -> nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
