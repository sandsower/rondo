defmodule Rondo.AgentRunner do
  @moduledoc """
  Executes a Linear issue in an isolated workspace.
  """

  require Logger
  alias Rondo.Agent.Adapter
  alias Rondo.Agent.ClaudeCodeAdapter
  alias Rondo.Agent.PiAdapter

  alias Rondo.{
    Config,
    FinalReport,
    Gates,
    Interrupt,
    Linear.Issue,
    ModelRouting,
    ProcessProvider,
    RunLedger,
    Tracker,
    Workspace
  }

  alias Rondo.ProcessProvider.{Beislid, Native}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, claude_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    workspace_opts = workspace_policy_opts(opts)

    case Workspace.create_for_issue(issue, workspace_opts) do
      {:ok, workspace} ->
        with :ok <- Workspace.run_before_run_hook(workspace, issue, workspace_opts),
             :ok <- ensure_workspace_ready(workspace),
             :ok <- send_phase_update(claude_update_recipient, issue, :claude_starting) do
          try do
            case run_agent_turns(workspace, issue, claude_update_recipient, opts) do
              :ok -> :ok
              {:pause, interrupt} -> exit({:final_report_invalid, interrupt})
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

  @doc """
  Sentinel issue-state fetcher for runs without tracker tools (run-once /
  manifest envelope runs). Its function identity signals "no tracker capability"
  to the continuation decision, so these runs never loop on tracker state. Always
  returns `{:ok, []}`.
  """
  @spec no_tracker_issue_state_fetcher([String.t()]) :: {:ok, []}
  def no_tracker_issue_state_fetcher(_issue_ids), do: {:ok, []}

  defp workspace_policy_opts(opts) do
    ledger_opts =
      case Keyword.get(opts, :run_ledger) do
        nil -> []
        ledger -> [ledger: ledger]
      end

    case Keyword.get(opts, :action_policy_policy_file) do
      nil -> ledger_opts
      policy_file -> Keyword.put(ledger_opts, :policy_file, policy_file)
    end
  end

  # Spawn-boundary guard: the agent subprocess launches with the issue workspace
  # as its cwd ({:cd, workspace} in the adapter Port), so the workspace must be a
  # present directory at the moment of spawn. Creation runs earlier, but the
  # before_run hook and concurrent lifecycle actions (e.g. a racing stale-path
  # removal) can leave it absent at the spawn boundary. Verify here and abort with
  # a clear error rather than letting the Port emit a low-level "Could not cd" that
  # only recovers by luck/retry (RON-35).
  defp ensure_workspace_ready(workspace) do
    if File.dir?(workspace) do
      :ok
    else
      {:error, {:workspace_not_ready, workspace}}
    end
  end

  defp handle_agent_run_error(issue, {:action_policy_guidance_required, interrupt}) do
    Logger.warning("Agent run needs guidance for #{issue_context(issue)}: #{inspect(interrupt["blocked_side_effect"])}")
    exit({:action_policy_guidance_required, interrupt})
  end

  defp handle_agent_run_error(issue, {:workspace_not_ready, workspace}) do
    Logger.error("Agent run aborted for #{issue_context(issue)}: workspace not present at spawn boundary: #{workspace}")

    raise RuntimeError,
          "Agent run aborted for #{issue_context(issue)}: workspace #{workspace} was not a directory at spawn time " <>
            "(creation incomplete or workspace removed before launch)"
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
         message: Map.get(event, :message),
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
    with {:ok, provider} <- process_provider_module(opts),
         :ok <- preflight_process_provider(provider, opts),
         {:ok, opts} <- model_routing_opts(provider, opts),
         {:ok, adapter} <- adapter_module(opts),
         {:ok, opts} <- ensure_model_selection_supported(adapter, opts) do
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

      do_run_agent_turns(context, issue, 1, Keyword.get(opts, :initial_run_ref), nil)
    end
  end

  defp model_routing_opts(provider, opts) do
    routing = resolve_model_routing(provider, opts)

    if routing.status == :blocked do
      with {:ok, _opts} <- maybe_record_model_routing(Keyword.put(opts, :model_routing, routing), routing) do
        {:error, {:model_routing_blocked, routing}}
      end
    else
      {:ok, apply_model_routing_opts(opts, routing)}
    end
  end

  defp ensure_model_selection_supported(adapter, opts) do
    routing = Keyword.get(opts, :model_routing)

    if Keyword.has_key?(opts, :model) and model_selection_unsupported?(adapter, opts) do
      handle_unsupported_model_selection(opts, routing, adapter)
    else
      maybe_record_model_routing(opts, routing)
    end
  end

  defp model_selection_unsupported?(adapter, opts) do
    case safe_adapter_probe(adapter, opts) do
      {:ok, %{checks: %{model_selection: :unsupported}}} -> true
      {:ok, %{checks: %{model_selection: :ok}}} -> false
      {:error, _reason} -> true
      _probe -> false
    end
  end

  defp safe_adapter_probe(adapter, opts) do
    {:ok, adapter.probe(opts)}
  rescue
    error -> {:error, error}
  end

  defp handle_unsupported_model_selection(opts, %{mode: :require} = routing, adapter) do
    routing = unsupported_model_selection_routing(routing, adapter, :blocked)

    with {:ok, _opts} <- maybe_record_model_routing(Keyword.put(opts, :model_routing, routing), routing) do
      {:error, {:model_routing_blocked, routing}}
    end
  end

  defp handle_unsupported_model_selection(opts, routing, adapter) when is_map(routing) do
    routing = unsupported_model_selection_routing(routing, adapter, :fallback)
    opts = opts |> Keyword.delete(:model) |> Keyword.put(:model_routing, routing)
    maybe_record_model_routing(opts, routing)
  end

  defp handle_unsupported_model_selection(opts, _routing, _adapter), do: {:ok, opts}

  defp unsupported_model_selection_routing(routing, adapter, status) do
    %{routing | status: status, resolved: nil, reason: "adapter #{adapter.id()} does not support per-run model selection"}
  end

  defp resolve_model_routing(provider, opts) do
    ModelRouting.resolve(
      routing_context: Keyword.get(opts, :model_routing_context, %{stage: :initial_spawn}),
      source_contract: Keyword.get(opts, :source_contract, %{}),
      model_routing_hints: provider.model_routing_hints(opts),
      repo_model_routing: Config.model_routing()
    )
  end

  defp apply_model_routing_opts(opts, routing) do
    opts
    |> Keyword.put(:model_routing, routing)
    |> maybe_put_routed_model(routing)
    |> maybe_put_routed_adapter(routing)
  end

  defp maybe_put_routed_model(opts, %{resolved: %{model: model}}) when is_binary(model), do: Keyword.put(opts, :model, model)
  defp maybe_put_routed_model(opts, _routing), do: opts

  defp maybe_put_routed_adapter(opts, %{resolved: %{adapter: adapter}}) when is_binary(adapter), do: Keyword.put(opts, :agent_adapter, adapter)
  defp maybe_put_routed_adapter(opts, _routing), do: opts

  defp maybe_record_model_routing(opts, routing) do
    case Keyword.get(opts, :run_ledger) do
      %RunLedger{} = ledger ->
        with {:ok, ledger} <- RunLedger.update_agent_metadata(ledger, %{"model_routing" => routing}) do
          {:ok, Keyword.put(opts, :run_ledger, ledger)}
        end

      _ledger ->
        {:ok, opts}
    end
  end

  defp do_run_agent_turns(context, issue, turn_number, run_ref, previous_final_report_fingerprint) do
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
          continue_agent_turns(context, issue, turn_number, effective_run_ref, Map.get(invocation_result, :final_report), previous_final_report_fingerprint)
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

  defp continue_agent_turns(
         context,
         issue,
         turn_number,
         effective_run_ref,
         final_report,
         previous_final_report_fingerprint
       ) do
    analysis = FinalReport.analyze(final_report)

    case continuation_decision(
           context,
           issue,
           analysis,
           turn_number,
           previous_final_report_fingerprint,
           final_report,
           effective_run_ref
         ) do
      {:continue, refreshed_issue, current_final_report_fingerprint} when turn_number < context.max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} turn=#{turn_number}/#{context.max_turns}")

        do_run_agent_turns(
          context,
          refreshed_issue,
          turn_number + 1,
          effective_run_ref,
          current_final_report_fingerprint
        )

      {:continue, refreshed_issue, _current_final_report_fingerprint} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with delivery still incomplete")
        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:pause, interrupt} ->
        {:pause, interrupt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Continuation is delivery-driven. A valid `rondo.final_report/v0` decides
  # directly via its declared `next_state` (terminal -> stop, active -> continue),
  # regardless of tracker state. When the final report is invalid but clearly
  # describes a blocked or terminal state, we pause instead of blindly
  # continuing. Repeated identical/near-identical reports across continuations
  # also pause to avoid loops. Without a usable report we only fall back to
  # tracker-state continuation when the run actually has tracker capability (a
  # real issue_state_fetcher); tracker-less envelope/manifest runs stop instead
  # of looping on an unsatisfiable "issue still active" nudge.
  defp continuation_decision(
         context,
         issue,
         analysis,
         turn_number,
         previous_final_report_fingerprint,
         final_report,
         effective_run_ref
       ) do
    with nil <-
           final_report_unparsed_pause(
             context,
             issue,
             analysis,
             turn_number,
             final_report,
             effective_run_ref
           ),
         nil <-
           final_report_repetition_pause(
             context,
             issue,
             analysis,
             turn_number,
             previous_final_report_fingerprint,
             final_report,
             effective_run_ref
           ) do
      continuation_decision_by_status(context, issue, analysis)
    end
  end

  defp final_report_unparsed_pause(context, issue, analysis, turn_number, final_report, effective_run_ref) do
    case final_report_state_classification(analysis.next_state_hint) do
      :blocked when analysis.status != :valid ->
        {:pause, final_report_interrupt(context, issue, effective_run_ref, analysis, final_report, turn_number, "blocked_state_unparsed")}

      :terminal when analysis.status != :valid ->
        {:pause, final_report_interrupt(context, issue, effective_run_ref, analysis, final_report, turn_number, "terminal_state_unparsed")}

      _other ->
        nil
    end
  end

  defp final_report_repetition_pause(
         context,
         issue,
         analysis,
         turn_number,
         previous_final_report_fingerprint,
         final_report,
         effective_run_ref
       ) do
    if analysis.status != :valid && previous_final_report_fingerprint && final_report_loop_guardable?(final_report) &&
         final_report_loop_guard?(analysis.fingerprint, previous_final_report_fingerprint) do
      {:pause, final_report_interrupt(context, issue, effective_run_ref, analysis, final_report, turn_number, "repeated_final_report")}
    else
      nil
    end
  end

  defp continuation_decision_by_status(context, issue, analysis) do
    case analysis.status do
      :valid -> valid_final_report_continuation(issue, analysis)
      _invalid_or_missing -> invalid_or_missing_final_report_continuation(context, issue, analysis)
    end
  end

  defp valid_final_report_continuation(issue, analysis) do
    if active_issue_state?(Map.get(analysis.report, "next_state")) do
      {:continue, issue, analysis.fingerprint}
    else
      {:done, issue}
    end
  end

  defp invalid_or_missing_final_report_continuation(context, issue, analysis) do
    if tracker_capable?(context) do
      case continue_with_issue?(issue, context.issue_state_fetcher) do
        {:continue, refreshed_issue} -> {:continue, refreshed_issue, analysis.fingerprint}
        other -> other
      end
    else
      {:done, issue}
    end
  end

  defp tracker_capable?(%{issue_state_fetcher: fetcher}) do
    fetcher != (&__MODULE__.no_tracker_issue_state_fetcher/1)
  end

  defp final_report_interrupt(context, issue, effective_run_ref, analysis, final_report, turn_number, classification) do
    Interrupt.final_report_invalid(%{
      issue: issue,
      run_id: Map.get(context, :run_id),
      run_dir: Map.get(context, :run_dir),
      workspace: context.workspace,
      session_id: Map.get(effective_run_ref || %{}, :provider_ref),
      run_ref: effective_run_ref,
      retry_attempt: Keyword.get(Map.get(context, :opts, []), :retry_attempt) || Keyword.get(Map.get(context, :opts, []), :attempt),
      classification: classification,
      final_report_status: Atom.to_string(analysis.status),
      errors: analysis.errors,
      reported_next_state: analysis.next_state_hint,
      continuation_count: max(turn_number - 1, 0),
      fingerprint: analysis.fingerprint,
      excerpt: final_report_excerpt(final_report)
    })
  end

  defp final_report_state_classification(next_state) when is_binary(next_state) do
    normalized_state = normalize_issue_state(next_state)

    cond do
      normalized_state == "blocked" -> :blocked
      active_issue_state?(next_state) -> :active
      terminal_issue_state?(next_state) -> :terminal
      true -> :other
    end
  end

  defp final_report_state_classification(_next_state), do: :other

  defp terminal_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.tracker_terminal_states()
    |> Enum.any?(fn terminal_state -> normalize_issue_state(terminal_state) == normalized_state end)
  end

  defp final_report_loop_guard?(current_fingerprint, previous_fingerprint)
       when is_binary(current_fingerprint) and is_binary(previous_fingerprint) do
    current_fingerprint == previous_fingerprint or
      String.jaro_distance(current_fingerprint, previous_fingerprint) >= 0.97
  end

  defp final_report_loop_guard?(_current_fingerprint, _previous_fingerprint), do: false

  defp final_report_loop_guardable?(report) when is_binary(report), do: String.trim(report) != ""
  defp final_report_loop_guardable?(report), do: not is_nil(report)

  defp final_report_excerpt(report) when is_binary(report) do
    report
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 500)
  end

  defp final_report_excerpt(report) when is_map(report) do
    report
    |> Jason.encode!()
    |> final_report_excerpt()
  end

  defp final_report_excerpt(report), do: inspect(report) |> final_report_excerpt()

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

  defp build_turn_prompt(provider, issue, opts, 1, _max_turns) do
    case opts |> Keyword.get(:operator_guidance) |> normalize_operator_guidance() do
      nil -> ProcessProvider.prompt(provider, issue, opts)
      guidance -> operator_guidance_prompt(guidance)
    end
  end

  defp build_turn_prompt(_provider, _issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous turn completed normally, but the work is not yet complete (your final report did not declare a terminal next_state, or the tracker issue is still active).
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

  defp normalize_operator_guidance(guidance) when is_binary(guidance) do
    case String.trim(guidance) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_operator_guidance(_guidance), do: nil

  defp operator_guidance_prompt(guidance) do
    """
    Operator guidance for paused run:

    #{guidance}

    Resume from the current workspace state and existing agent session. Do not restart the task from scratch.
    Focus only on the work needed to unblock and complete the current ticket.
    """
  end

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
