defmodule Rondo.Codex.CLI do
  @moduledoc """
  Spawns `codex exec --json` subprocesses and streams JSON events back to the caller.
  """

  require Logger
  alias Rondo.Codex.StreamParser
  alias Rondo.Config
  alias Rondo.PathSafety

  @port_line_bytes 1_048_576

  @type run_result :: %{
          thread_id: String.t() | nil,
          session_id: String.t() | nil,
          exit_code: integer(),
          usage: map() | nil
        }

  @doc """
  Run a first-turn codex JSON session with the given prompt.
  """
  @spec run(String.t(), Path.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(prompt, workspace, opts \\ []) do
    args = build_first_turn_args(prompt, opts)
    execute(args, workspace, opts)
  end

  @doc """
  Resume an existing codex thread by id with continuation guidance.
  """
  @spec resume(String.t(), String.t(), Path.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def resume(thread_id, prompt, workspace, opts \\ []) do
    args = build_resume_args(thread_id, prompt, opts)
    execute(args, workspace, opts)
  end

  defp execute(args, workspace, opts) do
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, Config.codex_turn_timeout_ms())
    stall_timeout_ms = Keyword.get(opts, :stall_timeout_ms, Config.codex_stall_timeout_ms())

    with :ok <- validate_workspace(workspace) do
      command = Config.codex_command()

      with {:ok, spawn_target, spawn_args} <- spawn_invocation(command, args) do
        port =
          Port.open(
            {:spawn_executable, spawn_target},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              {:line, @port_line_bytes},
              {:cd, Path.expand(workspace)},
              {:args, spawn_args}
            ]
          )

        now = System.monotonic_time(:millisecond)
        deadline = now + turn_timeout_ms
        stall_deadline = now + stall_timeout_ms

        try do
          stream_loop(port, deadline, stall_deadline, stall_timeout_ms, on_event, %{
            thread_id: nil,
            usage: nil,
            buffer: "",
            failure_lines: [],
            final_report: nil
          })
        rescue
          exception ->
            safe_port_close(port)
            reraise exception, __STACKTRACE__
        catch
          :exit, reason ->
            safe_port_close(port)
            {:error, {:subprocess_exit, reason}}
        end
      end
    end
  end

  defp stream_loop(port, deadline, stall_deadline, stall_timeout_ms, on_event, state) do
    now = System.monotonic_time(:millisecond)
    remaining_ms = max(min(deadline - now, stall_deadline - now), 0)

    cond do
      now >= deadline ->
        safe_port_close(port)
        {:error, :turn_timeout}

      now >= stall_deadline ->
        safe_port_close(port)
        {:error, :stall_timeout}

      true ->
        receive do
          {^port, {:data, {:eol, line}}} ->
            state = handle_line(line, on_event, state)
            new_stall_deadline = System.monotonic_time(:millisecond) + stall_timeout_ms
            stream_loop(port, deadline, new_stall_deadline, stall_timeout_ms, on_event, state)

          {^port, {:data, {:noeol, chunk}}} ->
            new_stall_deadline = System.monotonic_time(:millisecond) + stall_timeout_ms
            stream_loop(port, deadline, new_stall_deadline, stall_timeout_ms, on_event, %{state | buffer: state.buffer <> chunk})

          {^port, {:exit_status, 0}} ->
            state = flush_buffer(on_event, drain_port_data(port, on_event, state))

            {:ok,
             %{
               thread_id: state.thread_id,
               session_id: state.thread_id,
               exit_code: 0,
               usage: state.usage
             }}

          {^port, {:exit_status, code}} ->
            state = flush_buffer(on_event, drain_port_data(port, on_event, state))
            {:error, {:subprocess_exit, code, Enum.reverse(state.failure_lines)}}
        after
          remaining_ms ->
            safe_port_close(port)

            if System.monotonic_time(:millisecond) >= deadline do
              {:error, :turn_timeout}
            else
              {:error, :stall_timeout}
            end
        end
    end
  end

  defp handle_line(line, on_event, state) do
    full_line = String.trim_trailing(state.buffer <> line, "\r")
    state = %{state | buffer: ""}

    case StreamParser.parse_line(full_line) do
      {:ok, event} ->
        thread_id = StreamParser.extract_thread_id(event) || state.thread_id
        usage = StreamParser.extract_usage(event) || state.usage
        final_report = StreamParser.assistant_text(event) || state.final_report

        if Map.get(event, :event_type) != :ignore do
          on_event.(event)
        end

        %{state | thread_id: thread_id, usage: usage, final_report: final_report}

      {:error, reason} ->
        Logger.metadata(parse_error_metadata(state))
        Logger.debug("Unparseable codex stream line: reason=#{inspect(reason)} bytes=#{byte_size(full_line)}")

        %{state | failure_lines: record_failure_line(state.failure_lines, full_line)}
    end
  end

  defp record_failure_line(failure_lines, line) when is_list(failure_lines) and is_binary(line) do
    if provider_failure_line?(line) do
      [line | failure_lines] |> Enum.take(5)
    else
      failure_lines
    end
  end

  defp record_failure_line(failure_lines, _line), do: failure_lines

  defp provider_failure_line?(line) when is_binary(line) do
    normalized = String.downcase(line)

    Regex.match?(
      ~r/(usage limit has been reached|usage limit exceeded|rate limit(?:ed| exceeded| exhausted)?|quota(?: exhausted| exceeded| reached)?|insufficient credits?|credit(?:s)?(?: exhausted| depleted| limit reached| limit has been reached)|subscription(?: expired| exhausted| limit reached)?)/i,
      normalized
    )
  end

  defp parse_error_metadata(state) do
    [
      adapter: "codex",
      thread_id: state.thread_id
    ]
  end

  defp drain_port_data(port, on_event, state) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        drain_port_data(port, on_event, handle_line(line, on_event, state))

      {^port, {:data, {:noeol, chunk}}} ->
        drain_port_data(port, on_event, %{state | buffer: state.buffer <> chunk})
    after
      0 -> state
    end
  end

  defp flush_buffer(_on_event, %{buffer: ""} = state), do: state
  defp flush_buffer(on_event, state), do: handle_line("", on_event, state)

  defp build_first_turn_args(prompt, opts), do: ["exec", "--json"] |> maybe_add_model(opts) |> Kernel.++([prompt])
  defp build_resume_args(thread_id, prompt, opts), do: ["exec", "--json", "resume", thread_id] |> maybe_add_model(opts) |> Kernel.++([prompt])

  defp maybe_add_model(args, opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> args ++ ["--model", model]
      _model -> args
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

  defp safe_port_close(port) do
    os_pid =
      try do
        {:os_pid, pid} = Port.info(port, :os_pid)
        pid
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    Port.close(port)

    if is_integer(os_pid) and os_pid > 0 do
      System.cmd("kill", ["--", "-#{os_pid}"], stderr_to_stdout: true)
    end
  rescue
    ArgumentError -> :ok
  catch
    :error, :badarg -> :ok
  end

  defp spawn_invocation(command, args) do
    case :os.type() do
      {:win32, _} ->
        {:error, {:unsupported_platform, :windows_shell_command}}

      _ ->
        {spawn_target, spawn_args} = unix_shell_invocation(build_wrapper_script(command, args))
        {:ok, spawn_target, spawn_args}
    end
  end

  defp unix_shell_invocation(script) do
    case System.find_executable("bash") do
      nil -> {"/bin/sh", ["-c", script]}
      bash -> {bash, ["-c", script]}
    end
  end

  defp build_wrapper_script(command, args) do
    inner_command = shell_command_with_args(command, args)
    "exec #{inner_command}"
  end

  defp shell_command_with_args(command, args) do
    escaped_args = Enum.map_join(args, " ", &shell_escape/1)

    [command, escaped_args]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp shell_escape(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end
end
