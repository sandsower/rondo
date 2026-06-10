defmodule Rondo.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with the configured agent adapter.
  """

  require Logger
  alias Rondo.Agent.Adapter
  alias Rondo.Agent.ClaudeCodeAdapter
  alias Rondo.Agent.PiAdapter
  alias Rondo.{Config, Gates, Linear.Issue, ProcessProvider, Tracker, Workspace}
  alias Rondo.ProcessProvider.{Beislid, Native}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, claude_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    workspace_opts = workspace_policy_opts(opts)

    case Workspace.create_for_issue(issue, workspace_opts) do
      {:ok, workspace} ->
        with :ok <- Workspace.run_before_run_hook(workspace, issue, workspace_opts),
             :ok <- send_phase_update(claude_update_recipient, issue, :claude_starting) do
          try do
            case run_agent_turns(workspace, issue, claude_update_recipient, opts) do
              :ok -> :ok
              {:error, reason} -> handle_agent_run_error(issue, reason)
            end
          after
            Workspace.run_after_run_hook(workspace, issue, workspace_opts)
          end
        else
          {:error, reason} ->
            handle_agent_run_error(issue, reason)
        end

      {:error, reason} ->
        handle_agent_run_error(issue, reason)
    end
  end

  defp workspace_policy_opts(opts) do
    case Keyword.get(opts, :run_ledger) do
      nil -> []
      ledger -> [ledger: ledger]
    end
  end

  defp handle_agent_run_error(issue, {:action_policy_guidance_required, interrupt}) do
    Logger.warning("Agent run needs guidance for #{issue_context(issue)}: #{inspect(interrupt["blocked_side_effect"])}")
    exit({:action_policy_guidance_required, interrupt})
  end

  defp handle_agent_run_error(issue, reason) do
    Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
    raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
  end

  defp claude_event_handler(recipient, issue, completion_ref \\ nil) do
    fn event ->
      if Map.get(event, :event_type) == :invocation_completed and is_reference(completion_ref) do
        Process.put(completion_ref, true)
      end

      send_claude_update(recipient, issue, event)
    end
  end

  defp send_claude_update(recipient, %Issue{id: issue_id}, event)
       when is_binary(issue_id) and is_pid(recipient) do
    timestamp = DateTime.utc_now()
    session_id = Adapter.provider_session_id(event)
    usage = Map.get(event, :usage)
    event_type = compatibility_event_type(event)

    send(
      recipient,
      {:claude_worker_update, issue_id,
       %{
         event: event_type,
         timestamp: timestamp,
         adapter: Map.get(event, :adapter),
         run_ref: Map.get(event, :run_ref),
         session_id: session_id,
         usage: usage,
         capabilities: Map.get(event, :capabilities),
         final_report: Map.get(event, :final_report),
         diff_source: Map.get(event, :diff_source),
         raw: compatibility_raw(event)
       }}
    )

    :ok
  end

  defp send_claude_update(_recipient, _issue, _event), do: :ok

  defp compatibility_event_type(%{adapter: "claude_code", raw: %{event_type: event_type}}) when is_atom(event_type), do: event_type
  defp compatibility_event_type(%{event_type: event_type}) when is_atom(event_type), do: event_type
  defp compatibility_event_type(_event), do: :unknown

  defp compatibility_raw(%{adapter: "claude_code", raw: raw}) when is_map(raw), do: raw
  defp compatibility_raw(event), do: event

  defp send_phase_update(recipient, %Issue{id: issue_id}, phase)
       when is_pid(recipient) and is_atom(phase) do
    send(
      recipient,
      {:claude_worker_update, issue_id,
       %{
         event: phase,
         timestamp: DateTime.utc_now(),
         session_id: nil,
         usage: nil,
         raw: %{}
       }}
    )

    :ok
  end

  defp send_phase_update(_recipient, _issue, _phase), do: :ok

  defp run_agent_turns(workspace, issue, claude_update_recipient, opts) do
    with {:ok, adapter} <- adapter_module(opts),
         {:ok, provider} <- process_provider_module(opts),
         :ok <- preflight_process_provider(provider, opts) do
      context = %{
        workspace: workspace,
        claude_update_recipient: claude_update_recipient,
        opts: opts,
        issue_state_fetcher: Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1),
        adapter: adapter,
        process_provider: provider,
        max_turns: Keyword.get(opts, :max_turns, Config.agent_max_turns()),
        gates: Keyword.get(opts, :gates),
        run_dir: Keyword.get(opts, :run_dir)
      }

      do_run_agent_turns(context, issue, 1, nil)
    end
  end

  defp do_run_agent_turns(context, issue, turn_number, run_ref) do
    prompt = build_turn_prompt(context.process_provider, issue, context.opts, turn_number, context.max_turns)

    completion_ref = make_ref()
    Process.put(completion_ref, false)

    result =
      context.adapter.invoke(%{
        prompt: prompt,
        workspace: context.workspace,
        previous_run_ref: run_ref,
        on_event: claude_event_handler(context.claude_update_recipient, issue, completion_ref),
        opts: context.opts
      })

    completion_observed? = Process.get(completion_ref, false)
    Process.delete(completion_ref)

    case result do
      {:ok, %{run_ref: new_run_ref} = invocation_result} ->
        effective_run_ref = new_run_ref || run_ref
        provider_ref = if effective_run_ref, do: Map.get(effective_run_ref, :provider_ref)

        Logger.info(
          "Completed agent turn for #{issue_context(issue)} adapter=#{context.adapter.id()} " <>
            "provider_ref=#{provider_ref} workspace=#{context.workspace} turn=#{turn_number}/#{context.max_turns}"
        )

        maybe_send_invocation_result_update(
          context.claude_update_recipient,
          issue,
          context.adapter,
          invocation_result,
          completion_observed?
        )

        with :ok <- run_gates(context, issue, turn_number) do
          continue_agent_turns(context, issue, turn_number, effective_run_ref)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_send_invocation_result_update(_recipient, _issue, _adapter, _invocation_result, true), do: :ok

  defp maybe_send_invocation_result_update(recipient, issue, adapter, invocation_result, false) do
    :invocation_completed
    |> Adapter.event(
      adapter: adapter.id(),
      run_ref: Map.get(invocation_result, :run_ref),
      usage: Map.get(invocation_result, :usage),
      capabilities: Map.get(invocation_result, :capabilities),
      final_report: Map.get(invocation_result, :final_report),
      diff_source: Map.get(invocation_result, :diff_source),
      raw: Map.get(invocation_result, :raw, %{})
    )
    |> claude_event_handler(recipient, issue).()
  end

  defp run_gates(%{gates: []}, _issue, _turn_number), do: :ok

  defp run_gates(context, issue, turn_number) do
    with {:ok, gate_selection} <- select_gate_selection(context, issue, turn_number) do
      run_selected_gates(context, issue, turn_number, gate_selection)
    end
  end

  defp run_selected_gates(%{run_dir: nil}, _issue, _turn_number, %{gates: []}), do: :ok

  defp run_selected_gates(%{run_dir: nil}, _issue, _turn_number, _gate_selection), do: {:error, :missing_run_ledger_for_gates}

  defp run_selected_gates(context, issue, turn_number, gate_selection) do
    {action_policy_provider, gate_selection} = action_policy_provider_for_gates(gate_selection, context)

    case Gates.run(gate_selection.gates, context.workspace,
           run_dir: context.run_dir,
           execution_id: gate_execution_id(turn_number),
           gate_selection: Map.drop(gate_selection, [:gates, :action_policy_provider]),
           action_policy: true,
           action_policy_evaluator: action_policy_evaluator(action_policy_provider, context.opts)
         ) do
      {:ok, summary} ->
        send_gate_update(context.claude_update_recipient, issue, summary)
        :ok

      {:error, summary} when is_map(summary) ->
        send_gate_update(context.claude_update_recipient, issue, summary)
        {:error, {:gate_failed, gate_error_summary(summary)}}

      {:error, reason} ->
        {:error, {:gate_error, reason}}
    end
  end

  defp select_gate_selection(%{gates: gates}, _issue, _turn_number) when is_list(gates) do
    {:ok, gates |> ProcessProvider.gate_selection_result() |> Map.put(:action_policy_provider, Native)}
  end

  defp select_gate_selection(context, issue, turn_number) do
    opts = gate_selection_opts(context, issue, turn_number)

    case ProcessProvider.select_gate_selection(context.process_provider, opts) do
      {:ok, selection} ->
        {:ok, Map.put(selection, :action_policy_provider, context.process_provider)}

      {:error, reason} ->
        handle_gate_selection_failure(context.process_provider, reason, opts)
    end
  end

  defp gate_selection_opts(context, issue, turn_number) do
    [
      issue: issue,
      workspace: context.workspace,
      run_dir: context.run_dir,
      stage: :post_turn,
      turn_number: turn_number
    ]
    |> maybe_put_source_contract(context.opts)
  end

  defp handle_gate_selection_failure(Native, reason, _opts), do: {:error, {:process_provider_gate_selection_failed, reason}}

  defp handle_gate_selection_failure(_provider, {:invalid_artifact_field, _field} = reason, _opts) do
    {:error, {:process_provider_gate_selection_failed, reason}}
  end

  defp handle_gate_selection_failure(provider, reason, opts) do
    if Config.process_provider_required?() do
      {:error, {:process_provider_gate_selection_failed, reason}}
    else
      provider_id = provider_id(provider)
      Logger.warning("Process provider gate selection failed provider=#{provider_id} reason=#{inspect(reason)}; falling back to native gates")

      with {:ok, selection} <- ProcessProvider.select_gate_selection(Native, opts) do
        {:ok, selection |> annotate_native_fallback(provider_id, reason) |> Map.put(:action_policy_provider, Native)}
      end
    end
  end

  defp action_policy_evaluator(Beislid, context_opts) do
    fn action, classes, opts ->
      Beislid.evaluate_action_policy(action, classes, Keyword.merge(context_provider_opts(context_opts), opts))
    end
  end

  defp action_policy_evaluator(provider, _context_opts), do: ProcessProvider.action_policy_evaluator(provider)

  defp context_provider_opts(context_opts) do
    case Keyword.get(context_opts, :source_contract) do
      source_contract when is_map(source_contract) -> [source_contract: source_contract]
      _other -> []
    end
  end

  defp action_policy_provider_for_gates(%{action_policy_provider: Beislid} = gate_selection, %{opts: opts}) do
    provider = if Beislid.action_policy_available?(opts), do: Beislid, else: Native

    gate_selection =
      update_in(gate_selection.metadata, fn metadata ->
        Map.put(metadata, :action_policy_provider, provider_id(provider))
      end)

    {provider, gate_selection}
  end

  defp action_policy_provider_for_gates(gate_selection, context) do
    provider = Map.get(gate_selection, :action_policy_provider, context.process_provider)
    {provider, gate_selection}
  end

  defp maybe_put_source_contract(opts, context_opts) do
    case Keyword.get(context_opts, :source_contract) do
      source_contract when is_map(source_contract) -> Keyword.put(opts, :source_contract, source_contract)
      _other -> opts
    end
  end

  defp annotate_native_fallback(selection, provider_id, reason) do
    warning = %{message: "provider #{provider_id} gate selection failed: #{inspect(reason)}; fell back to native gates"}

    selection
    |> Map.update!(:warnings, &[warning | &1])
    |> Map.update!(:metadata, &Map.merge(&1, %{fallback_from: provider_id, fallback_reason: inspect(reason)}))
  end

  defp provider_id(provider) do
    if function_exported?(provider, :id, 0), do: provider.id(), else: inspect(provider)
  end

  defp gate_execution_id(turn_number) when is_integer(turn_number) and turn_number > 0 do
    "turn-" <> (turn_number |> Integer.to_string() |> String.pad_leading(4, "0"))
  end

  defp gate_execution_id(_turn_number), do: "turn-unknown"

  defp send_gate_update(recipient, %Issue{id: issue_id}, summary)
       when is_pid(recipient) and is_binary(issue_id) and is_map(summary) do
    send(
      recipient,
      {:claude_worker_update, issue_id,
       %{
         event: :gates_completed,
         timestamp: DateTime.utc_now(),
         session_id: nil,
         usage: nil,
         raw: Gates.summary_to_json(summary)
       }}
    )

    :ok
  end

  defp send_gate_update(_recipient, _issue, _summary), do: :ok

  defp gate_error_summary(summary) do
    %{
      status: summary.status,
      failed: Enum.map(summary.results, &Map.take(&1, [:name, :status, :exit_status, :retryable, :environment_failure]))
    }
  end

  defp continue_agent_turns(context, issue, turn_number, effective_run_ref) do
    case continue_with_issue?(issue, context.issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < context.max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} turn=#{turn_number}/#{context.max_turns}")
        do_run_agent_turns(context, refreshed_issue, turn_number + 1, effective_run_ref)

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active")
        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp adapter_module(opts) do
    opts
    |> Keyword.get(:agent_adapter, Config.agent_adapter())
    |> resolve_adapter_module()
  end

  defp resolve_adapter_module(module) when is_atom(module), do: {:ok, module}
  defp resolve_adapter_module("claude_code"), do: {:ok, ClaudeCodeAdapter}
  defp resolve_adapter_module(:claude_code), do: {:ok, ClaudeCodeAdapter}
  defp resolve_adapter_module("pi"), do: {:ok, PiAdapter}
  defp resolve_adapter_module(:pi), do: {:ok, PiAdapter}
  defp resolve_adapter_module(other), do: {:error, {:unsupported_agent_adapter, other}}

  defp process_provider_module(opts) do
    opts
    |> Keyword.get(:process_provider, Config.process_provider_kind())
    |> resolve_process_provider_module()
  end

  defp resolve_process_provider_module("native"), do: {:ok, Rondo.ProcessProvider.Native}
  defp resolve_process_provider_module(:native), do: {:ok, Rondo.ProcessProvider.Native}
  defp resolve_process_provider_module("beislid"), do: {:ok, Rondo.ProcessProvider.Beislid}
  defp resolve_process_provider_module(:beislid), do: {:ok, Rondo.ProcessProvider.Beislid}
  defp resolve_process_provider_module(module) when is_atom(module), do: {:ok, module}
  defp resolve_process_provider_module(other), do: {:error, {:unsupported_process_provider, other}}

  defp preflight_process_provider(Beislid, opts) do
    probe = Beislid.probe(opts)

    cond do
      blocking_probe?(probe) ->
        {:error, {:process_provider_preflight_failed, Beislid.id(), probe}}

      Config.process_provider_required?() and Map.get(probe, :status) != :ok ->
        {:error, {:process_provider_preflight_failed, Beislid.id(), probe}}

      true ->
        :ok
    end
  end

  defp preflight_process_provider(_provider, _opts), do: :ok

  defp blocking_probe?(%{checks: checks}), do: map_size(Map.get(checks, :blocking, %{})) > 0

  defp build_turn_prompt(provider, issue, opts, 1, _max_turns), do: ProcessProvider.prompt(provider, issue, opts)

  defp build_turn_prompt(_provider, _issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous turn completed normally, but the tracker issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this session, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.tracker_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
