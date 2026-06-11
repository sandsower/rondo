defmodule Rondo.RunOnce do
  @moduledoc """
  Synchronous one-shot runner for executing exactly one visible tracker issue or local execution request.
  """

  require Logger

  alias Rondo.{
    AgentRunner,
    CleanEval,
    Config,
    ExecutionRequest,
    Linear.Issue,
    PatchArtifact,
    RunLedger,
    SideEffectPolicy,
    Tracker
  }

  @type run_result :: :ok | {:error, term()}
  @type deps :: %{
          fetch_issue_states_by_ids: ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()}),
          update_issue_state: (String.t(), String.t() -> :ok | {:error, term()}),
          action_policy_evaluator: (String.t(), [String.t()], keyword() -> {:ok, map()} | {:error, term()}),
          agent_runner: (Issue.t(), keyword() -> run_result() | no_return())
        }

  @spec run(String.t()) :: run_result()
  def run(issue_id), do: run(issue_id, [])

  @spec run(String.t(), keyword()) :: run_result()
  def run(issue_id, opts) when is_binary(issue_id) do
    deps = Keyword.get(opts, :deps, runtime_deps())
    agent_opts = Keyword.get(opts, :agent_opts, [])

    with :ok <- validate_issue_id(issue_id),
         :ok <- Config.validate!(),
         {:ok, issue} <- fetch_one_issue(issue_id, deps),
         :ok <- ensure_dispatchable(issue),
         {:ok, ledger} <- create_run_once_ledger(issue),
         {deps, agent_opts} = apply_run_policy_file(deps, agent_opts, ledger),
         {:ok, issue, ledger} <- maybe_transition_to_in_progress(issue, deps, ledger) do
      do_run_agent_with_ledger(issue, deps, agent_opts, ledger)
    end
  end

  def run(issue_id, _opts), do: {:error, {:invalid_issue_id, issue_id}}

  @spec run_manifest(Path.t(), keyword()) :: run_result()
  def run_manifest(path, opts \\ []) do
    if is_binary(path) do
      deps = Keyword.get(opts, :deps, runtime_deps())
      agent_opts = Keyword.get(opts, :agent_opts, [])

      with :ok <- Config.validate!(),
           {:ok, %{issue: issue, source_contract: source_contract}} <- ExecutionRequest.load(path),
           {:ok, policy_file} <- manifest_policy_file(source_contract) do
        ledger_opts = manifest_ledger_opts(source_contract, policy_file)
        run_agent(issue, deps, manifest_agent_opts(agent_opts), ledger_opts)
      end
    else
      {:error, {:invalid_execution_request_path, path}}
    end
  end

  defp manifest_agent_opts(agent_opts) do
    Keyword.put_new(agent_opts, :issue_state_fetcher, &AgentRunner.no_tracker_issue_state_fetcher/1)
  end

  # Threads the per-run frozen policy file (copied into the run dir at ledger
  # creation) into every evaluator path the run owns: the deps evaluator used
  # for tracker transitions and the agent opts consumed by AgentRunner for
  # workspace side-effect evaluations.
  defp apply_run_policy_file(deps, agent_opts, %RunLedger{policy_file: nil}), do: {deps, agent_opts}

  defp apply_run_policy_file(deps, agent_opts, %RunLedger{policy_file: policy_file}) do
    {maybe_override_policy_evaluator(deps, policy_file), Keyword.put(agent_opts, :action_policy_policy_file, policy_file)}
  end

  defp manifest_ledger_opts(source_contract, nil), do: [source_contract: source_contract]

  defp manifest_ledger_opts(source_contract, policy_file),
    do: [source_contract: source_contract, action_policy_policy_file: policy_file]

  @spec manifest_policy_file(map()) :: {:ok, Path.t() | nil} | {:error, term()}
  defp manifest_policy_file(source_contract) do
    case Map.get(source_contract, :runner_extensions) do
      nil -> {:ok, nil}
      extensions when is_map(extensions) -> manifest_action_policy_file(extensions, source_contract)
      other -> {:error, {:invalid_manifest_runner_extensions, other}}
    end
  end

  defp manifest_action_policy_file(extensions, source_contract) do
    case Map.get(extensions, "action_policy") do
      nil -> {:ok, nil}
      action_policy when is_map(action_policy) -> resolve_manifest_policy_file(Map.get(action_policy, "policy_file"), source_contract)
      other -> {:error, {:invalid_manifest_runner_extensions, other}}
    end
  end

  defp resolve_manifest_policy_file(nil, _source_contract), do: {:ok, nil}

  defp resolve_manifest_policy_file(value, source_contract) when is_binary(value) do
    resolved = Path.expand(value, Path.dirname(source_contract.path))

    case File.stat(resolved) do
      {:ok, %File.Stat{type: :regular, access: access}} when access in [:read, :read_write] ->
        {:ok, resolved}

      _ ->
        {:error, {:manifest_policy_file_unreadable, resolved}}
    end
  end

  defp resolve_manifest_policy_file(value, _source_contract), do: {:error, {:invalid_manifest_policy_file, value}}

  # Sole caller (apply_run_policy_file/3) only reaches this with a binary path;
  # the nil-policy_file case returns earlier without overriding the evaluator.
  defp maybe_override_policy_evaluator(deps, policy_file) do
    evaluator = deps.action_policy_evaluator

    %{
      deps
      | action_policy_evaluator: fn action, classes, opts ->
          evaluator.(action, classes, Keyword.put(opts, :policy_file, policy_file))
        end
    }
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      fetch_issue_states_by_ids: &Tracker.fetch_issue_states_by_ids/1,
      update_issue_state: &Tracker.update_issue_state/2,
      action_policy_evaluator: &Rondo.ActionPolicy.evaluate/3,
      agent_runner: fn issue, agent_opts -> AgentRunner.run(issue, self(), agent_opts) end
    }
  end

  @spec validate_issue_id(String.t()) :: :ok | {:error, {:invalid_issue_id, String.t()}}
  defp validate_issue_id(issue_id) do
    if String.trim(issue_id) == "" do
      {:error, {:invalid_issue_id, issue_id}}
    else
      :ok
    end
  end

  @spec fetch_one_issue(String.t(), deps()) :: {:ok, Issue.t()} | {:error, term()}
  defp fetch_one_issue(issue_id, deps) do
    case deps.fetch_issue_states_by_ids.([issue_id]) do
      {:ok, [%Issue{} = issue | _]} -> {:ok, issue}
      {:ok, []} -> {:error, {:issue_not_visible, issue_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_dispatchable(Issue.t()) :: :ok | {:error, term()}
  defp ensure_dispatchable(%Issue{} = issue) do
    active_states = state_set(Config.tracker_active_states())
    terminal_states = state_set(Config.tracker_terminal_states())

    cond do
      !complete_issue_shape?(issue) ->
        {:error, {:issue_not_dispatchable, issue_context(issue), :incomplete_issue}}

      !issue.assigned_to_worker ->
        {:error, {:issue_not_dispatchable, issue_context(issue), :assigned_to_another_worker}}

      terminal_state?(issue.state, terminal_states) ->
        {:error, {:issue_not_dispatchable, issue_context(issue), :terminal_state}}

      !active_state?(issue.state, active_states) ->
        {:error, {:issue_not_dispatchable, issue_context(issue), :inactive_state}}

      todo_blocked_by_non_terminal?(issue, terminal_states) ->
        {:error, {:issue_not_dispatchable, issue_context(issue), :blocked}}

      true ->
        :ok
    end
  end

  @spec maybe_transition_to_in_progress(Issue.t(), deps(), RunLedger.t()) ::
          {:ok, Issue.t(), RunLedger.t()} | {:error, term()}
  defp maybe_transition_to_in_progress(%Issue{state: state} = issue, deps, ledger) do
    if normalize_state(state) == "todo" do
      transition_todo_issue_to_in_progress(issue, deps, ledger)
    else
      {:ok, issue, ledger}
    end
  end

  defp transition_todo_issue_to_in_progress(issue, deps, ledger) do
    with {:ok, ledger} <- authorize_tracker_transition(issue, deps, ledger) do
      case update_issue_to_in_progress(issue, deps) do
        {:ok, issue} ->
          {:ok, issue, ledger}

        {:error, reason} ->
          _ledger = complete_run_once_ledger(ledger, {:error, reason})
          {:error, reason}
      end
    end
  end

  defp update_issue_to_in_progress(issue, deps) do
    case deps.update_issue_state.(issue.id, "In Progress") do
      :ok ->
        Logger.info("Transitioned #{issue_context(issue)} to In Progress for run-once")
        {:ok, %{issue | state: "In Progress"}}

      {:error, reason} ->
        {:error, {:issue_transition_failed, issue_context(issue), reason}}
    end
  end

  @spec authorize_tracker_transition(Issue.t(), deps(), RunLedger.t()) :: {:ok, RunLedger.t()} | {:error, term()}
  defp authorize_tracker_transition(%Issue{} = issue, deps, ledger) do
    side_effect = %{
      action: tracker_transition_action(),
      classes: tracker_write_classes(),
      label: "Tracker update",
      operation: "Change issue #{issue.identifier || issue.id} from Todo to In Progress",
      required: true,
      resume_safe: true,
      skip_behavior: "block",
      side_effect_id: "tracker-transition:#{issue.id}:in-progress"
    }

    case SideEffectPolicy.evaluate(side_effect, evaluator: deps.action_policy_evaluator, ledger: ledger) do
      {:ok, decision} ->
        {:ok, Map.get(decision, :ledger, ledger)}

      {:blocked, %{block_reason: :action_policy_requires_guidance, interrupt: interrupt} = decision} ->
        ledger = Map.get(decision, :ledger, ledger)
        _ledger = pause_run_once_ledger(ledger, interrupt)
        {:error, {:action_policy_guidance_required, interrupt}}

      {:blocked, %{block_reason: :action_policy_denied, envelope: envelope} = decision} ->
        ledger = Map.get(decision, :ledger, ledger)
        _ledger = complete_run_once_ledger(ledger, {:error, {:action_policy_denied, envelope}})
        {:error, {:action_policy_denied, envelope}}

      {:blocked, %{block_reason: {:action_policy_failed, reason}}} ->
        _ledger = complete_run_once_ledger(ledger, {:error, {:action_policy_failed, reason}})
        {:error, {:action_policy_failed, reason}}
    end
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

  @spec create_run_once_ledger(Issue.t(), keyword()) :: {:ok, RunLedger.t()} | {:error, term()}
  defp create_run_once_ledger(issue, ledger_opts \\ []) do
    RunLedger.create_run(issue, ledger_opts)
  end

  @spec run_agent(Issue.t(), deps(), keyword(), keyword()) :: run_result()
  defp run_agent(issue, deps, agent_opts, ledger_opts) do
    with {:ok, ledger} <- create_run_once_ledger(issue, ledger_opts) do
      agent_opts = maybe_put_source_contract_agent_opt(agent_opts, Keyword.get(ledger_opts, :source_contract))
      {deps, agent_opts} = apply_run_policy_file(deps, agent_opts, ledger)
      do_run_agent_with_ledger(issue, deps, agent_opts, ledger)
    end
  end

  defp maybe_put_source_contract_agent_opt(agent_opts, nil), do: agent_opts
  defp maybe_put_source_contract_agent_opt(agent_opts, source_contract) when is_map(source_contract), do: Keyword.put_new(agent_opts, :source_contract, source_contract)

  defp do_run_agent_with_ledger(issue, deps, agent_opts, ledger) do
    agent_opts =
      agent_opts
      |> Keyword.put_new(:run_dir, ledger.run_dir)
      |> Keyword.put_new(:run_ledger, ledger)

    result = deps.agent_runner.(issue, agent_opts)
    {ledger, updates} = record_queued_updates(ledger, issue.id)
    ledger = finalize_run_artifacts(ledger, result, updates)
    ledger = maybe_run_clean_eval(ledger, result)
    complete_run_once_ledger_result(ledger, result)
  rescue
    error ->
      reason = {:agent_run_failed, Exception.message(error)}
      {ledger, _updates} = record_queued_updates(ledger, issue.id)
      complete_run_once_ledger_result(ledger, {:error, reason})
  catch
    :exit, {:action_policy_guidance_required, interrupt} when is_map(interrupt) ->
      {ledger, _updates} = record_queued_updates(ledger, issue.id)
      _ledger = pause_run_once_ledger(ledger, interrupt)
      {:error, {:action_policy_guidance_required, interrupt}}

    :exit, reason ->
      reason = {:agent_run_failed, {:exit, reason}}
      {ledger, _updates} = record_queued_updates(ledger, issue.id)
      complete_run_once_ledger_result(ledger, {:error, reason})

    kind, reason ->
      reason = {:agent_run_failed, {kind, reason}}
      {ledger, _updates} = record_queued_updates(ledger, issue.id)
      complete_run_once_ledger_result(ledger, {:error, reason})
  end

  defp maybe_run_clean_eval(ledger, :ok) do
    if CleanEval.enabled?() do
      run_clean_eval(ledger)
    else
      ledger
    end
  end

  defp maybe_run_clean_eval(ledger, _result), do: ledger

  defp run_clean_eval(ledger) do
    case CleanEval.run(ledger) do
      {:ok, ledger, result} ->
        Logger.info("Run-once clean eval #{ledger_context(ledger)} status=#{result.status}")
        ledger

      {:error, reason} ->
        Logger.warning("Failed to record run-once clean eval #{ledger_context(ledger)} reason=#{inspect(reason)}")
        ledger
    end
  rescue
    # Clean eval is reporting-only: it must never change the run result, even
    # if it crashes. Log and keep the ledger unchanged.
    error ->
      Logger.warning("Run-once clean eval crashed #{ledger_context(ledger)} reason=#{Exception.message(error)}")
      ledger
  end

  defp finalize_run_artifacts(ledger, :ok, updates) do
    ledger
    |> capture_patch_artifact()
    |> record_final_report_artifact(updates)
  end

  defp finalize_run_artifacts(ledger, _result, _updates), do: ledger

  defp capture_patch_artifact(ledger) do
    case PatchArtifact.capture(ledger) do
      {:ok, ledger, status} ->
        Logger.info("Run-once patch artifact capture #{ledger_context(ledger)} status=#{status}")
        ledger

      {:error, reason} ->
        Logger.warning("Failed to capture run-once patch artifact #{ledger_context(ledger)} reason=#{inspect(reason)}")
        ledger
    end
  end

  defp record_final_report_artifact(ledger, updates) do
    case RunLedger.record_final_report(ledger, final_report_from_updates(updates)) do
      {:ok, ledger, status} ->
        Logger.info("Run-once final report validation #{ledger_context(ledger)} status=#{status}")
        ledger

      {:error, reason} ->
        Logger.warning("Failed to record run-once final report #{ledger_context(ledger)} reason=#{inspect(reason)}")
        ledger
    end
  end

  defp final_report_from_updates(updates) do
    updates
    |> Enum.reverse()
    |> Enum.find_value(fn update -> Map.get(update, :final_report) || Map.get(update, "final_report") end)
  end

  defp complete_run_once_ledger_result(ledger, result) do
    case complete_run_once_ledger(ledger, result) do
      {:ok, _ledger} ->
        result

      {:error, reason} ->
        {:error, {:run_once_ledger_completion_failed, reason, original_result(result)}}
    end
  end

  defp complete_run_once_ledger(ledger, :ok), do: RunLedger.complete_run(ledger, :completed, %{mode: "run_once"})
  defp complete_run_once_ledger(ledger, {:error, reason}), do: RunLedger.complete_run(ledger, :failed, %{mode: "run_once", reason: inspect(reason)})

  defp pause_run_once_ledger(ledger, interrupt) do
    case RunLedger.pause_run(ledger, interrupt, source: %{interrupt: "action_policy"}) do
      {:ok, ledger} -> ledger
      {:error, _reason} -> ledger
    end
  end

  defp original_result(:ok), do: :ok
  defp original_result({:error, reason}), do: reason

  defp record_queued_updates(ledger, issue_id) do
    updates = collect_queued_updates(issue_id)
    {Enum.reduce(updates, ledger, &record_update(&2, &1)), updates}
  end

  defp collect_queued_updates(issue_id), do: collect_queued_updates(issue_id, [])

  defp collect_queued_updates(issue_id, acc) do
    receive do
      {:claude_worker_update, ^issue_id, update} when is_map(update) ->
        collect_queued_updates(issue_id, [update | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp record_update(ledger, update) do
    case RunLedger.append_agent_event(ledger, update) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to append run-once ledger agent event #{ledger_context(ledger)} session_id=#{update_session_id(update)} reason=#{inspect(reason)}")
    end

    ledger
    |> write_update_checkpoint(update)
    |> link_gate_artifacts(update)
  end

  defp update_session_id(update) do
    Map.get(update, :session_id) || Map.get(update, "session_id") || "unknown"
  end

  defp write_update_checkpoint(ledger, update) do
    case RunLedger.checkpoint_kind_for_agent_update(update) do
      nil ->
        ledger

      kind ->
        payload = RunLedger.checkpoint_payload_for_agent_update(update)
        source = RunLedger.checkpoint_source_for_agent_update(update)

        case RunLedger.write_checkpoint(ledger, kind, payload, source: source) do
          {:ok, ledger} -> ledger
          {:error, _reason} -> ledger
        end
    end
  end

  defp link_gate_artifacts(ledger, %{event: :gates_completed, raw: raw}) when is_map(raw) do
    artifacts = gate_artifacts(raw)

    case RunLedger.link_artifacts(ledger, artifacts) do
      {:ok, ledger} -> ledger
      {:error, _reason} -> ledger
    end
  end

  defp link_gate_artifacts(ledger, _update), do: ledger

  defp gate_artifacts(raw) do
    results_path = Map.get(raw, :results_path) || Map.get(raw, "results_path")
    results = Map.get(raw, :results) || Map.get(raw, "results") || []

    [%{kind: "gate_results", path: results_path}]
    |> Kernel.++(
      Enum.flat_map(results, fn result ->
        stdout_path = Map.get(result, :stdout_path) || Map.get(result, "stdout_path")
        stderr_path = Map.get(result, :stderr_path) || Map.get(result, "stderr_path")

        [
          %{kind: "gate_stdout", path: stdout_path},
          %{kind: "gate_stderr", path: stderr_path}
        ]
      end)
    )
    |> Enum.reject(&is_nil(&1.path))
  end

  @spec complete_issue_shape?(Issue.t()) :: boolean()
  defp complete_issue_shape?(%Issue{id: id, identifier: identifier, title: title, state: state}) do
    Enum.all?([id, identifier, title, state], &(is_binary(&1) and String.trim(&1) != ""))
  end

  @spec todo_blocked_by_non_terminal?(Issue.t(), MapSet.t(String.t())) :: boolean()
  defp todo_blocked_by_non_terminal?(%Issue{state: state, blocked_by: blockers}, terminal_states) when is_list(blockers) do
    normalize_state(state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) -> !terminal_state?(blocker_state, terminal_states)
        _ -> true
      end)
  end

  defp todo_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  @spec active_state?(String.t(), MapSet.t(String.t())) :: boolean()
  defp active_state?(state, active_states) when is_binary(state), do: MapSet.member?(active_states, normalize_state(state))
  defp active_state?(_state, _active_states), do: false

  @spec terminal_state?(String.t(), MapSet.t(String.t())) :: boolean()
  defp terminal_state?(state, terminal_states) when is_binary(state), do: MapSet.member?(terminal_states, normalize_state(state))
  defp terminal_state?(_state, _terminal_states), do: false

  @spec state_set([String.t()]) :: MapSet.t(String.t())
  defp state_set(states) do
    states
    |> Enum.map(&normalize_state/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  @spec normalize_state(term()) :: String.t()
  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp ledger_context(ledger) do
    issue = Map.get(ledger.manifest, "issue", %{})

    [
      "issue_identifier=#{Map.get(issue, "identifier") || "unknown"}",
      "issue_id=#{Map.get(issue, "id") || "unknown"}",
      "run_id=#{ledger.run_id}",
      "run_dir=#{ledger.run_dir}"
    ]
    |> Enum.join(" ")
  end

  @spec issue_context(Issue.t()) :: String.t()
  defp issue_context(%Issue{identifier: identifier, id: id}) do
    "issue_identifier=#{identifier || "unknown"} issue_id=#{id || "unknown"}"
  end
end
