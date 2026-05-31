defmodule Rondo.RunOnce do
  @moduledoc """
  Synchronous one-shot runner for executing exactly one visible tracker issue.
  """

  require Logger

  alias Rondo.{AgentRunner, Config, ExecutionRequest, Linear.Issue, RunLedger, Tracker}

  @type run_result :: :ok | {:error, term()}
  @type deps :: %{
          fetch_issue_states_by_ids: ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()}),
          update_issue_state: (String.t(), String.t() -> :ok | {:error, term()}),
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
         {:ok, issue} <- maybe_transition_to_in_progress(issue, deps) do
      run_agent(issue, deps, agent_opts)
    end
  end

  def run(issue_id, _opts), do: {:error, {:invalid_issue_id, issue_id}}

  @spec run_manifest(Path.t(), keyword()) :: run_result()
  def run_manifest(path, opts \\ []) do
    if is_binary(path) do
      deps = Keyword.get(opts, :deps, runtime_deps())
      agent_opts = Keyword.get(opts, :agent_opts, [])

      with :ok <- Config.validate!(),
           {:ok, %{issue: issue, source_contract: source_contract}} <- ExecutionRequest.load(path) do
        run_agent(issue, deps, manifest_agent_opts(agent_opts), source_contract: source_contract)
      end
    else
      {:error, {:invalid_execution_request_path, path}}
    end
  end

  defp manifest_agent_opts(agent_opts) do
    Keyword.put_new(agent_opts, :issue_state_fetcher, fn _issue_ids -> {:ok, []} end)
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      fetch_issue_states_by_ids: &Tracker.fetch_issue_states_by_ids/1,
      update_issue_state: &Tracker.update_issue_state/2,
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

  @spec maybe_transition_to_in_progress(Issue.t(), deps()) :: {:ok, Issue.t()} | {:error, term()}
  defp maybe_transition_to_in_progress(%Issue{state: state} = issue, deps) do
    if normalize_state(state) == "todo" do
      case deps.update_issue_state.(issue.id, "In Progress") do
        :ok ->
          Logger.info("Transitioned #{issue_context(issue)} to In Progress for run-once")
          {:ok, %{issue | state: "In Progress"}}

        {:error, reason} ->
          {:error, {:issue_transition_failed, issue_context(issue), reason}}
      end
    else
      {:ok, issue}
    end
  end

  @spec run_agent(Issue.t(), deps(), keyword(), keyword()) :: run_result()
  defp run_agent(issue, deps, agent_opts, ledger_opts \\ []) do
    case RunLedger.create_run(issue, ledger_opts) do
      {:ok, ledger} ->
        do_run_agent_with_ledger(issue, deps, agent_opts, ledger)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_run_agent_with_ledger(issue, deps, agent_opts, ledger) do
    result = deps.agent_runner.(issue, Keyword.put_new(agent_opts, :run_dir, ledger.run_dir))
    ledger = record_queued_updates(ledger, issue.id)
    complete_run_once_ledger_result(ledger, result)
  rescue
    error ->
      reason = {:agent_run_failed, Exception.message(error)}
      ledger = record_queued_updates(ledger, issue.id)
      complete_run_once_ledger_result(ledger, {:error, reason})
  catch
    :exit, reason ->
      reason = {:agent_run_failed, {:exit, reason}}
      ledger = record_queued_updates(ledger, issue.id)
      complete_run_once_ledger_result(ledger, {:error, reason})

    kind, reason ->
      reason = {:agent_run_failed, {kind, reason}}
      ledger = record_queued_updates(ledger, issue.id)
      complete_run_once_ledger_result(ledger, {:error, reason})
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

  defp original_result(:ok), do: :ok
  defp original_result({:error, reason}), do: reason

  defp record_queued_updates(ledger, issue_id) do
    collect_queued_updates(issue_id)
    |> Enum.reduce(ledger, &record_update(&2, &1))
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
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to append run-once ledger agent event #{ledger_context(ledger)} reason=#{inspect(reason)}")
    end

    ledger
    |> write_update_checkpoint(update)
    |> link_gate_artifacts(update)
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
