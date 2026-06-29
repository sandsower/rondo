defmodule Rondo.Agent.CodexAdapter do
  @moduledoc """
  Codex implementation of the provider-neutral agent adapter contract.

  The adapter keeps Codex-native thread identity and JSONL events intact while
  exposing Rondo-normalized events, run refs, and invocation results.
  """

  @behaviour Rondo.Agent.Adapter

  alias Rondo.Agent.Adapter
  alias Rondo.Codex.{CLI, StreamParser}
  alias Rondo.{Config, PathSafety}

  @id "codex"
  @help_probe_timeout_ms 10_000
  @help_probe_line_bytes 8_192

  @impl true
  def id, do: @id

  @impl true
  def capabilities do
    %{
      launch: :subprocess,
      streaming: true,
      resume: :thread_id,
      stop: :process_group_termination,
      approval: :degraded,
      usage: :final,
      rate_limits: :unsupported,
      diff: :fallback_git_diff,
      final_report: :final_or_last_assistant_message
    }
  end

  @impl true
  @spec probe(keyword()) :: Adapter.probe_result()
  def probe(opts \\ []) do
    command = Config.codex_command()
    command_status = command_probe_status(command)
    help_probe_timeout_ms = Keyword.get(opts, :help_probe_timeout_ms, @help_probe_timeout_ms)
    model_selection_status = model_selection_probe_status(command, command_status, help_probe_timeout_ms)

    Adapter.probe_result(aggregate_probe_status([command_status, model_selection_status, :ok, :degraded]), %{
      command: command_status,
      launch: :subprocess,
      stream_parser: :ok,
      resume: :thread_id,
      stop: :process_group_termination,
      approval: :degraded,
      usage: :final,
      rate_limits: :unsupported,
      model_selection: model_selection_status,
      diff: :fallback_git_diff,
      final_report: :final_or_last_assistant_message
    })
  end

  @impl true
  def invoke(%{prompt: prompt, workspace: workspace, previous_run_ref: previous_run_ref, on_event: on_event} = request) do
    opts = Map.get(request, :opts, [])
    capabilities = capabilities()
    stream_state_key = {:rondo_codex_adapter_stream, make_ref()}
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
             raw: cli_result,
             diff_source: :fallback_git_diff
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

  defp model_selection_probe_status(_command, :missing, _timeout_ms), do: :unsupported

  defp model_selection_probe_status(command, :ok, timeout_ms) do
    command
    |> String.split(~r/\s+/, trim: true)
    |> case do
      [] -> :unsupported
      [binary | args] -> command_help_model_status(binary, args, timeout_ms)
    end
  end

  defp command_help_model_status(binary, args, timeout_ms) do
    binary
    |> System.find_executable()
    |> command_help_model_status_for_executable(args, timeout_ms)
  rescue
    _error -> :unsupported
  end

  defp command_help_model_status_for_executable(nil, _args, _timeout_ms), do: :unsupported

  defp command_help_model_status_for_executable(executable, args, timeout_ms) do
    executable
    |> stream_help_for_model_flag(args ++ ["exec", "--help"], timeout_ms)
    |> help_output_model_status()
  end

  defp stream_help_for_model_flag(executable, args, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :stderr_to_stdout, {:line, @help_probe_line_bytes}, {:args, args}]
      )

    deadline = System.monotonic_time(:millisecond) + max(timeout_ms, 0)

    help_probe_loop(port, deadline, "")
  rescue
    _error -> :unsupported
  end

  defp help_probe_loop(port, deadline, output) do
    if String.contains?(output, "--model") do
      safe_port_close(port)
      :model_flag_seen
    else
      now = System.monotonic_time(:millisecond)
      remaining_ms = max(deadline - now, 0)

      if remaining_ms == 0 do
        safe_port_close(port)
        :timeout
      else
        receive do
          {^port, {:data, {:eol, line}}} ->
            help_probe_loop(port, deadline, bounded_help_probe_output(output, line <> "\n"))

          {^port, {:data, {:noeol, chunk}}} ->
            help_probe_loop(port, deadline, bounded_help_probe_output(output, chunk))

          {^port, {:exit_status, _status}} ->
            output
        after
          remaining_ms ->
            safe_port_close(port)
            :timeout
        end
      end
    end
  end

  defp bounded_help_probe_output(output, chunk) do
    combined = output <> chunk
    combined_size = byte_size(combined)

    if combined_size <= @help_probe_line_bytes do
      combined
    else
      binary_part(combined, combined_size - @help_probe_line_bytes, @help_probe_line_bytes)
    end
  end

  defp help_output_model_status(:model_flag_seen), do: :ok

  defp help_output_model_status(output) when is_binary(output) do
    if String.contains?(output, "--model"), do: :ok, else: :unsupported
  end

  defp help_output_model_status(_output), do: :unsupported

  defp safe_port_close(port) do
    os_pid = port_os_pid(port)
    descendant_pids = descendant_pids(os_pid)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    catch
      :error, :badarg -> :ok
    after
      terminate_pids(Enum.reverse(descendant_pids))
      terminate_process_group(os_pid)
      terminate_pid(os_pid)
    end
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _info -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp descendant_pids(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> parse_pids()
        |> Enum.flat_map(fn child_pid -> descendant_pids(child_pid) ++ [child_pid] end)

      _result ->
        []
    end
  rescue
    _error -> []
  end

  defp descendant_pids(_pid), do: []

  defp parse_pids(output) do
    output
    |> String.split(~r/\s+/, trim: true)
    |> Enum.flat_map(fn pid ->
      case Integer.parse(pid) do
        {parsed, ""} when parsed > 0 -> [parsed]
        _invalid -> []
      end
    end)
  end

  defp terminate_pids(pids), do: Enum.each(pids, &terminate_pid/1)

  defp terminate_pid(pid) when is_integer(pid) and pid > 0 do
    System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp terminate_pid(_pid), do: :ok

  defp terminate_process_group(pid) when is_integer(pid) and pid > 0 do
    System.cmd("kill", ["--", "-#{pid}"], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp terminate_process_group(_pid), do: :ok

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
         %{provider_ref_kind: provider_ref_kind, provider_ref: thread_id, resumable?: true},
         cli_opts
       )
       when provider_ref_kind in ["thread_id", :thread_id, "session_id", :session_id] and is_binary(thread_id) do
    CLI.resume(thread_id, prompt, workspace, cli_opts)
  end

  defp invoke_cli(_prompt, _workspace, %{resumable?: false} = run_ref, _cli_opts),
    do: {:error, {:resume_unsupported, run_ref}}

  defp invoke_cli(_prompt, _workspace, run_ref, _cli_opts), do: {:error, {:invalid_resume_ref, run_ref}}

  defp run_ref_from_cli_result(%{thread_id: thread_id}, _previous_run_ref) when is_binary(thread_id) do
    Adapter.run_ref(@id, thread_id, "thread_id", true)
  end

  defp run_ref_from_cli_result(_cli_result, previous_run_ref), do: previous_run_ref

  defp handle_stream_event(raw_event, stream_state_key, on_event, capabilities) do
    case normalize_event(raw_event) do
      %{event_type: :ignore} ->
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
    StreamParser.assistant_text(raw_event)
  end

  defp normalize_event(raw_event) when is_map(raw_event) do
    thread_id = StreamParser.extract_thread_id(raw_event)
    run_ref = if thread_id, do: Adapter.run_ref(@id, thread_id, "thread_id", true)

    event_type = normalized_event_type(raw_event)

    event_type
    |> Adapter.event(
      adapter: @id,
      run_ref: run_ref,
      usage: StreamParser.extract_usage(raw_event),
      raw: raw_event,
      message: normalized_message(raw_event),
      diff: normalized_diff(raw_event)
    )
  end

  defp normalized_event_type(%{"type" => "thread.started"}), do: :session_started
  defp normalized_event_type(%{"type" => "turn.started"}), do: :turn_started
  defp normalized_event_type(%{"type" => "turn.completed"}), do: :invocation_completed
  defp normalized_event_type(%{"type" => "turn.failed"}), do: :invocation_failed
  defp normalized_event_type(%{"type" => "error"}), do: :invocation_failed
  defp normalized_event_type(%{"type" => "item.started"} = payload), do: item_event_type(payload, :started)
  defp normalized_event_type(%{"type" => "item.updated"} = payload), do: item_event_type(payload, :updated)
  defp normalized_event_type(%{"type" => "item.completed"} = payload), do: item_event_type(payload, :completed)
  defp normalized_event_type(_payload), do: :warning

  defp item_event_type(payload, phase) do
    case item_type(payload) do
      "agent_message" when phase == :completed -> :assistant_message
      "command_execution" -> tool_event_type(phase)
      "mcp_tool_call" -> tool_event_type(phase)
      "collab_tool_call" -> tool_event_type(phase)
      "file_change" -> :diff_updated
      _ -> :ignore
    end
  end

  defp tool_event_type(:started), do: :tool_started
  defp tool_event_type(:updated), do: :tool_updated
  defp tool_event_type(:completed), do: :tool_completed

  defp normalized_message(%{"type" => "turn.failed"} = payload) do
    error = Map.get(payload, "error") || Map.get(payload, :error) || %{}
    error_message(error)
  end

  defp normalized_message(%{"type" => "error"} = payload) do
    error_message(payload)
  end

  defp normalized_message(%{"type" => "item.started"} = payload), do: StreamParser.item_message(item_payload(payload))
  defp normalized_message(%{"type" => "item.updated"} = payload), do: StreamParser.item_message(item_payload(payload))
  defp normalized_message(%{"type" => "item.completed"} = payload), do: StreamParser.item_message(item_payload(payload))
  defp normalized_message(_payload), do: nil

  defp normalized_diff(%{"type" => "item.started"} = payload), do: diff_payload(payload)
  defp normalized_diff(%{"type" => "item.updated"} = payload), do: diff_payload(payload)
  defp normalized_diff(%{"type" => "item.completed"} = payload), do: diff_payload(payload)
  defp normalized_diff(_payload), do: nil

  defp diff_payload(payload) do
    item = item_payload(payload)

    case item_type(item) do
      "file_change" ->
        %{
          changes: map_get_any(item, ["changes", :changes]) || [],
          status: map_get_any(item, ["status", :status])
        }

      _ ->
        nil
    end
  end

  defp item_payload(payload) do
    Map.get(payload, "item") || payload
  end

  defp item_type(%{"item" => %{} = item}), do: item_type(item)
  defp item_type(%{"type" => type}) when is_binary(type), do: type
  defp item_type(_payload), do: nil

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(_payload), do: "codex error"

  defp map_get_any(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key -> if is_binary(key), do: Map.get(map, key), else: nil end)
  end
end
