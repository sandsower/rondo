defmodule Rondo.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with the configured agent adapter.
  """

  require Logger
  alias Rondo.Agent.Adapter
  alias Rondo.Agent.ClaudeCodeAdapter
  alias Rondo.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, claude_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               :ok <- send_phase_update(claude_update_recipient, issue, :claude_starting),
               :ok <- run_agent_turns(workspace, issue, claude_update_recipient, opts) do
            :ok
          else
            {:error, reason} ->
              Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
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
    with {:ok, adapter} <- adapter_module(opts) do
      context = %{
        workspace: workspace,
        claude_update_recipient: claude_update_recipient,
        opts: opts,
        issue_state_fetcher: Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1),
        adapter: adapter,
        max_turns: Keyword.get(opts, :max_turns, Config.agent_max_turns())
      }

      do_run_agent_turns(context, issue, 1, nil)
    end
  end

  defp do_run_agent_turns(context, issue, turn_number, run_ref) do
    prompt = build_turn_prompt(issue, context.opts, turn_number, context.max_turns)

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

        continue_agent_turns(context, issue, turn_number, effective_run_ref)

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
  defp resolve_adapter_module(other), do: {:error, {:unsupported_agent_adapter, other}}

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
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
