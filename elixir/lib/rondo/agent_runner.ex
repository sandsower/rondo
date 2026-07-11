defmodule Rondo.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with the configured agent adapter.
  """

  require Logger
  alias Rondo.Agent.Adapter
  alias Rondo.Agent.ChildHome
  alias Rondo.Agent.ChildLaunchPolicy
  alias Rondo.Agent.ClaudeCodeAdapter
  alias Rondo.Agent.CodexAdapter
  alias Rondo.Agent.PiAdapter

  alias Rondo.{
    ChangedFiles,
    Config,
    FinalReport,
    Gates,
    Interrupt,
    ModelRouting,
    ProcessProvider,
    RunDecision,
    RunLedger,
    SideEffectPolicy,
    Tracker,
    Workspace
  }

  alias Rondo.Linear.Issue
  alias Rondo.ProcessProvider.{Beislid, Native}
  alias Rondo.Tracker.TerminalState
  alias Rondo.Tracker.UpdateDetector

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
              {:error, reason} -> handle_agent_run_error(issue, reason, claude_update_recipient, opts)
            end
          after
            Workspace.run_after_run_hook(workspace, issue, workspace_opts)
          end
        else
          {:error, reason} ->
            handle_agent_run_error(issue, reason, claude_update_recipient, opts)
        end

      {:error, reason} ->
        handle_agent_run_error(issue, reason, claude_update_recipient, opts)
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

  @doc false
  @spec no_tracker_issue_context_fetcher([String.t()]) :: {:ok, []}
  def no_tracker_issue_context_fetcher(_issue_ids), do: {:ok, []}

  defp workspace_policy_opts(opts) do
    ledger_opts =
      case Keyword.get(opts, :run_ledger) do
        nil -> []
        ledger -> [ledger: ledger]
      end

    ledger_opts =
      case Keyword.get(opts, :action_policy_policy_file) do
        nil -> ledger_opts
        policy_file -> Keyword.put(ledger_opts, :policy_file, policy_file)
      end

    if Keyword.get(opts, :fresh_workspace, false) do
      Keyword.put(ledger_opts, :fresh, true)
    else
      ledger_opts
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

  defp handle_agent_run_error(issue, {:action_policy_guidance_required, interrupt}, recipient, opts) do
    Logger.warning("Agent run needs guidance for #{issue_context(issue)}: #{inspect(interrupt["blocked_side_effect"])}")

    dispatch_run_decision(
      recipient,
      issue,
      :pause,
      "action_policy_guidance_required",
      "pause because action-policy guidance is required",
      action_policy_guidance_run_decision_opts(issue, interrupt, opts)
    )

    exit({:action_policy_guidance_required, interrupt})
  end

  defp handle_agent_run_error(issue, {:action_policy_denied, envelope}, _recipient, _opts) when is_map(envelope) do
    Logger.warning("Agent run stopped for #{issue_context(issue)}: action policy denied")
    exit({:action_policy_denied, envelope})
  end

  defp handle_agent_run_error(issue, {kind, payload} = reason, _recipient, _opts)
       when kind in [:process_provider_failed, :process_provider_required_failed] and is_map(payload) do
    Logger.error("Agent run failed for #{issue_context(issue)}: #{Map.get(payload, :message) || inspect(reason)}")
    exit(reason)
  end

  defp handle_agent_run_error(issue, {:workspace_not_ready, workspace}, _recipient, _opts) do
    Logger.error("Agent run aborted for #{issue_context(issue)}: workspace not present at spawn boundary: #{workspace}")

    raise RuntimeError,
          "Agent run aborted for #{issue_context(issue)}: workspace #{workspace} was not a directory at spawn time " <>
            "(creation incomplete or workspace removed before launch)"
  end

  defp handle_agent_run_error(issue, {:model_routing_exhausted, interrupt}, recipient, opts) when is_map(interrupt) do
    Logger.warning("Agent run paused for #{issue_context(issue)}: model routing candidates exhausted")

    dispatch_run_decision(
      recipient,
      issue,
      :pause,
      "model_routing_exhausted",
      "pause because model routing candidates are exhausted",
      model_routing_exhausted_run_decision_opts(issue, interrupt, opts)
    )

    exit({:model_routing_exhausted, interrupt})
  end

  defp handle_agent_run_error(issue, reason, _recipient, _opts) do
    Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
    raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
  end

  defp claude_event_handler(recipient, issue, completion_ref \\ nil, failure_hint_ref \\ nil) do
    fn event ->
      if Map.get(event, :event_type) == :invocation_completed and is_reference(completion_ref) do
        Process.put(completion_ref, true)
      end

      maybe_record_provider_exhaustion_hint(failure_hint_ref, event)
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
         payload: Map.get(event, :payload),
         decision_kind: Map.get(event, :decision_kind),
         reason_code: Map.get(event, :reason_code),
         summary: Map.get(event, :summary),
         input_signals: Map.get(event, :input_signals),
         evidence: Map.get(event, :evidence),
         turn_number: Map.get(event, :turn_number),
         retry_attempt: Map.get(event, :retry_attempt),
         capabilities: Map.get(event, :capabilities),
         final_report: Map.get(event, :final_report),
         diff_source: Map.get(event, :diff_source),
         model_routing: Map.get(event, :model_routing),
         source: Map.get(event, :source),
         raw: compatibility_raw(event)
       }}
    )

    :ok
  end

  defp send_claude_update(_recipient, _issue, _event), do: :ok

  defp dispatch_model_routing_decision(recipient, issue, routing, source) do
    send_claude_update(recipient, issue, %{
      event: :model_routing_decision,
      method: "model_routing_decision",
      message: Map.get(routing, :reason),
      model_routing: routing,
      source: source
    })
  end

  defp invoke_turn_with_model_fallback(turn_context, issue, turn_number, run_ref) do
    routing = Keyword.get(turn_context.opts, :model_routing, %{})
    routing_context = Keyword.get(turn_context.opts, :model_routing_context, %{})
    candidates = Map.get(routing, :candidates, []) || []

    run_state = %{
      routing: routing,
      routing_context: routing_context,
      run_ref: run_ref,
      turn_number: turn_number
    }

    case candidates do
      [] -> invoke_current_model_routing_selection(turn_context, issue, run_state)
      _candidates -> invoke_model_routing_candidate(turn_context, issue, run_state, candidates, nil, 1)
    end
  end

  defp invoke_current_model_routing_selection(turn_context, issue, run_state) do
    source = model_routing_source(provider_id(turn_context.adapter), run_state.routing_context, run_state.turn_number)
    :ok = dispatch_model_routing_decision(turn_context.claude_update_recipient, issue, run_state.routing, source)

    prompt =
      build_turn_prompt(
        turn_context.process_provider,
        issue,
        turn_context.opts,
        run_state.turn_number,
        turn_context.max_turns
      )

    completion_ref = make_ref()
    Process.put(completion_ref, false)

    result =
      invoke_adapter_with_child_policy(
        turn_context.adapter,
        prompt,
        turn_context.workspace,
        run_state.run_ref,
        claude_event_handler(turn_context.claude_update_recipient, issue, completion_ref),
        turn_context.opts
      )

    completion_observed? = Process.get(completion_ref, false)
    Process.delete(completion_ref)

    case result do
      {:ok, %{run_ref: _} = invocation_result} -> {:ok, turn_context, completion_observed?, invocation_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke_model_routing_candidate(turn_context, issue, run_state, [candidate | rest], fallback_info, attempt_number) do
    attempt_routing = build_model_routing_attempt(run_state.routing, candidate, fallback_info)
    attempt_opts = apply_model_routing_opts(turn_context.opts, attempt_routing)
    attempt_adapter = attempt_adapter_module(turn_context.adapter, attempt_opts)

    case model_selection_attempt(attempt_adapter, attempt_opts, attempt_routing) do
      {:ok, attempt_opts, attempt_routing} ->
        invoke_model_routing_candidate_attempt(
          turn_context,
          issue,
          run_state,
          {attempt_adapter, attempt_opts, attempt_routing},
          {candidate, rest, attempt_number}
        )

      {:error, blocked_routing} ->
        source = model_routing_source(provider_id(attempt_adapter), run_state.routing_context, run_state.turn_number)
        :ok = dispatch_model_routing_decision(turn_context.claude_update_recipient, issue, blocked_routing, source)
        {:error, {:model_routing_blocked, blocked_routing}}
    end
  end

  defp invoke_model_routing_candidate_attempt(
         turn_context,
         issue,
         run_state,
         {attempt_adapter, attempt_opts, attempt_routing},
         {candidate, rest, attempt_number}
       ) do
    attempt_context = %{turn_context | adapter: attempt_adapter, opts: attempt_opts}
    source = model_routing_source(provider_id(attempt_adapter), run_state.routing_context, run_state.turn_number)

    :ok = dispatch_model_routing_decision(turn_context.claude_update_recipient, issue, attempt_routing, source)

    prompt =
      build_turn_prompt(
        attempt_context.process_provider,
        issue,
        attempt_opts,
        run_state.turn_number,
        attempt_context.max_turns
      )

    completion_ref = make_ref()
    failure_hint_ref = make_ref()

    Process.put(completion_ref, false)
    Process.put(failure_hint_ref, nil)

    result =
      invoke_adapter_with_child_policy(
        attempt_adapter,
        prompt,
        attempt_context.workspace,
        compatible_previous_run_ref(run_state.run_ref, attempt_adapter),
        claude_event_handler(turn_context.claude_update_recipient, issue, completion_ref, failure_hint_ref),
        attempt_opts
      )

    attempt_state = %{
      attempt_number: attempt_number,
      candidate: candidate,
      completion_observed?: Process.get(completion_ref, false),
      failure_hint: Process.get(failure_hint_ref),
      rest: rest,
      source: source
    }

    Process.delete(completion_ref)
    Process.delete(failure_hint_ref)
    handle_model_routing_result(result, attempt_context, turn_context, issue, run_state, attempt_state)
  end

  defp model_selection_attempt(attempt_adapter, attempt_opts, %{mode: :require} = attempt_routing) do
    if model_selection_unsupported?(attempt_adapter, attempt_opts) do
      {:error, unsupported_model_selection_routing(attempt_routing, attempt_adapter, :blocked)}
    else
      {:ok, attempt_opts, attempt_routing}
    end
  end

  defp model_selection_attempt(attempt_adapter, attempt_opts, attempt_routing) do
    if model_selection_unsupported?(attempt_adapter, attempt_opts) do
      attempt_opts = attempt_opts |> Keyword.delete(:model) |> Keyword.delete(:agent_adapter)
      attempt_routing = unsupported_model_selection_routing(attempt_routing, attempt_adapter, :fallback)
      {:ok, Keyword.put(attempt_opts, :model_routing, attempt_routing), attempt_routing}
    else
      {:ok, attempt_opts, attempt_routing}
    end
  end

  defp invoke_adapter_with_child_policy(adapter, prompt, workspace, previous_run_ref, on_event, opts) do
    if child_launch_policy_required?(adapter, opts) do
      with {:ok, envelope} <- resolve_child_launch_policy(adapter, opts, on_event),
           :ok <- ChildHome.prepare(envelope) do
        adapter.invoke(%{
          prompt: prompt,
          workspace: workspace,
          previous_run_ref: previous_run_ref,
          on_event: on_event,
          opts: Keyword.put(opts, :child_launch_envelope, envelope)
        })
      else
        {:block, envelope} ->
          {:error, {:child_launch_blocked, ChildLaunchPolicy.sanitize(envelope)}}

        {:error, reason} ->
          {:error, {:child_home_prepare_failed, reason}}
      end
    else
      adapter.invoke(%{
        prompt: prompt,
        workspace: workspace,
        previous_run_ref: previous_run_ref,
        on_event: on_event,
        opts: opts
      })
    end
  end

  defp child_launch_policy_required?(adapter, opts) do
    adapter.id() in ["claude_code", "codex", "pi"] and
      (match?(%RunLedger{}, Keyword.get(opts, :run_ledger)) or
         Keyword.get(opts, :enforce_child_launch_policy, false))
  end

  defp resolve_child_launch_policy(adapter, opts, on_event) do
    run_dir =
      Keyword.get(opts, :run_dir) ||
        case Keyword.get(opts, :run_ledger) do
          %RunLedger{run_dir: run_dir} -> run_dir
          _other -> nil
        end

    result =
      ChildLaunchPolicy.resolve(
        run_mode: Config.action_policy_run_mode(),
        dispatch_origin: Keyword.get(opts, :dispatch_origin, :daemon),
        unsafe_bypass: Keyword.get(opts, :unsafe_child_credential_bypass, false),
        adapter: adapter.id(),
        model: Keyword.get(opts, :model),
        isolation_baseline:
          Keyword.get(
            opts,
            :child_isolation_baseline,
            Application.get_env(:rondo, :child_isolation_baseline, :env_home_scoped)
          ),
        run_dir: run_dir,
        source_contract: Keyword.get(opts, :source_contract, %{}),
        provider_auth_env_names: Keyword.get(opts, :provider_auth_env_names)
      )

    envelope = elem(result, 1)

    case persist_child_launch_policy(opts, envelope) do
      :ok ->
        emit_child_launch_policy(on_event, envelope)
        result

      {:error, reason} ->
        {:error, {:child_launch_evidence_write_failed, reason}}
    end
  end

  defp persist_child_launch_policy(opts, envelope) do
    evidence = ChildLaunchPolicy.sanitize(envelope)

    case Keyword.get(opts, :run_ledger) do
      %RunLedger{} = ledger ->
        case RunLedger.record_child_launch_policy(ledger, evidence) do
          {:ok, _ledger} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :missing_run_ledger}
    end
  end

  defp emit_child_launch_policy(on_event, envelope) when is_function(on_event, 1) do
    evidence = ChildLaunchPolicy.sanitize(envelope)

    on_event.(%{
      event_type: :child_launch_policy_resolved,
      adapter: envelope.adapter,
      capabilities: %{child_launch: evidence},
      evidence: evidence,
      raw: %{event_type: :child_launch_policy_resolved, evidence: evidence}
    })

    :ok
  end

  defp handle_model_routing_result(
         {:ok, %{run_ref: _} = invocation_result},
         attempt_context,
         _turn_context,
         _issue,
         _run_state,
         attempt_state
       ) do
    {:ok, attempt_context, attempt_state.completion_observed?, invocation_result}
  end

  defp handle_model_routing_result({:error, reason}, attempt_context, turn_context, issue, run_state, attempt_state) do
    case provider_exhaustion_context(reason, attempt_state.failure_hint) do
      nil ->
        {:error, reason}

      failure_context ->
        handle_provider_exhaustion(
          failure_context,
          reason,
          attempt_context,
          turn_context,
          issue,
          run_state,
          attempt_state
        )
    end
  end

  defp handle_provider_exhaustion(failure_context, reason, attempt_context, turn_context, issue, run_state, attempt_state) do
    case attempt_state.rest do
      [] ->
        exhausted_info =
          build_model_routing_exhausted_info(
            attempt_state.candidate,
            failure_context,
            run_state.turn_number,
            attempt_state.attempt_number
          )

        exhausted_routing = build_model_routing_attempt(run_state.routing, attempt_state.candidate, exhausted_info)

        :ok =
          dispatch_model_routing_decision(
            turn_context.claude_update_recipient,
            issue,
            exhausted_routing,
            attempt_state.source
          )

        interrupt =
          model_routing_exhaustion_interrupt(
            attempt_context,
            issue,
            run_state.turn_number,
            exhausted_info,
            reason
          )

        {:error, {:model_routing_exhausted, interrupt}}

      [next_candidate | remaining] ->
        next_attempt_number = attempt_state.attempt_number + 1

        next_fallback_info =
          build_model_routing_transition_info(
            attempt_state.candidate,
            next_candidate,
            failure_context,
            run_state.turn_number,
            attempt_state.attempt_number,
            next_attempt_number
          )

        invoke_model_routing_candidate(
          turn_context,
          issue,
          run_state,
          [next_candidate | remaining],
          next_fallback_info,
          next_attempt_number
        )
    end
  end

  defp build_model_routing_attempt(routing, candidate, nil) do
    routing
    |> Map.put(:resolved, candidate)
    |> Map.put(:status, Map.get(routing, :status, :honored))
  end

  defp build_model_routing_attempt(routing, candidate, fallback_info) when is_map(fallback_info) do
    routing
    |> Map.put(:resolved, candidate)
    |> Map.put(:status, :fallback)
    |> Map.put(:reason, model_routing_fallback_reason(candidate, fallback_info))
    |> Map.put(:fallback, fallback_info)
  end

  defp build_model_routing_transition_info(failed_candidate, next_candidate, failure_context, turn_number, failed_attempt_number, next_attempt_number) do
    %{
      failed_candidate: sanitize_model_candidate(failed_candidate),
      next_candidate: sanitize_model_candidate(next_candidate),
      failed_attempt_number: failed_attempt_number,
      attempt_number: next_attempt_number,
      failure_class: failure_context.class,
      failure_reason: failure_context.reason,
      turn_number: turn_number,
      exhausted: false
    }
  end

  defp build_model_routing_exhausted_info(failed_candidate, failure_context, turn_number, failed_attempt_number) do
    %{
      failed_candidate: sanitize_model_candidate(failed_candidate),
      next_candidate: nil,
      failed_attempt_number: failed_attempt_number,
      attempt_number: failed_attempt_number,
      failure_class: failure_context.class,
      failure_reason: failure_context.reason,
      turn_number: turn_number,
      exhausted: true
    }
  end

  defp model_routing_fallback_reason(candidate, %{
         failed_candidate: failed_candidate,
         failure_class: failure_class,
         failure_reason: failure_reason,
         turn_number: turn_number,
         attempt_number: attempt_number,
         exhausted: true
       }) do
    candidate_label = ModelRouting.candidate_label(candidate)
    failed_label = ModelRouting.candidate_label(failed_candidate)

    "fallback exhausted after #{candidate_label} on turn #{turn_number} attempt #{attempt_number} " <>
      "following #{failed_label} #{failure_class}: #{failure_reason}"
  end

  defp model_routing_fallback_reason(candidate, %{
         failed_candidate: failed_candidate,
         failure_class: failure_class,
         failure_reason: failure_reason,
         turn_number: turn_number,
         attempt_number: attempt_number
       }) do
    candidate_label = ModelRouting.candidate_label(candidate)
    failed_label = ModelRouting.candidate_label(failed_candidate)

    "fallback from #{failed_label} to #{candidate_label} after #{failure_class} " <>
      "on turn #{turn_number} attempt #{attempt_number}: #{failure_reason}"
  end

  defp provider_exhaustion_context(_reason, %{class: class, reason: reason}) when is_binary(reason) do
    %{class: normalize_failure_class(class), reason: reason}
  end

  defp provider_exhaustion_context(reason, failure_hint) do
    Enum.find_value([failure_hint, reason], &exhaustion_context_from_term/1)
  end

  defp provider_exhaustion_hint(%{event_type: event_type} = event)
       when event_type in [
              :warning,
              :assistant_message,
              :invocation_failed,
              :turn_failed,
              :startup_failed,
              :turn_ended_with_error
            ] do
    [Map.get(event, :message), Map.get(event, "message"), Map.get(event, :raw), event]
    |> Enum.find_value(&exhaustion_context_from_term/1)
  end

  defp provider_exhaustion_hint(_event), do: nil

  defp extract_failure_text(term) when is_binary(term) do
    text = String.trim(term)

    if text == "", do: nil, else: text
  end

  defp extract_failure_text(term) when is_list(term) do
    Enum.find_value(term, &extract_failure_text/1)
  end

  defp extract_failure_text(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> extract_failure_text()
  end

  defp extract_failure_text(%{} = map) do
    [
      event_map_value(map, :message),
      event_map_value(map, :reason),
      event_map_value(map, :error),
      event_map_value(map, :failure_hint),
      event_map_value(map, :failure_lines),
      event_map_value(map, :output),
      event_map_value(map, :details),
      inspect(map)
    ]
    |> Enum.find_value(&extract_failure_text/1)
  end

  defp extract_failure_text(_term), do: nil

  defp exhaustion_context_from_term(term) do
    with text when is_binary(text) <- extract_failure_text(term),
         class when is_binary(class) <- classify_provider_exhaustion_text(text) do
      %{class: class, reason: text}
    else
      _other -> nil
    end
  end

  defp classify_provider_exhaustion_text(text) when is_binary(text) do
    normalized = String.downcase(text)

    cond do
      contains_any?(normalized, ["usage limit has been reached", "usage limit exceeded"]) ->
        "usage_limit"

      rate_limit_text?(normalized) ->
        "rate_limit"

      limited_resource_text?(normalized, "quota", ["exhausted", "exceeded", "reached"]) ->
        "quota_limit"

      contains_any?(normalized, credit_limit_phrases()) ->
        "credit_limit"

      limited_resource_text?(normalized, "subscription", ["expired", "exhausted", "reached"]) ->
        "subscription_limit"

      true ->
        nil
    end
  end

  defp rate_limit_text?(text) do
    String.contains?(text, "rate limited") or
      limited_resource_text?(text, "rate limit", ["exceeded", "exhausted", "reached", "429"])
  end

  defp limited_resource_text?(text, resource, markers) do
    String.contains?(text, resource) and contains_any?(text, markers)
  end

  defp contains_any?(text, markers) do
    Enum.any?(markers, &String.contains?(text, &1))
  end

  defp credit_limit_phrases do
    [
      "insufficient credits",
      "no credits",
      "credit exhausted",
      "credits depleted",
      "credit limit reached",
      "credit limit has been reached"
    ]
  end

  defp normalize_failure_class(class) when is_atom(class), do: Atom.to_string(class)
  defp normalize_failure_class(class) when is_binary(class), do: class
  defp normalize_failure_class(class), do: to_string(class)

  defp event_map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp event_map_value(_map, _key), do: nil

  defp compatible_previous_run_ref(%{adapter: adapter} = run_ref, attempt_adapter) when is_binary(adapter) do
    if adapter == provider_id(attempt_adapter), do: run_ref, else: nil
  end

  defp compatible_previous_run_ref(_run_ref, _attempt_adapter), do: nil

  defp attempt_adapter_module(current_adapter, attempt_opts) do
    case Keyword.get(attempt_opts, :agent_adapter) do
      nil ->
        current_adapter

      adapter ->
        case resolve_adapter_module(adapter) do
          {:ok, module} -> module
          {:error, _reason} -> current_adapter
        end
    end
  end

  defp sanitize_model_candidate(nil), do: nil
  defp sanitize_model_candidate(candidate) when is_map(candidate), do: Map.take(candidate, [:adapter, :model])
  defp sanitize_model_candidate(_candidate), do: nil

  defp model_routing_exhaustion_interrupt(attempt_context, issue, turn_number, exhausted_info, reason) do
    %{
      "reason" => "model_routing_exhausted",
      "question" => "Configured model candidates were exhausted after provider quota or rate-limit failures. Should Rondo pause and wait, or change routing?",
      "issue" => %{"id" => issue.id, "identifier" => issue.identifier, "title" => issue.title},
      "run_id" => Map.get(attempt_context, :run_id),
      "run_dir" => Map.get(attempt_context, :run_dir),
      "workspace" => attempt_context.workspace,
      "turn_number" => turn_number,
      "failed_candidate" => Map.get(exhausted_info, :failed_candidate),
      "failure_class" => Map.get(exhausted_info, :failure_class),
      "failure_reason" => Map.get(exhausted_info, :failure_reason),
      "attempt_number" => Map.get(exhausted_info, :attempt_number),
      "exhausted" => true,
      "reason_detail" => inspect(reason)
    }
  end

  defp compatibility_event_type(event) when is_map(event) do
    raw_event_type = get_in(event, [:raw, :event_type])
    event_type = Map.get(event, :event_type)
    event_name = Map.get(event, :event)

    cond do
      is_atom(raw_event_type) and not is_nil(raw_event_type) -> raw_event_type
      is_atom(event_type) and not is_nil(event_type) -> event_type
      is_atom(event_name) and not is_nil(event_name) -> event_name
      true -> :unknown
    end
  end

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

  defp maybe_record_provider_exhaustion_hint(nil, _event), do: :ok

  defp maybe_record_provider_exhaustion_hint(failure_hint_ref, event) when is_reference(failure_hint_ref) do
    case Process.get(failure_hint_ref) do
      nil ->
        case provider_exhaustion_hint(event) do
          nil -> :ok
          hint -> Process.put(failure_hint_ref, hint)
        end

      _existing ->
        :ok
    end
  end

  defp run_agent_turns(workspace, issue, claude_update_recipient, opts) do
    with {:ok, provider} <- process_provider_module(opts),
         :ok <- preflight_process_provider(provider, opts),
         {:ok, opts} <- model_routing_opts(provider, nil, issue, claude_update_recipient, opts, 1),
         {:ok, adapter} <- adapter_module(opts),
         {:ok, opts} <- ensure_model_selection_supported(adapter, issue, claude_update_recipient, opts, 1) do
      {trackerless?, issue_state_fetcher, issue_context_fetcher} = tracker_fetchers(opts)

      issue_context_snapshot =
        if trackerless? do
          UpdateDetector.snapshot_from_issue(issue)
        else
          initial_issue_context_snapshot(issue, issue_context_fetcher)
        end

      run_dir =
        case Keyword.get(opts, :run_dir) do
          nil -> run_ledger_dir(Keyword.get(opts, :run_ledger))
          dir -> dir
        end

      context = %{
        workspace: workspace,
        claude_update_recipient: claude_update_recipient,
        opts: opts,
        issue_state_fetcher: issue_state_fetcher,
        issue_context_fetcher: issue_context_fetcher,
        issue_context_snapshot: issue_context_snapshot,
        trackerless: trackerless?,
        adapter: adapter,
        process_provider: provider,
        max_turns: Keyword.get(opts, :max_turns, Config.agent_max_turns()),
        gates: Keyword.get(opts, :gates),
        run_dir: run_dir
      }

      do_run_agent_turns(context, issue, 1, Keyword.get(opts, :initial_run_ref))
    end
  end

  defp model_routing_opts(provider, current_adapter, issue, claude_update_recipient, opts, turn_number) do
    routing_context = model_routing_context_for_turn(opts, turn_number)
    base_opts = model_routing_base_opts(opts, routing_context)
    routing = resolve_model_routing(provider, base_opts)
    routing = maybe_bound_model_routing_to_adapter(routing, current_adapter)
    source = model_routing_source(provider_id(provider), routing_context, turn_number)

    if routing.status == :blocked do
      dispatch_model_routing_decision(claude_update_recipient, issue, routing, source)
      {:error, {:model_routing_blocked, routing}}
    else
      {:ok, apply_model_routing_opts(base_opts, routing)}
    end
  end

  defp ensure_model_selection_supported(adapter, issue, claude_update_recipient, opts, turn_number) do
    routing = Keyword.get(opts, :model_routing)
    routing_context = Keyword.get(opts, :model_routing_context, %{})
    source = model_routing_source(provider_id(adapter), routing_context, turn_number)

    if Keyword.has_key?(opts, :model) and model_selection_unsupported?(adapter, opts) do
      handle_unsupported_model_selection(opts, routing, adapter, claude_update_recipient, issue, source)
    else
      {:ok, opts}
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

  defp handle_unsupported_model_selection(_opts, %{mode: :require} = routing, adapter, claude_update_recipient, issue, source) do
    routing = unsupported_model_selection_routing(routing, adapter, :blocked)
    dispatch_model_routing_decision(claude_update_recipient, issue, routing, source)
    {:error, {:model_routing_blocked, routing}}
  end

  defp handle_unsupported_model_selection(opts, routing, adapter, _claude_update_recipient, _issue, _source) when is_map(routing) do
    routing = unsupported_model_selection_routing(routing, adapter, :fallback)
    opts = opts |> Keyword.delete(:model) |> Keyword.delete(:agent_adapter) |> Keyword.put(:model_routing, routing)
    {:ok, opts}
  end

  defp handle_unsupported_model_selection(opts, _routing, _adapter, _claude_update_recipient, _issue, _source), do: {:ok, opts}

  defp unsupported_model_selection_routing(routing, adapter, status) do
    %{routing | status: status, resolved: nil, reason: "adapter #{adapter.id()} does not support per-run model selection"}
  end

  defp resolve_model_routing(provider, opts) do
    ModelRouting.resolve(
      routing_context: Keyword.get(opts, :model_routing_context, %{stage: :initial_spawn, phase: :planning}),
      source_contract: Keyword.get(opts, :source_contract, %{}),
      model_routing_hints: runtime_model_routing_hints(provider, opts),
      repo_model_routing: Config.model_routing()
    )
  end

  defp runtime_model_routing_hints(provider, opts) do
    provider.model_routing_hints(opts)
    |> merge_runtime_model_routing_hints(Keyword.get(opts, :runtime_model_routing_hints, %{}))
  end

  defp merge_runtime_model_routing_hints(provider_hints, runtime_hints) when is_map(provider_hints) and is_map(runtime_hints) do
    Map.merge(provider_hints, runtime_hints)
  end

  defp merge_runtime_model_routing_hints(provider_hints, _runtime_hints) when is_map(provider_hints), do: provider_hints
  defp merge_runtime_model_routing_hints(_provider_hints, runtime_hints) when is_map(runtime_hints), do: runtime_hints
  defp merge_runtime_model_routing_hints(_provider_hints, _runtime_hints), do: %{}

  defp model_routing_context_for_turn(opts, turn_number) do
    context =
      case Keyword.get(opts, :model_routing_context) do
        %{} = routing_context -> routing_context
        _ -> %{}
      end

    initial_spawn? =
      turn_number == 1 and
        is_nil(Keyword.get(opts, :initial_run_ref)) and
        is_nil(Keyword.get(opts, :operator_guidance))

    if initial_spawn? do
      context
      |> Map.put_new(:stage, :initial_spawn)
      |> maybe_put_default_planning_phase()
    else
      context
      |> Map.put(:stage, :turn)
      |> Map.put_new(:phase, "implementation")
    end
  end

  defp maybe_put_default_planning_phase(context) do
    if phase_separation_enabled?() do
      Map.put_new(context, :phase, "planning")
    else
      context
    end
  end

  defp phase_separation_enabled? do
    tiers = Config.model_routing() |> Map.get(:tiers, %{})
    (configured_tier?(tiers, :frontier) or configured_tier?(tiers, :heavy)) and configured_tier?(tiers, :standard)
  end

  defp configured_tier?(tiers, tier) when is_map(tiers) do
    case Map.get(tiers, tier) || Map.get(tiers, Atom.to_string(tier)) do
      values when is_list(values) -> values != []
      _other -> false
    end
  end

  defp configured_tier?(_tiers, _tier), do: false

  defp planning_phase?(%{opts: opts}) when is_list(opts), do: planning_phase?(Keyword.get(opts, :model_routing_context, %{}))
  defp planning_phase?(%{phase: phase}), do: normalize_phase(phase) in ["planning", "context_discovery"]
  defp planning_phase?(%{"phase" => phase}), do: normalize_phase(phase) in ["planning", "context_discovery"]
  defp planning_phase?(_context), do: false

  defp normalize_phase(phase) when is_atom(phase), do: phase |> Atom.to_string() |> normalize_phase()
  defp normalize_phase(phase) when is_binary(phase), do: phase |> String.trim() |> String.downcase() |> String.replace(~r/[-\s]+/, "_")
  defp normalize_phase(_phase), do: nil

  defp model_routing_source(source, routing_context, turn_number) do
    [
      source: source,
      stage: Map.get(routing_context, :stage) || Map.get(routing_context, "stage"),
      skill: Map.get(routing_context, :skill) || Map.get(routing_context, "skill"),
      phase: Map.get(routing_context, :phase) || Map.get(routing_context, "phase"),
      step: Map.get(routing_context, :step) || Map.get(routing_context, "step"),
      turn_number: turn_number
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp model_routing_base_opts(opts, routing_context) do
    opts
    |> maybe_clear_routed_model_state()
    |> Keyword.put(:model_routing_context, routing_context)
  end

  defp maybe_bound_model_routing_to_adapter(%{resolved: %{adapter: desired_adapter}} = routing, current_adapter)
       when is_binary(desired_adapter) and not is_nil(current_adapter) do
    current_adapter_id = provider_id(current_adapter)

    if current_adapter_id == desired_adapter do
      routing
    else
      status = if routing.mode == :require, do: :blocked, else: :fallback

      %{
        routing
        | status: status,
          resolved: nil,
          reason: "model routing requested adapter #{desired_adapter} but active adapter #{current_adapter_id} cannot switch mid-run"
      }
    end
  end

  defp maybe_bound_model_routing_to_adapter(routing, _current_adapter), do: routing

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

  defp maybe_clear_routed_model_state(opts) do
    if Keyword.has_key?(opts, :model_routing) do
      opts
      |> Keyword.delete(:model)
      |> Keyword.delete(:agent_adapter)
    else
      opts
    end
  end

  # credo:disable-for-next-line
  defp do_run_agent_turns(context, issue, turn_number, run_ref, previous_final_report_fingerprint \\ nil) do
    case maybe_continue_with_live_update(context, issue, :continue) do
      {:continue, refreshed_issue, next_context} ->
        run_active_agent_turn(next_context, refreshed_issue, turn_number, run_ref, previous_final_report_fingerprint)

      {:terminal, refreshed_issue, next_context} ->
        stop_for_tracker_state(next_context, refreshed_issue, turn_number, run_ref, :terminal, :pre_turn)

      {:inactive, refreshed_issue, next_context} ->
        stop_for_tracker_state(next_context, refreshed_issue, turn_number, run_ref, :inactive, :pre_turn)

      {:missing, refreshed_issue, next_context} ->
        # credo:disable-for-next-line
        stop_for_tracker_state(next_context, refreshed_issue, turn_number, run_ref, :missing, :pre_turn)

      {:pause, interrupt, _next_context} ->
        {:pause, interrupt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_active_agent_turn(context, issue, turn_number, run_ref, previous_final_report_fingerprint) do
    with {:ok, turn_opts} <-
           model_routing_opts(
             context.process_provider,
             context.adapter,
             issue,
             context.claude_update_recipient,
             context.opts,
             turn_number
           ),
         {:ok, turn_opts} <-
           ensure_model_selection_supported(
             context.adapter,
             issue,
             context.claude_update_recipient,
             turn_opts,
             turn_number
           ),
         turn_context = %{context | opts: turn_opts},
         {:ok, turn_context, completion_observed?, invocation_result} <-
           invoke_turn_with_model_fallback(turn_context, issue, turn_number, run_ref) do
      handle_invocation_result(
        turn_context,
        issue,
        turn_number,
        run_ref,
        previous_final_report_fingerprint,
        completion_observed?,
        invocation_result
      )
    end
  end

  defp handle_invocation_result(
         turn_context,
         issue,
         turn_number,
         run_ref,
         previous_final_report_fingerprint,
         completion_observed?,
         %{run_ref: new_run_ref} = invocation_result
       ) do
    effective_run_ref = new_run_ref || run_ref
    provider_ref = if effective_run_ref, do: Map.get(effective_run_ref, :provider_ref)

    Logger.info(
      "Completed agent turn for #{issue_context(issue)} adapter=#{turn_context.adapter.id()} " <>
        "provider_ref=#{provider_ref} workspace=#{turn_context.workspace} turn=#{turn_number}/#{turn_context.max_turns}"
    )

    maybe_send_invocation_result_update(
      turn_context.claude_update_recipient,
      issue,
      turn_context.adapter,
      invocation_result,
      completion_observed?
    )

    with :ok <- run_gates_for_phase(turn_context, issue, turn_number) do
      continue_agent_turns(
        clear_live_update_prompt(turn_context),
        issue,
        turn_number,
        effective_run_ref,
        Map.get(invocation_result, :final_report),
        previous_final_report_fingerprint
      )
    end
  end

  defp run_gates_for_phase(turn_context, issue, turn_number) do
    if planning_phase?(turn_context) do
      :ok
    else
      run_gates(turn_context, issue, turn_number)
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

  defp run_ledger_dir(%{run_dir: run_dir}), do: run_dir
  defp run_ledger_dir(_nil_or_other), do: nil

  defp run_selected_gates(%{run_dir: nil}, _issue, _turn_number, %{gates: []}), do: :ok

  defp run_selected_gates(%{run_dir: nil}, _issue, _turn_number, _gate_selection), do: {:error, :missing_run_ledger_for_gates}

  defp run_selected_gates(context, issue, turn_number, gate_selection) do
    with {:ok, action_policy_provider, gate_selection} <- action_policy_provider_for_gates(gate_selection, context) do
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
          process_provider_gate_failure(action_policy_provider, summary, context.opts)

        {:error, reason} ->
          {:error, {:gate_error, reason}}
      end
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
    changed_files_snapshot = changed_files_snapshot(context)

    [
      issue: issue,
      workspace: context.workspace,
      run_dir: context.run_dir,
      stage: :post_turn,
      turn_number: turn_number,
      changed_files: Map.get(changed_files_snapshot, :changed_files, []),
      changed_files_metadata: Map.drop(changed_files_snapshot, [:changed_files])
    ]
    |> maybe_put_source_contract(context.opts)
  end

  defp changed_files_snapshot(context) do
    case ChangedFiles.collect(context.workspace, run_dir: context.run_dir) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> %{changed_files: [], source: "error", reason: inspect(reason)}
    end
  end

  defp invalid_artifact_reason?({:invalid_artifact_field, _field}), do: true
  defp invalid_artifact_reason?(:invalid_artifact), do: true
  defp invalid_artifact_reason?(:invalid_artifact_id), do: true
  defp invalid_artifact_reason?({:unsupported_artifact_schema, _schema}), do: true
  defp invalid_artifact_reason?({:artifact_not_approved, _status}), do: true
  defp invalid_artifact_reason?({:invalid_json, _path, _message}), do: true
  defp invalid_artifact_reason?(_reason), do: false

  defp handle_gate_selection_failure(provider, reason, opts) do
    required? = Config.process_provider_required?()
    payload = process_provider_failure_payload(provider, :gate_selection, reason, opts, required?)

    cond do
      required? ->
        {:error, {:process_provider_required_failed, payload}}

      provider == Native or invalid_artifact_reason?(reason) ->
        {:error, {:process_provider_failed, payload}}

      true ->
        provider_id = provider_id(provider)
        Logger.warning("Process provider gate selection failed provider=#{provider_id} reason=#{inspect(reason)}; falling back to native gates")

        case ProcessProvider.select_gate_selection(Native, opts) do
          {:ok, selection} ->
            {:ok, selection |> annotate_native_fallback(provider_id, reason) |> annotate_action_policy_provider(Native)}

          {:error, native_reason} ->
            native_payload = process_provider_failure_payload(Native, :gate_selection, native_reason, opts, required?)
            {:error, {:process_provider_failed, native_payload}}
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
    required? = Config.process_provider_required?()

    if Beislid.action_policy_available?(opts) do
      {:ok, Beislid, annotate_action_policy_provider(gate_selection, Beislid)}
    else
      action_policy_provider_missing_beislid_policy(gate_selection, opts, required?)
    end
  end

  defp action_policy_provider_for_gates(gate_selection, context) do
    provider = Map.get(gate_selection, :action_policy_provider, context.process_provider)
    {:ok, provider, annotate_action_policy_provider(gate_selection, provider)}
  end

  defp action_policy_provider_missing_beislid_policy(_gate_selection, opts, true) do
    payload = process_provider_failure_payload(Beislid, :action_policy, :action_policy_unavailable, opts, true)
    {:error, {:process_provider_required_failed, payload}}
  end

  defp action_policy_provider_missing_beislid_policy(gate_selection, _opts, false) do
    provider = Native

    gate_selection =
      gate_selection
      |> annotate_native_fallback(provider_id(Beislid), :action_policy_unavailable)
      |> annotate_action_policy_provider(provider)

    {:ok, provider, gate_selection}
  end

  defp process_provider_failure_payload(provider, phase, reason, opts, required?) do
    ProcessProvider.failure_payload(provider, phase, reason, Keyword.put(opts, :required, required?))
  end

  defp process_provider_failure_tuple(true, payload), do: {:process_provider_required_failed, payload}
  defp process_provider_failure_tuple(false, payload), do: {:process_provider_failed, payload}

  defp process_provider_gate_failure(Beislid, summary, opts) do
    case summary_status(summary) do
      status when status in [:policy_blocked, "policy_blocked", :policy_denied, "policy_denied"] ->
        if Config.process_provider_required?() do
          payload = process_provider_failure_payload(Beislid, :action_policy, gate_failure_reason(summary), opts, true)
          {:error, {:process_provider_required_failed, payload}}
        else
          {:error, gate_failure_reason(summary)}
        end

      _ ->
        {:error, gate_failure_reason(summary)}
    end
  end

  defp process_provider_gate_failure(_provider, summary, _opts), do: {:error, gate_failure_reason(summary)}

  defp summary_status(summary), do: Map.get(summary, :status) || Map.get(summary, "status")

  defp maybe_put_source_contract(opts, context_opts) do
    case Keyword.get(context_opts, :source_contract) do
      source_contract when is_map(source_contract) -> Keyword.put(opts, :source_contract, source_contract)
      _other -> opts
    end
  end

  defp annotate_action_policy_provider(selection, provider) do
    selection
    |> Map.put(:action_policy_provider, provider)
    |> Map.update!(:metadata, &Map.put(&1, :action_policy_provider, provider_id(provider)))
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
         event: gate_update_event(summary),
         timestamp: DateTime.utc_now(),
         session_id: nil,
         usage: nil,
         raw: Gates.summary_to_json(summary)
       }}
    )

    :ok
  end

  defp send_gate_update(_recipient, _issue, _summary), do: :ok

  defp gate_update_event(%{status: :reused}), do: :gates_reused
  defp gate_update_event(%{"status" => "reused"}), do: :gates_reused
  defp gate_update_event(_summary), do: :gates_completed

  defp gate_error_summary(summary) do
    %{
      status: summary.status,
      failed: Enum.map(summary.results, &Map.take(&1, [:name, :status, :exit_status, :retryable, :environment_failure]))
    }
  end

  defp gate_failure_reason(%{status: status} = summary) when status in [:policy_blocked, "policy_blocked"] do
    case policy_gate_result(summary, [:policy_blocked, "policy_blocked"]) do
      nil -> {:gate_failed, gate_error_summary(summary)}
      result -> {:action_policy_guidance_required, gate_guidance_interrupt(result)}
    end
  end

  defp gate_failure_reason(%{status: status} = summary) when status in [:policy_denied, "policy_denied"] do
    case policy_gate_result(summary, [:policy_denied, "policy_denied"]) do
      nil -> {:gate_failed, gate_error_summary(summary)}
      result -> {:action_policy_denied, gate_policy_envelope(result)}
    end
  end

  defp gate_failure_reason(summary), do: {:gate_failed, gate_error_summary(summary)}

  defp policy_gate_result(summary, statuses) when is_list(statuses) do
    Enum.find(List.wrap(summary.results), fn result ->
      status = Map.get(result, :status)
      status_text = if is_atom(status), do: Atom.to_string(status), else: status
      status in statuses or status_text in statuses
    end)
  end

  defp gate_guidance_interrupt(result) do
    SideEffectPolicy.guidance_interrupt(gate_side_effect(result), gate_policy_envelope(result))
  end

  defp gate_policy_envelope(result), do: Map.get(result, :policy_decision) || %{}

  defp gate_side_effect(result) do
    policy_decision = gate_policy_envelope(result)
    command = Map.get(result, :command)
    action = Map.get(policy_decision, "action") || Map.get(result, :name) || "gate"
    classes = Map.get(policy_decision, "classes") || []

    %{
      action: action,
      classes: classes,
      label: Map.get(result, :name) || action,
      operation: command,
      command: command,
      required: true,
      resume_safe: true,
      skip_behavior: "block",
      side_effect_id: "gate:#{Map.get(result, :name) || action}"
    }
  end

  # credo:disable-for-next-line
  # credo:disable-for-next-line
  defp continue_agent_turns(context, issue, turn_number, effective_run_ref, final_report, previous_final_report_fingerprint) do
    analysis = FinalReport.analyze(final_report)

    decision =
      case maybe_complete_planning_phase(context, issue, analysis, turn_number, final_report, effective_run_ref) do
        :not_planning ->
          continuation_decision(
            context,
            issue,
            analysis,
            turn_number,
            previous_final_report_fingerprint,
            final_report,
            effective_run_ref
          )

        planning_decision ->
          planning_decision
      end

    case decision do
      {:continue, refreshed_issue, current_final_report_fingerprint, next_context}
      when turn_number < context.max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} turn=#{turn_number}/#{context.max_turns}")

        do_run_agent_turns(
          next_context,
          refreshed_issue,
          turn_number + 1,
          effective_run_ref,
          current_final_report_fingerprint
        )

      {:continue, refreshed_issue, _current_final_report_fingerprint, _next_context} ->
        dispatch_run_decision(
          turn_context_recipient(context),
          issue,
          :stop,
          "max_turns_reached",
          "stop because agent.max_turns was reached",
          run_decision_opts(context, refreshed_issue, turn_number, effective_run_ref, analysis, final_report, %{
            "agent_max_turns" => context.max_turns
          })
        )

        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with delivery still incomplete")
        :ok

      {:done, _refreshed_issue, _next_context} ->
        :ok

      {:pause, interrupt, _next_context} ->
        {:pause, interrupt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # credo:disable-for-next-line
  # credo:disable-for-next-line
  defp maybe_complete_planning_phase(context, issue, analysis, turn_number, final_report, effective_run_ref) do
    cond do
      not planning_phase?(context) ->
        :not_planning

      planning_phase_ready?(analysis) ->
        maybe_complete_ready_planning_phase(context, issue, analysis, turn_number, final_report, effective_run_ref)

      true ->
        reason = planning_phase_block_reason(analysis)

        pause_planning_phase(
          context,
          %{
            issue: issue,
            analysis: analysis,
            turn_number: turn_number,
            final_report: final_report,
            effective_run_ref: effective_run_ref
          },
          reason,
          "pause because planning phase did not produce a safe implementation handoff"
        )
    end
  end

  # credo:disable-for-next-line
  defp maybe_complete_ready_planning_phase(context, issue, analysis, turn_number, final_report, effective_run_ref) do
    case maybe_continue_with_live_update(context, issue, :continue) do
      {:continue, refreshed_issue, next_context} ->
        maybe_continue_after_workspace_check(
          next_context,
          context,
          refreshed_issue,
          analysis,
          turn_number,
          final_report,
          effective_run_ref
        )

      {:terminal, refreshed_issue, next_context} ->
        # credo:disable-for-next-line
        stop_for_tracker_state(next_context, refreshed_issue, turn_number, effective_run_ref, :terminal, :planning_complete)

      {:inactive, refreshed_issue, next_context} ->
        # credo:disable-for-next-line
        stop_for_tracker_state(next_context, refreshed_issue, turn_number, effective_run_ref, :inactive, :planning_complete)

      {:missing, refreshed_issue, next_context} ->
        # credo:disable-for-next-line
        stop_for_tracker_state(next_context, refreshed_issue, turn_number, effective_run_ref, :missing, :planning_complete)

      {:pause, interrupt, _next_context} ->
        {:pause, interrupt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_continue_after_workspace_check(
         next_context,
         context,
         issue,
         analysis,
         turn_number,
         final_report,
         effective_run_ref
       ) do
    case Workspace.verify_clean(next_context.workspace, next_context.opts) do
      {:ok, :clean} ->
        continue_after_planning_ready(
          next_context,
          context,
          issue,
          analysis,
          turn_number,
          final_report,
          effective_run_ref
        )

      {:ok, :dirty} ->
        pause_after_planning_workspace_check(
          next_context,
          issue,
          analysis,
          turn_number,
          final_report,
          effective_run_ref,
          %{"workspace_status" => "dirty"}
        )

      {:error, reason} ->
        pause_after_planning_workspace_check(
          next_context,
          issue,
          analysis,
          turn_number,
          final_report,
          effective_run_ref,
          %{"workspace_check_error" => inspect(reason)}
        )
    end
  end

  defp continue_after_planning_ready(
         next_context,
         context,
         issue,
         analysis,
         turn_number,
         final_report,
         effective_run_ref
       ) do
    next_context = next_context |> clear_live_update_prompt() |> put_planning_handoff(analysis, final_report)

    _ledger =
      record_planning_completed_checkpoint(context, issue, turn_number, analysis, final_report, effective_run_ref)

    dispatch_run_decision(
      turn_context_recipient(context),
      issue,
      :continue,
      "planning_phase_completed",
      "continue from planning phase to implementation phase",
      run_decision_opts(context, issue, turn_number, effective_run_ref, analysis, final_report, %{
        "completed_phase" => "planning",
        "next_phase" => "implementation",
        "recommended_implementation_tier" => implementation_tier_from_report(analysis.report)
      })
    )

    {:continue, issue, analysis.fingerprint, next_context}
  end

  defp pause_after_planning_workspace_check(
         next_context,
         issue,
         analysis,
         turn_number,
         final_report,
         effective_run_ref,
         extra_input_signals
       ) do
    reason = Map.get(extra_input_signals, "workspace_status") || "check_failed"

    pause_planning_phase(
      next_context,
      %{
        issue: issue,
        analysis: analysis,
        turn_number: turn_number,
        final_report: final_report,
        effective_run_ref: effective_run_ref,
        extra_input_signals: extra_input_signals
      },
      "planning_workspace_#{reason}",
      "pause because the workspace must be clean before implementation can begin"
    )
  end

  defp pause_planning_phase(context, planning_args, reason, summary) do
    issue = Map.fetch!(planning_args, :issue)
    analysis = Map.fetch!(planning_args, :analysis)
    turn_number = Map.fetch!(planning_args, :turn_number)
    final_report = Map.fetch!(planning_args, :final_report)
    effective_run_ref = Map.fetch!(planning_args, :effective_run_ref)
    extra_input_signals = Map.get(planning_args, :extra_input_signals, %{})

    dispatch_run_decision(
      turn_context_recipient(context),
      issue,
      :pause,
      reason,
      summary,
      run_decision_opts(
        context,
        issue,
        turn_number,
        effective_run_ref,
        analysis,
        final_report,
        Map.merge(
          %{"completed_phase" => "planning", "next_phase" => nil, "planning_block_reason" => reason},
          extra_input_signals
        )
      )
    )

    {:pause,
     final_report_interrupt(
       context,
       issue,
       effective_run_ref,
       analysis,
       final_report,
       turn_number,
       reason
     ), clear_live_update_prompt(context)}
  end

  defp planning_phase_ready?(%{status: :valid, report: report}) when is_map(report) do
    active_issue_state?(Map.get(report, "next_state")) and
      implementation_plan_present?(report) and
      planning_changed_files(report) == []
  end

  defp planning_phase_ready?(_analysis), do: false

  defp implementation_plan_present?(%{"implementation_plan" => plan}) when is_binary(plan), do: String.trim(plan) != ""

  defp implementation_plan_present?(%{"implementation_plan" => plan}) when is_list(plan),
    do: normalize_implementation_plan_steps(plan) != []

  defp implementation_plan_present?(_report), do: false

  # The planning prompt does not pin a type for `implementation_plan`, so a
  # list of step strings is as contract-compliant as a single string.
  defp normalize_implementation_plan_steps(plan) when is_list(plan) do
    plan
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp planning_changed_files(%{"changed_files" => files}) when is_list(files), do: Enum.filter(files, &is_binary/1)
  defp planning_changed_files(_report), do: []

  defp planning_phase_block_reason(%{status: status}) when status != :valid, do: "planning_final_report_invalid"

  defp planning_phase_block_reason(%{report: report}) when is_map(report) do
    cond do
      not active_issue_state?(Map.get(report, "next_state")) -> "planning_final_report_terminal"
      not implementation_plan_present?(report) -> "planning_handoff_missing"
      planning_changed_files(report) != [] -> "planning_report_declared_changes"
      true -> "planning_handoff_unsafe"
    end
  end

  defp planning_phase_block_reason(_analysis), do: "planning_handoff_unsafe"

  defp record_planning_completed_checkpoint(context, issue, turn_number, analysis, final_report, effective_run_ref) do
    case Keyword.get(Map.get(context, :opts, []), :run_ledger) do
      %RunLedger{} = ledger ->
        payload = %{
          "phase" => "planning",
          "next_phase" => "implementation",
          "turn_number" => turn_number,
          "issue" => %{
            "id" => Map.get(issue, :id),
            "identifier" => Map.get(issue, :identifier),
            "title" => Map.get(issue, :title),
            "state" => Map.get(issue, :state)
          },
          "final_report_status" => Atom.to_string(analysis.status),
          "implementation_plan" => implementation_plan_from_report(analysis.report, final_report),
          "recommended_implementation_tier" => implementation_tier_from_report(analysis.report),
          "run_ref" => effective_run_ref
        }

        case RunLedger.write_checkpoint(ledger, :planning_completed, payload, source: %{phase: "planning"}) do
          {:ok, ledger} ->
            ledger

          {:error, reason} ->
            Logger.warning("Failed to record planning checkpoint for #{issue_context(issue)} reason=#{inspect(reason)}")
            ledger
        end

      _other ->
        nil
    end
  end

  defp put_planning_handoff(context, analysis, final_report) do
    plan = implementation_plan_from_report(analysis.report, final_report)
    tier = implementation_tier_from_report(analysis.report)

    update_in(context.opts, fn opts ->
      opts
      |> Keyword.delete(:model_routing_context)
      |> Keyword.delete(:model_routing)
      |> Keyword.delete(:model)
      |> Keyword.put(:planning_handoff, plan)
      |> maybe_put_runtime_implementation_tier(tier)
    end)
  end

  defp maybe_put_runtime_implementation_tier(opts, "heavy") do
    Keyword.put(opts, :runtime_model_routing_hints, implementation_tier_hints("heavy"))
  end

  defp maybe_put_runtime_implementation_tier(opts, _tier), do: Keyword.delete(opts, :runtime_model_routing_hints)

  defp implementation_tier_hints(tier) do
    %{"steps" => [%{"stage" => "turn", "phase" => "implementation", "tier" => tier, "mode" => "prefer"}]}
  end

  defp implementation_tier_from_report(%{"recommended_implementation_tier" => tier}) when is_binary(tier) do
    case tier |> String.trim() |> String.downcase() do
      "heavy" -> "heavy"
      _other -> "standard"
    end
  end

  defp implementation_tier_from_report(_report), do: "standard"

  defp implementation_plan_from_report(%{"implementation_plan" => plan}, _final_report) when is_binary(plan) do
    case String.trim(plan) do
      "" -> "Planning phase completed without a detailed implementation_plan. Continue from the ticket and run ledger context."
      trimmed -> trimmed
    end
  end

  defp implementation_plan_from_report(%{"implementation_plan" => plan} = report, final_report) when is_list(plan) do
    case normalize_implementation_plan_steps(plan) do
      [] -> implementation_plan_from_report(Map.delete(report, "implementation_plan"), final_report)
      steps -> Enum.map_join(Enum.with_index(steps, 1), "\n", fn {step, index} -> "#{index}. #{step}" end)
    end
  end

  defp implementation_plan_from_report(_report, final_report) do
    "Planning phase completed. Final report excerpt:\n" <> final_report_excerpt(final_report)
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
      continuation_decision_by_status(context, issue, analysis, turn_number, final_report, effective_run_ref)
    end
  end

  defp final_report_unparsed_pause(context, issue, analysis, turn_number, final_report, effective_run_ref) do
    case final_report_state_classification(analysis.next_state_hint) do
      :blocked when analysis.status != :valid ->
        dispatch_run_decision(
          turn_context_recipient(context),
          issue,
          :pause,
          "blocked_state_unparsed",
          "pause because final report is missing or invalid when required",
          run_decision_opts(context, issue, turn_number, effective_run_ref, analysis, final_report, %{
            "classification" => "blocked_state_unparsed"
          })
        )

        {:pause,
         final_report_interrupt(
           context,
           issue,
           effective_run_ref,
           analysis,
           final_report,
           turn_number,
           "blocked_state_unparsed"
         ), clear_live_update_prompt(context)}

      :terminal when analysis.status != :valid ->
        dispatch_run_decision(
          turn_context_recipient(context),
          issue,
          :pause,
          "terminal_state_unparsed",
          "pause because final report is missing or invalid when required",
          run_decision_opts(context, issue, turn_number, effective_run_ref, analysis, final_report, %{
            "classification" => "terminal_state_unparsed"
          })
        )

        {:pause,
         final_report_interrupt(
           context,
           issue,
           effective_run_ref,
           analysis,
           final_report,
           turn_number,
           "terminal_state_unparsed"
         ), clear_live_update_prompt(context)}

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
      dispatch_run_decision(
        turn_context_recipient(context),
        issue,
        :pause,
        "repeated_final_report",
        "pause because the assistant repeated the same final report",
        run_decision_opts(context, issue, turn_number, effective_run_ref, analysis, final_report)
      )

      {:pause,
       final_report_interrupt(
         context,
         issue,
         effective_run_ref,
         analysis,
         final_report,
         turn_number,
         "repeated_final_report"
       ), clear_live_update_prompt(context)}
    else
      nil
    end
  end

  defp continuation_decision_by_status(
         context,
         issue,
         analysis,
         turn_number,
         final_report,
         effective_run_ref
       ) do
    case analysis.status do
      :valid ->
        valid_final_report_continuation(
          context,
          issue,
          analysis,
          turn_number,
          final_report,
          effective_run_ref
        )

      _invalid_or_missing ->
        invalid_or_missing_final_report_continuation(
          context,
          issue,
          analysis,
          turn_number,
          final_report,
          effective_run_ref
        )
    end
  end

  defp valid_final_report_continuation(context, issue, analysis, turn_number, final_report, effective_run_ref) do
    if active_issue_state?(Map.get(analysis.report, "next_state")) do
      case maybe_continue_with_live_update(context, issue, :continue) do
        {:continue, refreshed_issue, next_context} ->
          dispatch_run_decision(
            turn_context_recipient(context),
            refreshed_issue,
            :continue,
            "final_report_active_or_incomplete",
            "continue because final report says active/incomplete",
            # credo:disable-for-next-line
            # credo:disable-for-next-line
            # credo:disable-for-next-line
            run_decision_opts(context, refreshed_issue, turn_number, effective_run_ref, analysis, final_report)
          )

          {:continue, refreshed_issue, analysis.fingerprint, next_context}

        {:terminal, refreshed_issue, next_context} ->
          # credo:disable-for-next-line
          stop_for_tracker_state(next_context, refreshed_issue, turn_number, effective_run_ref, :terminal, :final_report)

        {:inactive, refreshed_issue, next_context} ->
          # credo:disable-for-next-line
          stop_for_tracker_state(next_context, refreshed_issue, turn_number, effective_run_ref, :inactive, :final_report)

        {:missing, refreshed_issue, next_context} ->
          # credo:disable-for-next-line
          stop_for_tracker_state(next_context, refreshed_issue, turn_number, effective_run_ref, :missing, :final_report)

        {:pause, interrupt, next_context} ->
          dispatch_run_decision(
            turn_context_recipient(context),
            issue,
            :pause,
            "tracker_update_requires_guidance",
            "pause because tracker update requires guidance",
            run_decision_opts(context, issue, turn_number, effective_run_ref, analysis, final_report, %{
              "tracker_update" => Map.get(interrupt, "question")
            })
          )

          {:pause, interrupt, next_context}

        {:error, reason} ->
          {:error, reason}
      end
    else
      dispatch_run_decision(
        turn_context_recipient(context),
        issue,
        :stop,
        "final_report_terminal_or_complete",
        "stop because final report says terminal/complete",
        run_decision_opts(context, issue, turn_number, effective_run_ref, analysis, final_report)
      )

      {:done, issue, clear_live_update_prompt(context)}
    end
  end

  defp invalid_or_missing_final_report_continuation(context, issue, analysis, turn_number, final_report, effective_run_ref) do
    if tracker_capable?(context) do
      case maybe_continue_with_live_update(context, issue, :continue) do
        {:continue, refreshed_issue, next_context} ->
          dispatch_run_decision(
            turn_context_recipient(context),
            refreshed_issue,
            :continue,
            "tracker_state_fallback",
            "fallback to tracker-state continuation because no usable final report exists",
            run_decision_opts(context, refreshed_issue, turn_number, effective_run_ref, analysis, final_report)
          )

          {:continue, refreshed_issue, analysis.fingerprint, next_context}

        {:terminal, refreshed_issue, next_context} ->
          # credo:disable-for-next-line
          stop_for_tracker_state(next_context, refreshed_issue, turn_number, effective_run_ref, :terminal, :tracker_fallback)

        {:inactive, refreshed_issue, next_context} ->
          # credo:disable-for-next-line
          stop_for_tracker_state(next_context, refreshed_issue, turn_number, effective_run_ref, :inactive, :tracker_fallback)

        {:missing, refreshed_issue, next_context} ->
          # credo:disable-for-next-line
          stop_for_tracker_state(next_context, refreshed_issue, turn_number, effective_run_ref, :missing, :tracker_fallback)

        {:pause, interrupt, next_context} ->
          dispatch_run_decision(
            turn_context_recipient(context),
            issue,
            :pause,
            "tracker_update_requires_guidance",
            "pause because tracker update requires guidance",
            run_decision_opts(context, issue, turn_number, effective_run_ref, analysis, final_report, %{
              "tracker_update" => Map.get(interrupt, "question")
            })
          )

          {:pause, interrupt, next_context}

        {:error, reason} ->
          {:error, reason}
      end
    else
      dispatch_run_decision(
        turn_context_recipient(context),
        issue,
        :stop,
        "tracker_less_no_continuation_authority",
        "stop because tracker-less run has no continuation authority",
        run_decision_opts(context, issue, turn_number, effective_run_ref, analysis, final_report)
      )

      {:done, issue, clear_live_update_prompt(context)}
    end
  end

  defp run_decision_opts(context, issue, turn_number, effective_run_ref, analysis, final_report, extra_input_signals \\ %{}) do
    opts = Map.get(context, :opts, [])
    retry_attempt = Keyword.get(opts, :retry_attempt) || Keyword.get(opts, :attempt)

    [
      issue: issue,
      run_id: Map.get(context, :run_id),
      run_dir: Map.get(context, :run_dir),
      session_id: Map.get(effective_run_ref || %{}, :provider_ref),
      run_ref: effective_run_ref,
      turn_number: turn_number,
      retry_attempt: retry_attempt,
      input_signals:
        Map.merge(
          %{
            "final_report_status" => Atom.to_string(analysis.status),
            "final_report_next_state" => analysis.next_state_hint,
            "final_report_fingerprint" => analysis.fingerprint,
            "tracker_capable" => tracker_capable?(context),
            "issue_state" => Map.get(issue, :state),
            "continuation_count" => max(turn_number - 1, 0)
          },
          extra_input_signals
        ),
      evidence: run_decision_evidence(context, analysis, final_report)
    ]
  end

  defp run_decision_evidence(context, analysis, final_report) do
    evidence =
      if analysis.status == :valid and is_binary(Map.get(context, :run_dir)) do
        %{"final_report" => %{"path" => RunLedger.final_report_relative_path()}}
      else
        %{}
      end

    if is_binary(final_report) and String.trim(final_report) != "" do
      Map.put(evidence, "final_report_excerpt", final_report_excerpt(final_report))
    else
      evidence
    end
  end

  defp dispatch_run_decision(recipient, issue, decision_kind, reason_code, summary, opts) do
    send_claude_update(recipient, issue, RunDecision.synthetic_update(decision_kind, reason_code, summary, opts))
  end

  defp stop_for_tracker_state(context, issue, turn_number, effective_run_ref, classification, stage) do
    reason_code = tracker_state_stop_reason_code(classification)
    summary = tracker_state_stop_summary(classification, Map.get(issue, :state))

    dispatch_run_decision(
      turn_context_recipient(context),
      issue,
      :stop,
      reason_code,
      summary,
      tracker_state_stop_run_decision_opts(context, issue, turn_number, effective_run_ref, classification, stage)
    )

    exit({:tracker_state_stop, %{classification: classification, stage: stage, issue_id: Map.get(issue, :id), issue_identifier: Map.get(issue, :identifier), state: Map.get(issue, :state)}})
  end

  defp tracker_state_stop_run_decision_opts(context, issue, turn_number, effective_run_ref, classification, stage) do
    opts = Map.get(context, :opts, [])
    run_ledger = Keyword.get(opts, :run_ledger)
    retry_attempt = Keyword.get(opts, :retry_attempt) || Keyword.get(opts, :attempt)

    [
      issue: issue,
      run_id: run_ledger_run_id(run_ledger),
      run_dir: run_ledger_run_dir(run_ledger),
      session_id: Map.get(effective_run_ref || %{}, :provider_ref),
      run_ref: effective_run_ref,
      turn_number: turn_number,
      retry_attempt: retry_attempt,
      input_signals: %{
        "tracker_state" => Map.get(issue, :state),
        "tracker_state_classification" => Atom.to_string(classification),
        "tracker_state_stage" => to_string(stage),
        "tracker_capable" => tracker_capable?(context)
      },
      evidence: %{
        "tracker_state" => %{
          "issue_id" => Map.get(issue, :id),
          "issue_identifier" => Map.get(issue, :identifier)
        }
      }
    ]
  end

  defp tracker_state_stop_reason_code(classification) do
    cond do
      classification == :terminal -> "tracker_state_terminal"
      classification == :inactive -> "tracker_state_inactive"
      classification == :missing -> "tracker_state_missing"
      true -> "tracker_state_stopped"
    end
  end

  defp tracker_state_stop_summary(:terminal, state) when is_binary(state), do: "stop because tracker state #{state} is terminal"
  defp tracker_state_stop_summary(:inactive, state) when is_binary(state), do: "stop because tracker state #{state} is no longer active"
  defp tracker_state_stop_summary(:missing, state) when is_binary(state), do: "stop because tracker state #{state} is no longer visible"
  defp tracker_state_stop_summary(:missing, _state), do: "stop because tracker issue is no longer visible"
  defp tracker_state_stop_summary(_classification, state) when is_binary(state), do: "stop because tracker state #{state} changed"
  defp tracker_state_stop_summary(_classification, _state), do: "stop because tracker state is no longer visible"

  defp turn_context_recipient(%{claude_update_recipient: recipient}), do: recipient
  defp turn_context_recipient(_context), do: nil

  defp action_policy_guidance_run_decision_opts(issue, interrupt, opts) do
    run_ledger = Keyword.get(opts, :run_ledger)
    resume = Map.get(interrupt, "resume", %{})

    [
      issue: issue,
      run_id: run_ledger_run_id(run_ledger),
      run_dir: run_ledger_run_dir(run_ledger),
      session_id: Map.get(resume, "session_id"),
      run_ref: Map.get(resume, "run_ref"),
      retry_attempt: Map.get(resume, "retry_attempt"),
      input_signals: %{
        "guidance_severity" => Map.get(interrupt, "guidance_severity"),
        "policy_decision" => get_in(interrupt, ["policy", "decision"]),
        "blocked_side_effect" => get_in(interrupt, ["blocked_side_effect", "action"])
      },
      evidence: %{
        "blocked_side_effect" => Map.get(interrupt, "blocked_side_effect"),
        "policy" => Map.get(interrupt, "policy"),
        "resume" => resume
      }
    ]
  end

  defp model_routing_exhausted_run_decision_opts(issue, interrupt, opts) do
    run_ledger = Keyword.get(opts, :run_ledger)
    resume = Map.get(interrupt, "resume", %{})
    fallback = Map.get(interrupt, "model_fallback", %{})

    [
      issue: issue,
      run_id: run_ledger_run_id(run_ledger),
      run_dir: run_ledger_run_dir(run_ledger),
      session_id: Map.get(resume, "session_id"),
      run_ref: Map.get(resume, "run_ref"),
      retry_attempt: Map.get(resume, "retry_attempt"),
      input_signals: %{
        "failed_candidate" => Map.get(fallback, "failed_candidate"),
        "fallback_exhausted" => Map.get(fallback, "exhausted")
      },
      evidence: %{
        "model_fallback" => fallback,
        "resume" => resume
      }
    ]
  end

  defp run_ledger_run_id(%RunLedger{run_id: run_id}), do: run_id
  defp run_ledger_run_id(_ledger), do: nil

  defp run_ledger_run_dir(%RunLedger{run_dir: run_dir}), do: run_dir
  defp run_ledger_run_dir(_ledger), do: nil

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

  defp maybe_continue_with_live_update(context, issue, no_tracker_result) do
    if tracker_capable?(context) do
      continue_with_live_update(context, issue)
    else
      {no_tracker_result, issue, clear_live_update_prompt(context)}
    end
  end

  defp tracker_capable?(%{trackerless: true}), do: false

  defp tracker_capable?(%{issue_state_fetcher: fetcher}),
    do: fetcher != (&__MODULE__.no_tracker_issue_state_fetcher/1)

  defp tracker_fetchers(opts) do
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    trackerless? =
      Keyword.get(opts, :trackerless, false) == true or
        issue_state_fetcher == (&__MODULE__.no_tracker_issue_state_fetcher/1)

    if trackerless? do
      {
        true,
        &__MODULE__.no_tracker_issue_state_fetcher/1,
        &__MODULE__.no_tracker_issue_context_fetcher/1
      }
    else
      {
        false,
        issue_state_fetcher,
        Keyword.get(opts, :issue_context_fetcher, &Tracker.fetch_issue_contexts_by_ids/1)
      }
    end
  end

  defp clear_live_update_prompt(%{opts: opts} = context) when is_list(opts) do
    %{context | opts: Keyword.delete(opts, :live_update_prompt)}
  end

  defp clear_live_update_prompt(context), do: context

  defp continue_with_live_update(context, %Issue{} = issue) do
    case continue_with_issue?(issue, context.issue_state_fetcher) do
      {:continue, refreshed_issue} ->
        refresh_live_issue_context(context, refreshed_issue)

      {:terminal, refreshed_issue} ->
        {:terminal, refreshed_issue, clear_live_update_prompt(context)}

      {:inactive, refreshed_issue} ->
        {:inactive, refreshed_issue, clear_live_update_prompt(context)}

      {:missing, refreshed_issue} ->
        {:missing, refreshed_issue, clear_live_update_prompt(context)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_live_issue_context(context, %Issue{} = refreshed_issue) do
    case current_issue_context_snapshot(refreshed_issue, Map.get(context, :issue_context_fetcher)) do
      {:ok, current_snapshot} ->
        previous_snapshot = Map.get(context, :issue_context_snapshot)
        detection = UpdateDetector.detect_update(previous_snapshot, current_snapshot)

        updated_context =
          context
          |> Map.put(:issue_context_snapshot, current_snapshot)
          |> maybe_put_live_update_prompt(detection)

        maybe_send_tracker_update(context.claude_update_recipient, refreshed_issue, detection)

        case detection.action do
          :pause ->
            interrupt = tracker_update_interrupt(context, refreshed_issue, detection)
            {:pause, interrupt, clear_live_update_prompt(updated_context)}

          _ ->
            {:continue, refreshed_issue, updated_context}
        end

      {:error, reason} ->
        Logger.debug("Failed to refresh live tracker context for #{issue_context(refreshed_issue)}: #{inspect(reason)}")
        {:continue, refreshed_issue, clear_live_update_prompt(context)}
    end
  end

  defp maybe_put_live_update_prompt(context, %{action: :inject, prompt_lines: prompt_lines}) when is_list(prompt_lines) and prompt_lines != [] do
    prompt = Enum.join(prompt_lines, "\n")
    update_in(context, [:opts], &Keyword.put(&1, :live_update_prompt, prompt))
  end

  defp maybe_put_live_update_prompt(context, _detection), do: clear_live_update_prompt(context)

  defp initial_issue_context_snapshot(%Issue{} = issue, issue_context_fetcher) do
    case current_issue_context_snapshot(issue, issue_context_fetcher) do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> UpdateDetector.snapshot_from_issue(issue)
    end
  end

  # credo:disable-for-next-line
  defp current_issue_context_snapshot(%Issue{id: issue_id} = _issue, issue_context_fetcher)
       when is_binary(issue_id) and is_function(issue_context_fetcher, 1) do
    case issue_context_fetcher.([issue_id]) do
      {:ok, [%{snapshot: snapshot} | _]} when is_map(snapshot) ->
        {:ok, snapshot}

      {:ok, [%{"snapshot" => snapshot} | _]} when is_map(snapshot) ->
        {:ok, snapshot}

      {:ok, [%{} = context | _]} ->
        case Map.get(context, :snapshot) || Map.get(context, "snapshot") do
          snapshot when is_map(snapshot) -> {:ok, snapshot}
          _ -> {:error, :missing_issue_context_snapshot}
        end

      {:ok, []} ->
        {:error, :issue_context_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_issue_context_snapshot(%Issue{} = issue, _issue_context_fetcher) do
    {:ok, UpdateDetector.snapshot_from_issue(issue)}
  end

  defp maybe_send_tracker_update(nil, _issue, _detection), do: :ok

  defp maybe_send_tracker_update(recipient, %Issue{id: issue_id}, detection) when is_pid(recipient) and is_binary(issue_id) do
    send(
      recipient,
      {:claude_worker_update, issue_id,
       %{
         event: :tracker_update_detected,
         timestamp: DateTime.utc_now(),
         session_id: nil,
         usage: nil,
         message: Map.get(detection, :summary),
         raw: detection
       }}
    )

    :ok
  end

  defp maybe_send_tracker_update(_recipient, _issue, _detection), do: :ok

  defp tracker_update_interrupt(context, issue, detection) do
    Interrupt.action_policy_guidance_required(%{
      issue: issue,
      timestamp: DateTime.utc_now(),
      run_id: Map.get(context, :run_id),
      run_dir: Map.get(context, :run_dir),
      session_id: Map.get(context, :session_id),
      question: tracker_update_question(detection),
      blocked_side_effect: %{
        "type" => "tracker_update",
        "action" => to_string(Map.get(detection, :action)),
        "classification" => to_string(Map.get(detection, :classification)),
        "reason" => Map.get(detection, :reason),
        "summary" => Map.get(detection, :summary)
      },
      guidance_severity: Map.get(detection, :guidance_severity),
      policy: %{reason: Map.get(detection, :reason)},
      suggested_responses: tracker_update_suggested_responses(detection),
      resume: %{run_id: Map.get(context, :run_id), run_dir: Map.get(context, :run_dir), session_id: Map.get(context, :session_id)}
    })
  end

  defp tracker_update_question(%{classification: :conflicting_or_ambiguous_update}) do
    "The ticket changed in a conflicting or ambiguous way. Should Rondo pause and await guidance?"
  end

  defp tracker_update_question(%{classification: :relation_or_blocker_change}) do
    "The ticket's blockers or relations changed. Should Rondo pause and re-evaluate the run?"
  end

  defp tracker_update_question(%{classification: :policy_or_risk_change}) do
    "The ticket now contains a policy, safety, or risk change. Should Rondo pause for guidance?"
  end

  defp tracker_update_question(_detection) do
    "The ticket changed while the run was active. Should Rondo continue with the refreshed tracker context?"
  end

  defp tracker_update_suggested_responses(%{action: :pause}) do
    [
      %{"id" => "resume", "label" => "Pause and review the live update before continuing"},
      %{"id" => "abort_run", "label" => "Abort this run"}
    ]
  end

  defp tracker_update_suggested_responses(_detection), do: []

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
  defp resolve_adapter_module("codex"), do: {:ok, CodexAdapter}
  defp resolve_adapter_module(:codex), do: {:ok, CodexAdapter}
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
    required? = Config.process_provider_required?()

    cond do
      blocking_probe?(probe) ->
        payload = process_provider_failure_payload(Beislid, :preflight, probe, opts, required?)
        {:error, process_provider_failure_tuple(required?, payload)}

      required? and Map.get(probe, :status) != :ok ->
        payload = process_provider_failure_payload(Beislid, :preflight, probe, opts, true)
        {:error, {:process_provider_required_failed, payload}}

      true ->
        :ok
    end
  end

  defp preflight_process_provider(_provider, _opts), do: :ok

  defp blocking_probe?(%{checks: checks}), do: map_size(Map.get(checks, :blocking, %{})) > 0

  defp build_turn_prompt(provider, issue, opts, 1, _max_turns) do
    prompt =
      case opts |> Keyword.get(:operator_guidance) |> normalize_operator_guidance() do
        nil ->
          ProcessProvider.prompt(provider, issue, opts)

        guidance ->
          if Keyword.get(opts, :fresh_workspace, false) do
            guidance
          else
            operator_guidance_prompt(guidance)
          end
      end

    prompt
    |> maybe_append_planning_phase_prompt(opts)
    |> prepend_live_update_prompt(opts)
  end

  defp build_turn_prompt(_provider, _issue, opts, turn_number, max_turns) do
    prompt =
      """
      Continuation guidance:

      - The previous turn completed normally, but the work is not yet complete (your final report did not declare a terminal next_state, or the tracker issue is still active).
      - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
      - Resume from the current workspace state instead of restarting from scratch.
      - The original task instructions and prior turn context are already present in this session, so do not restate them before acting.
      - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
      - Your final response must be only a valid `rondo.final_report/v0` JSON object with required fields `schema`, `summary`, `changed_files`, `gates_run`, `failures`, `risks`, and `next_state`; use `schema: "rondo.final_report/v0"` and do not use legacy keys such as `version`, `ticket`, `completed_actions`, or `blockers` instead of the required fields.
      """

    prompt
    |> maybe_prepend_planning_handoff(opts)
    |> prepend_live_update_prompt(opts)
  end

  defp maybe_append_planning_phase_prompt(prompt, opts) when is_binary(prompt) do
    if planning_phase?(%{opts: opts}) do
      prompt <> planning_phase_prompt()
    else
      prompt
    end
  end

  defp maybe_prepend_planning_handoff(prompt, opts) when is_binary(prompt) do
    case Keyword.get(opts, :planning_handoff) do
      handoff when is_binary(handoff) and handoff != "" ->
        "The planning-only phase is complete and its restrictions no longer apply. " <>
          "You are now in the implementation phase: edit files, run commands, and implement the plan below in the current workspace.\n\n" <>
          "Planning checkpoint to implement from:\n\n" <> handoff <> "\n\n" <> prompt

      _other ->
        prompt
    end
  end

  defp planning_phase_prompt do
    """

    ## Rondo planning phase

    This is a planning-only phase. Do not edit files, run autofix commands, commit, push, or perform implementation work.
    Produce an implementation handoff for the next phase. The next implementation phase will run separately with its own model routing.

    Your final response must include only a valid `rondo.final_report/v0` JSON object, using this exact core shape:

    ```json
    {
      "schema": "rondo.final_report/v0",
      "summary": "planning-only summary",
      "changed_files": [],
      "gates_run": [],
      "failures": [],
      "risks": [],
      "next_state": "In Progress",
      "implementation_plan": "concise handoff for the implementation phase",
      "recommended_implementation_tier": "standard"
    }
    ```

    Do not use legacy keys such as `version`, `ticket`, `completed_actions`, or `blockers` instead of the required core fields. `implementation_plan` may be either a non-empty string or a non-empty list of strings. Set `recommended_implementation_tier` to `standard` by default, or `heavy` only when implementation complexity requires stronger execution. Set `next_state` to an active state such as `In Progress` unless truly blocked.
    """
  end

  defp prepend_live_update_prompt(prompt, opts) when is_binary(prompt) do
    case Keyword.get(opts, :live_update_prompt) do
      value when is_binary(value) and value != "" ->
        "Live tracker update to incorporate:\n\n" <> value <> "\n\n" <> prompt

      _ ->
        prompt
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case TerminalState.refresh_issue_state(
           issue,
           issue_state_fetcher,
           Config.tracker_active_states(),
           Config.tracker_terminal_states()
         ) do
      {:active, refreshed_issue} ->
        {:continue, refreshed_issue}

      {:inactive, refreshed_issue} ->
        {:inactive, refreshed_issue}

      {:terminal, refreshed_issue} ->
        {:terminal, refreshed_issue}

      {:missing, refreshed_issue} ->
        {:missing, refreshed_issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:missing, issue}

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
