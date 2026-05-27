defmodule Rondo.Agent.PiAdapter do
  @moduledoc """
  pi implementation of the provider-neutral agent adapter contract.
  """

  @behaviour Rondo.Agent.Adapter

  alias Rondo.Agent.Adapter
  alias Rondo.Config
  alias Rondo.PathSafety
  alias Rondo.Pi.{CLI, StreamParser}

  @id "pi"

  @impl true
  def id, do: @id

  @impl true
  def capabilities do
    %{
      launch: :subprocess,
      streaming: true,
      resume: :session_id,
      stop: :degraded_process_termination,
      approval: :degraded,
      usage: :best_effort,
      rate_limits: :unsupported,
      diff: :fallback_git_diff,
      final_report: :explicit_result_or_last_assistant_message
    }
  end

  @impl true
  def probe(_opts \\ []) do
    command_status = command_probe_status(Config.pi_command())

    Adapter.probe_result(aggregate_probe_status([command_status, :ok, :degraded]), %{
      command: command_status,
      launch: :subprocess,
      stream_parser: :ok,
      resume: :degraded,
      stop: :degraded_process_termination,
      approval: :degraded,
      sandbox: :degraded,
      usage: :best_effort,
      rate_limits: :unsupported,
      diff: :fallback_git_diff,
      final_report: :explicit_result_or_last_assistant_message
    })
  end

  @impl true
  def invoke(%{prompt: prompt, workspace: workspace, previous_run_ref: previous_run_ref, on_event: on_event} = request) do
    opts = Map.get(request, :opts, [])
    capabilities = capabilities()
    stream_state_key = {:rondo_pi_adapter_stream, make_ref()}
    Process.put(stream_state_key, %{completion_observed?: false, final_report: nil, run_ref: previous_run_ref, usage: nil})

    try do
      cli_opts =
        Keyword.put(opts, :on_event, fn raw_event ->
          handle_stream_event(raw_event, stream_state_key, on_event, capabilities)
        end)

      result =
        with :ok <- validate_workspace(workspace) do
          invoke_cli(prompt, workspace, previous_run_ref, cli_opts)
        end

      case result do
        {:ok, cli_result} ->
          stream_state = Process.get(stream_state_key, %{})
          run_ref = run_ref_from_cli_result(cli_result, stream_state.run_ref || previous_run_ref)
          usage = Map.get(cli_result, :usage) || stream_state.usage
          final_report = Map.get(stream_state, :final_report) || provider_final_report(cli_result)

          maybe_emit_completion_event(on_event, stream_state, run_ref, usage, final_report, capabilities, cli_result)

          {:ok,
           Adapter.result(
             run_ref: run_ref,
             usage: usage,
             final_report: final_report,
             capabilities: capabilities,
             probe: probe(opts),
             raw: cli_result
           )}

        {:error, reason} ->
          on_event.(
            Adapter.event(:invocation_failed,
              adapter: @id,
              run_ref: previous_run_ref,
              raw: %{reason: inspect(reason)}
            )
          )

          {:error, reason}
      end
    after
      Process.delete(stream_state_key)
    end
  end

  defp command_probe_status(command) when is_binary(command) do
    command
    |> String.trim()
    |> case do
      "" -> :missing
      trimmed -> command_binary_status(trimmed)
    end
  end

  defp command_binary_status(command) do
    command
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> System.find_executable()
    |> case do
      nil -> :missing
      _path -> :ok
    end
  end

  defp aggregate_probe_status(statuses) do
    cond do
      Enum.any?(statuses, &(&1 == :missing)) -> :missing
      Enum.any?(statuses, &(&1 == :degraded)) -> :degraded
      Enum.any?(statuses, &(&1 == :unsupported)) -> :degraded
      true -> :ok
    end
  end

  defp validate_workspace(workspace) do
    expanded = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())

    with true <- File.dir?(expanded),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded),
         {:ok, canonical_root} <- PathSafety.canonicalize(root) do
      canonical_root_prefix = canonical_root <> "/"
      expanded_root_prefix = root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_equals_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_root}}
      end
    else
      false -> {:error, {:invalid_workspace_cwd, :not_a_directory}}
      {:error, {:path_canonicalize_failed, _path, reason}} -> {:error, {:invalid_workspace_cwd, reason}}
    end
  end

  defp invoke_cli(prompt, workspace, nil, cli_opts), do: CLI.run(prompt, workspace, cli_opts)

  defp invoke_cli(
         prompt,
         workspace,
         %{provider_ref_kind: provider_ref_kind, provider_ref: session_id, resumable?: true},
         cli_opts
       )
       when provider_ref_kind in ["session_id", :session_id] and is_binary(session_id) do
    CLI.resume(session_id, prompt, workspace, cli_opts)
  end

  defp invoke_cli(_prompt, _workspace, %{resumable?: false} = run_ref, _cli_opts),
    do: {:error, {:resume_unsupported, run_ref}}

  defp invoke_cli(_prompt, _workspace, run_ref, _cli_opts), do: {:error, {:invalid_resume_ref, run_ref}}

  defp handle_stream_event(raw_event, stream_state_key, on_event, capabilities) do
    case normalize_event(raw_event) do
      nil ->
        :ok

      event ->
        stream_state =
          stream_state_key
          |> Process.get(%{completion_observed?: false, final_report: nil, run_ref: nil, usage: nil})
          |> update_stream_state(raw_event, event)

        Process.put(stream_state_key, stream_state)

        event = %{event | run_ref: event.run_ref || stream_state.run_ref, usage: event.usage || stream_state.usage}

        event =
          if event.event_type == :invocation_completed do
            %{event | capabilities: capabilities, final_report: stream_state.final_report}
          else
            event
          end

        on_event.(event)
    end
  end

  defp maybe_emit_completion_event(
         _on_event,
         %{completion_observed?: true},
         _run_ref,
         _usage,
         _final_report,
         _capabilities,
         _cli_result
       ),
       do: :ok

  defp maybe_emit_completion_event(on_event, _stream_state, run_ref, usage, final_report, capabilities, cli_result) do
    on_event.(
      Adapter.event(:invocation_completed,
        adapter: @id,
        run_ref: run_ref,
        usage: usage,
        capabilities: capabilities,
        final_report: final_report,
        raw: cli_result
      )
    )
  end

  defp update_stream_state(stream_state, raw_event, event) do
    final_report = provider_final_report(raw_event) || Map.get(stream_state, :final_report)
    usage = StreamParser.extract_usage(raw_event) || event.usage || Map.get(stream_state, :usage)
    run_ref = event.run_ref || Map.get(stream_state, :run_ref)

    %{
      stream_state
      | final_report: final_report,
        usage: usage,
        run_ref: run_ref,
        completion_observed?: Map.get(stream_state, :completion_observed?, false) || event.event_type == :invocation_completed
    }
  end

  defp provider_final_report(raw_event) when is_map(raw_event) do
    StreamParser.explicit_result(raw_event) || StreamParser.assistant_text(raw_event)
  end

  defp provider_final_report(_raw_event), do: nil

  defp normalize_event(raw_event) when is_map(raw_event) do
    event_type = Map.get(raw_event, :event_type)

    if event_type == :ignore do
      nil
    else
      session_id = StreamParser.extract_session_id(raw_event)
      run_ref = if session_id, do: Adapter.run_ref(@id, session_id, "session_id", true)

      Adapter.event(event_type || :warning,
        adapter: @id,
        run_ref: run_ref,
        usage: StreamParser.extract_usage(raw_event),
        raw: raw_event,
        message: normalized_message(raw_event)
      )
    end
  end

  defp normalize_event(_raw_event), do: nil

  defp normalized_message(raw_event) do
    StreamParser.assistant_text(raw_event) || tool_message(raw_event)
  end

  defp tool_message(%{"toolName" => tool_name}) when is_binary(tool_name), do: tool_name
  defp tool_message(%{toolName: tool_name}) when is_binary(tool_name), do: tool_name
  defp tool_message(_raw_event), do: nil

  defp run_ref_from_cli_result(%{session_id: session_id}, _previous_run_ref) when is_binary(session_id) do
    Adapter.run_ref(@id, session_id, "session_id", true)
  end

  defp run_ref_from_cli_result(_cli_result, previous_run_ref), do: previous_run_ref
end
