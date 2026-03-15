defmodule Rondo.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Claude Code agent workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias Rondo.{AgentRunner, Config, StatusDashboard, Tracker, Workspace}
  alias Rondo.Linear.Issue

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

    state = %State{
      poll_interval_ms: Config.poll_interval_ms(),
      max_concurrent_agents: Config.max_concurrent_agents(),
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
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
  def terminate(_reason, %{running: running}) do
    running
    |> Map.values()
    |> Enum.each(fn %{pid: pid} when is_pid(pid) ->
      Task.Supervisor.terminate_child(Rondo.TaskSupervisor, pid)
    end)

    :ok
  rescue
    _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

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
        state = archive_running_entry(state, running_entry, reason)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                delay_type: :continuation
              })

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(reason)}"
              })
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
    state = reconcile_running_issues(state)

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
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
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

        terminate_running_issue(state, issue.id, true, issue.state)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, issue.state)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, issue.state)
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

        if missing_count >= @missing_issue_terminate_threshold do
          log_missing_running_issue(state_acc, issue_id)

          state_acc
          |> clear_missing_count(issue_id)
          |> terminate_running_issue(issue_id, false)
        else
          Logger.debug("Issue not visible during running-state refresh: issue_id=#{issue_id} missing_count=#{missing_count}/#{@missing_issue_terminate_threshold}")
          state_acc
        end
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

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

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, final_state \\ nil) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        running_entry =
          if final_state do
            update_in(running_entry, [:issue], fn
              %Issue{} = issue -> %{issue | state: final_state}
              other -> other
            end)
          else
            running_entry
          end

        state = record_session_completion_totals(state, running_entry)
        state = archive_running_entry(state, running_entry, :terminated)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier)
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
    Config.linear_terminal_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.linear_active_states()
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

    case Task.Supervisor.start_child(Rondo.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)}")

        transition_issue_to_in_progress(issue)

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            session_id: nil,
            last_claude_message: nil,
            last_claude_timestamp: nil,
            last_claude_event: nil,
            claude_input_tokens: 0,
            claude_output_tokens: 0,
            claude_total_tokens: 0,
            claude_last_reported_input_tokens: 0,
            claude_last_reported_output_tokens: 0,
            claude_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now(),
            event_log: []
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}"
        })
    end
  end

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
            error: error
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
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

        cleanup_issue_workspace(issue.identifier)
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

  defp cleanup_issue_workspace(identifier) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier)
  end

  defp cleanup_issue_workspace(_identifier), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.linear_terminal_states()) do
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
      {:noreply, dispatch_issue(state, issue, attempt)}
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

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    case metadata[:delay_type] do
      :continuation when attempt == 1 -> @continuation_retry_delay_ms
      :poll_retry -> @poll_retry_delay_ms
      :slot_wait -> @slot_wait_delay_ms
      _ -> failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.max_retry_backoff_ms())
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

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

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.max_concurrent_agents()) - map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
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
          claude_input_tokens: metadata.claude_input_tokens,
          claude_output_tokens: metadata.claude_output_tokens,
          claude_total_tokens: metadata.claude_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_claude_timestamp: metadata.last_claude_timestamp,
          last_claude_message: metadata.last_claude_message,
          last_claude_event: metadata.last_claude_event,
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

    {:reply,
     %{
       running: running,
       retrying: retrying,
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
    last_reported_input = Map.get(running_entry, :claude_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :claude_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :claude_last_reported_total_tokens, 0)
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
        last_claude_timestamp: timestamp,
        last_claude_message: summarize_claude_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_claude_event: event,
        claude_input_tokens: claude_input_tokens + token_delta.input_tokens,
        claude_output_tokens: claude_output_tokens + token_delta.output_tokens,
        claude_total_tokens: claude_total_tokens + token_delta.total_tokens,
        claude_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        claude_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        claude_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        event_log: event_log
      }),
      token_delta
    }
  end

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

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

  defp refine_event_label(:assistant, message, %{raw: raw}) when is_map(raw) do
    content = get_in_any(raw, ["message", "content"])
    tool_name = extract_first_tool_name(content)

    cond do
      is_linear_event?(tool_name, message) -> :linear
      is_github_event?(tool_name, message) -> :github
      tool_name == "Bash" -> :bash
      tool_name == "Read" -> :read
      tool_name == "Write" -> :write
      tool_name == "Edit" -> :edit
      tool_name == "Grep" -> :grep
      tool_name == "Glob" -> :glob
      tool_name == "Agent" -> :agent
      tool_name != nil -> :tool
      is_binary(message) and message != "" -> :assistant
      true -> :assistant
    end
  end

  defp refine_event_label(event, _message, _update), do: event

  defp extract_first_tool_name(content) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "tool_use", "name" => name} -> name
      _ -> nil
    end)
  end

  defp extract_first_tool_name(_), do: nil

  defp is_linear_event?(tool_name, message) do
    tool_name_str = to_string(tool_name)
    message_str = to_string(message)

    String.contains?(tool_name_str, "Linear") or
      String.contains?(tool_name_str, "linear") or
      (tool_name == "ToolSearch" and String.contains?(message_str, "linear"))
  end

  defp is_github_event?(tool_name, message) do
    message_str = to_string(message)

    (tool_name == "Bash" and (String.starts_with?(message_str, "$ gh ") or String.starts_with?(message_str, "$ git "))) or
      (tool_name == "ToolSearch" and String.contains?(message_str, "github"))
  end

  # Filter noisy/empty events from the log
  defp loggable_event?(:unknown, _message), do: false
  defp loggable_event?(:assistant, nil), do: false
  defp loggable_event?(:assistant, ""), do: false
  defp loggable_event?(_event, _message), do: true

  defp extract_event_summary(:assistant, %{raw: raw}) when is_map(raw) do
    raw
    |> get_in_any(["message", "content"])
    |> extract_content_text()
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

  defp get_in_any(_, _), do: nil

  defp extract_content_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} -> [text]
      %{"type" => "tool_use", "name" => name, "input" => input} -> [summarize_tool_use(name, input)]
      %{"type" => "tool_use", "name" => name} -> [name]
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

    archived_entry = %{
      issue_id: issue && issue.id,
      identifier: identifier,
      session_id: Map.get(running_entry, :session_id),
      state: issue && issue.state,
      started_at: Map.get(running_entry, :started_at),
      finished_at: finished_at,
      exit_reason: archive_exit_reason(reason),
      turn_count: Map.get(running_entry, :turn_count, 0),
      tokens: %{
        input_tokens: Map.get(running_entry, :claude_input_tokens, 0),
        output_tokens: Map.get(running_entry, :claude_output_tokens, 0),
        total_tokens: Map.get(running_entry, :claude_total_tokens, 0)
      },
      event_log: Map.get(running_entry, :event_log, [])
    }

    persist_archived_run(archived_entry)

    # In-memory index: metadata only, no event_log
    index_entry = Map.delete(archived_entry, :event_log)
    existing = Map.get(state, :archived_runs, [])

    Rondo.Debug.log("Archived run for #{identifier}, now #{length(existing) + 1} in-memory entries")
    %{state | archived_runs: [index_entry | existing]}
  end

  defp archive_exit_reason(:normal), do: "completed"
  defp archive_exit_reason(:terminated), do: "completed"
  defp archive_exit_reason(reason), do: "exited: #{inspect(reason)}"

  # --- Per-run file persistence ---
  # Layout: <archive_root>/<IDENTIFIER>/<timestamp>.json

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

      {:error, reason} ->
        Logger.warning("Failed to persist archived run for #{identifier}: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning("Failed to persist archived run: #{Exception.message(error)}")
  end

  @doc false
  def load_archived_run(identifier, filename) do
    path = Path.join([archive_root(), identifier, filename])

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, entry} when is_map(entry) -> {:ok, deserialize_archived_entry(entry)}
          _ -> {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :read_failed}
  end

  defp load_archived_runs do
    root = archive_root()
    case File.ls(root) do
      {:ok, identifiers} ->
        identifiers
        |> Enum.flat_map(fn identifier ->
          dir = Path.join(root, identifier)

          case File.ls(dir) do
            {:ok, files} ->
              files
              |> Enum.filter(&String.ends_with?(&1, ".json"))
              |> Enum.map(fn filename ->
                path = Path.join(dir, filename)

                case File.read(path) do
                  {:ok, json} ->
                    case Jason.decode(json) do
                      {:ok, entry} when is_map(entry) ->
                        entry
                        |> deserialize_archived_entry()
                        |> Map.delete(:event_log)

                      _ ->
                        nil
                    end

                  _ ->
                    nil
                end
              end)
              |> Enum.reject(&is_nil/1)

            _ ->
              []
          end
        end)
        |> Enum.sort_by(& &1[:started_at], :desc)

      {:error, _} ->
        []
    end
  rescue
    error ->
      Rondo.Debug.log("Failed to load archived runs: #{Exception.message(error)}")
      []
  end

  defp debug_log(msg) do
    line = "[#{DateTime.utc_now() |> DateTime.to_iso8601()}] #{msg}\n"
    File.mkdir_p!("/tmp/rondo_workspaces")
    File.write!("/tmp/rondo_workspaces/rondo_debug.log", line, [:append])
  end

  @archive_keys ~w(issue_id identifier session_id state started_at finished_at exit_reason turn_count tokens event_log)
  @token_keys ~w(input_tokens output_tokens total_tokens)
  @event_keys ~w(at event message tokens)

  defp deserialize_archived_entry(entry) when is_map(entry) do
    entry
    |> Map.new(fn {k, v} when is_binary(k) -> {safe_atom(k, @archive_keys), v}; other -> other end)
    |> Map.update(:tokens, %{}, fn t when is_map(t) ->
      Map.new(t, fn {k, v} when is_binary(k) -> {safe_atom(k, @token_keys), v}; other -> other end)
    end)
    |> Map.update(:event_log, [], fn log when is_list(log) ->
      Enum.map(log, fn e when is_map(e) ->
        Map.new(e, fn {k, v} when is_binary(k) -> {safe_atom(k, @event_keys), v}; other -> other end)
      end)
    end)
  end

  defp deserialize_archived_entry(_), do: %{}

  defp safe_atom(key, _allowed) when is_atom(key), do: key
  defp safe_atom(key, allowed) when is_binary(key) do
    if key in allowed, do: String.to_atom(key), else: String.to_atom(key)
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

  defp archive_root do
    Path.join(Config.workspace_root(), ".rondo_archive")
  end

  defp transition_issue_to_in_progress(%Issue{id: issue_id, state: state} = issue) do
    if normalize_state(state) == "todo" do
      case Tracker.update_issue_state(issue_id, "In Progress") do
        :ok ->
          Logger.info("Transitioned #{issue_context(issue)} to In Progress")

        {:error, reason} ->
          Logger.warning("Failed to transition #{issue_context(issue)} to In Progress: #{inspect(reason)}")
      end
    end

    :ok
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

  # Claude CLI reports per-message usage on assistant events (not cumulative),
  # so each event's tokens are added directly to the running total.
  defp extract_token_delta(_running_entry, %{event: _, timestamp: _} = update) do
    usage = extract_token_usage(update)

    input = get_token_usage(usage, :input) || 0
    output = get_token_usage(usage, :output) || 0
    total = get_token_usage(usage, :total) || 0

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      input_reported: input,
      output_reported: output,
      total_reported: total
    }
  end

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

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
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
