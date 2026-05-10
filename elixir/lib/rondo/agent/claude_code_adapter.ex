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

    cli_opts =
      Keyword.put(opts, :on_event, fn raw_event ->
        raw_event
        |> normalize_event()
        |> on_event.()
      end)

    result =
      case previous_run_ref do
        nil ->
          CLI.run(prompt, workspace, cli_opts)

        %{provider_ref_kind: provider_ref_kind, provider_ref: session_id, resumable?: true}
        when provider_ref_kind in ["session_id", :session_id] and is_binary(session_id) ->
          CLI.resume(session_id, prompt, workspace, cli_opts)

        %{resumable?: false} = run_ref ->
          {:error, {:resume_unsupported, run_ref}}

        run_ref ->
          {:error, {:invalid_resume_ref, run_ref}}
      end

    case result do
      {:ok, cli_result} ->
        run_ref = run_ref_from_cli_result(cli_result, previous_run_ref)
        usage = Map.get(cli_result, :usage)
        final_report = final_report(cli_result)
        capabilities = capabilities()

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
  end

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

  defp final_report(%{final_report: final_report}) when is_binary(final_report), do: final_report
  defp final_report(%{result: result}) when is_binary(result), do: result
  defp final_report(_cli_result), do: nil
end
