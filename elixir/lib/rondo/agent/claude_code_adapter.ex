defmodule Rondo.Agent.ClaudeCodeAdapter do
  @moduledoc """
  Claude Code implementation of the provider-neutral agent adapter contract.

  This adapter intentionally keeps `Rondo.Claude.CLI` and
  `Rondo.Claude.StreamParser` as Claude-specific internals while exposing
  provider-neutral run refs, events, capabilities, and invocation results to the
  orchestrator path.
  """

  @behaviour Rondo.Agent.Adapter

  alias Rondo.Agent.Adapter
  alias Rondo.Claude.{CLI, StreamParser}

  @id "claude_code"

  @impl true
  def id, do: @id

  @impl true
  def capabilities do
    %{
      launch: :subprocess,
      streaming: true,
      resume: :session_id,
      stop: :process_group_termination,
      approval: :permission_mode,
      usage: :final,
      rate_limits: :stream,
      diff: :fallback_git_diff,
      final_report: :final_or_last_assistant_message
    }
  end

  @impl true
  def probe(_opts \\ []) do
    Adapter.probe_result(:ok, %{
      command: :ok,
      stream_parser: :ok,
      resume: :ok
    })
  end

  @impl true
  def invoke(%{prompt: prompt, workspace: workspace, previous_run_ref: previous_run_ref, on_event: on_event} = request) do
    opts = Map.get(request, :opts, [])
    capabilities = capabilities()
    stream_state_key = {:rondo_claude_code_adapter_stream, make_ref()}
    Process.put(stream_state_key, %{completion_observed?: false, final_report: nil})

    try do
      cli_opts =
        Keyword.put(opts, :on_event, fn raw_event ->
          handle_stream_event(raw_event, stream_state_key, on_event, capabilities)
        end)

      result = invoke_cli(prompt, workspace, previous_run_ref, cli_opts)

      case result do
        {:ok, cli_result} ->
          stream_state = Process.get(stream_state_key, %{})
          run_ref = run_ref_from_cli_result(cli_result, previous_run_ref)
          usage = Map.get(cli_result, :usage)
          final_report = Map.get(stream_state, :final_report) || Map.get(cli_result, :final_report) || Map.get(cli_result, :result)

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

  defp invoke_cli(prompt, workspace, nil, cli_opts), do: CLI.run(prompt, workspace, cli_opts)

  defp invoke_cli(prompt, workspace, %{provider_ref_kind: provider_ref_kind, provider_ref: session_id, resumable?: true}, cli_opts)
       when provider_ref_kind in ["session_id", :session_id] and is_binary(session_id) do
    CLI.resume(session_id, prompt, workspace, cli_opts)
  end

  defp invoke_cli(_prompt, _workspace, %{resumable?: false} = run_ref, _cli_opts), do: {:error, {:resume_unsupported, run_ref}}
  defp invoke_cli(_prompt, _workspace, run_ref, _cli_opts), do: {:error, {:invalid_resume_ref, run_ref}}

  defp handle_stream_event(raw_event, stream_state_key, on_event, capabilities) do
    event = normalize_event(raw_event)

    stream_state =
      stream_state_key
      |> Process.get(%{completion_observed?: false, final_report: nil})
      |> update_stream_state(raw_event, event)

    Process.put(stream_state_key, stream_state)

    event =
      if event.event_type == :invocation_completed do
        %{event | capabilities: capabilities, final_report: stream_state.final_report}
      else
        event
      end

    on_event.(event)
  end

  defp maybe_emit_completion_event(_on_event, %{completion_observed?: true}, _run_ref, _usage, _final_report, _capabilities, _cli_result), do: :ok

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
    final_report = provider_final_report(raw_event) || assistant_message_text(raw_event) || Map.get(stream_state, :final_report)

    %{
      stream_state
      | final_report: final_report,
        completion_observed?: Map.get(stream_state, :completion_observed?, false) || event.event_type == :invocation_completed
    }
  end

  defp provider_final_report(raw_event) when is_map(raw_event) do
    case Map.get(raw_event, "result") || Map.get(raw_event, :result) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp assistant_message_text(%{"message" => %{} = message}), do: assistant_message_text(message)
  defp assistant_message_text(%{message: %{} = message}), do: assistant_message_text(message)

  defp assistant_message_text(%{} = message) do
    case Map.get(message, "content") || Map.get(message, :content) do
      content when is_list(content) ->
        content
        |> Enum.flat_map(&assistant_content_text/1)
        |> Enum.join(" ")
        |> case do
          "" -> nil
          text -> text
        end

      text when is_binary(text) and text != "" ->
        text

      _other ->
        nil
    end
  end

  defp assistant_content_text(%{"type" => "text", "text" => text}) when is_binary(text), do: [text]
  defp assistant_content_text(%{type: "text", text: text}) when is_binary(text), do: [text]
  defp assistant_content_text(_content), do: []

  defp normalize_event(raw_event) when is_map(raw_event) do
    session_id = StreamParser.extract_session_id(raw_event)
    run_ref = if session_id, do: Adapter.run_ref(@id, session_id, "session_id", true)

    raw_event
    |> normalized_event_type()
    |> Adapter.event(
      adapter: @id,
      run_ref: run_ref,
      usage: StreamParser.extract_usage(raw_event),
      raw: raw_event
    )
  end

  defp normalized_event_type(raw_event) do
    case Map.get(raw_event, :event_type) do
      :session_started -> :session_started
      :assistant -> :assistant_message
      :tool_use -> :tool_started
      :result -> :invocation_completed
      :rate_limit -> :rate_limits_updated
      :unknown -> :warning
      event when is_atom(event) -> event
      _ -> :warning
    end
  end

  defp run_ref_from_cli_result(%{session_id: session_id}, _previous_run_ref) when is_binary(session_id) do
    Adapter.run_ref(@id, session_id, "session_id", true)
  end

  defp run_ref_from_cli_result(_cli_result, previous_run_ref), do: previous_run_ref
end
