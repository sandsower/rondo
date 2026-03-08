defmodule SymphonyElixir.Claude.CLI do
  @moduledoc """
  Spawns Claude Code CLI subprocesses and streams events back to the caller.
  """

  require Logger
  alias SymphonyElixir.Claude.StreamParser
  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576
  @max_log_bytes 1_000

  @type run_result :: %{
          session_id: String.t() | nil,
          exit_code: integer(),
          usage: map() | nil
        }

  @doc """
  Run a first-turn Claude Code session with the given prompt.
  """
  @spec run(String.t(), Path.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(prompt, workspace, opts \\ []) do
    args = build_first_turn_args(prompt, workspace)
    execute(args, workspace, opts)
  end

  @doc """
  Resume an existing Claude Code session with continuation guidance.
  """
  @spec resume(String.t(), String.t(), Path.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def resume(session_id, prompt, workspace, opts \\ []) do
    args = build_resume_args(session_id, prompt, workspace)
    execute(args, workspace, opts)
  end

  defp execute(args, workspace, opts) do
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, Config.claude_turn_timeout_ms())
    stall_timeout_ms = Keyword.get(opts, :stall_timeout_ms, Config.claude_stall_timeout_ms())

    with :ok <- validate_workspace(workspace) do
      command = Config.claude_command()
      {cmd, cmd_args} = parse_command(command, args)

      # Erlang ports cannot read stdout and stderr as separate streams, so we
      # merge them with :stderr_to_stdout. The spec says stderr is diagnostics
      # only, not part of the protocol. Non-JSON stderr lines hit the
      # {:error, {:json_parse_error, ...}} branch in handle_line/3 and are
      # quietly logged at debug level, so they don't corrupt state. If Claude
      # Code ever emits JSON-shaped diagnostics on stderr this could be a
      # problem, but in practice its stderr is plain text.
      #
      # We wrap the command via /bin/sh so the child runs in a new process
      # group. safe_port_close/1 sends SIGTERM to the entire group via
      # `kill -- -$PID`, preventing orphan Claude processes when Symphony
      # exits or the agent is terminated.
      wrapper_args = ["-c", build_wrapper_script(cmd, cmd_args)]
      port =
        Port.open(
          {:spawn_executable, "/bin/sh"},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, @port_line_bytes},
            {:cd, Path.expand(workspace)},
            {:args, wrapper_args},
            {:env, [{~c"CLAUDECODE", false}]}
          ]
        )

      now = System.monotonic_time(:millisecond)
      deadline = now + turn_timeout_ms
      stall_deadline = now + stall_timeout_ms

      try do
        stream_loop(port, deadline, stall_deadline, stall_timeout_ms, on_event, %{
          session_id: nil,
          usage: nil,
          buffer: ""
        })
      catch
        :exit, reason ->
          safe_port_close(port)
          {:error, {:subprocess_exit, reason}}
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
            {:ok,
             %{
               session_id: state.session_id,
               exit_code: 0,
               usage: state.usage
             }}

          {^port, {:exit_status, code}} ->
            {:error, {:subprocess_exit, code}}
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
    # Strip trailing \r from PTY line discipline (script wrapper adds \r\n)
    full_line = String.trim_trailing(state.buffer <> line, "\r")
    state = %{state | buffer: ""}

    case StreamParser.parse_line(full_line) do
      {:ok, event} ->
        session_id = StreamParser.extract_session_id(event) || state.session_id
        usage = StreamParser.extract_usage(event) || state.usage
        on_event.(event)
        %{state | session_id: session_id, usage: usage}

      {:error, reason} ->
        Logger.debug(
          "Unparseable stream line: #{inspect(reason)} line=#{String.slice(full_line, 0, @max_log_bytes)}"
        )

        state
    end
  end

  defp build_first_turn_args(prompt, _workspace) do
    base = [
      "-p",
      prompt,
      "--verbose",
      "--output-format",
      Config.claude_output_format(),
      "--max-turns",
      to_string(Config.claude_max_turns()),
      "--permission-mode",
      Config.claude_permission_mode()
    ]

    base
    |> maybe_add_flag(Config.claude_dangerously_skip_permissions?(), "--dangerously-skip-permissions")
    |> maybe_add_option(Config.claude_model(), "--model")
    |> maybe_add_allowed_tools(Config.claude_allowed_tools())
  end

  defp build_resume_args(session_id, prompt, _workspace) do
    base = [
      "--resume",
      session_id,
      "-p",
      prompt,
      "--verbose",
      "--output-format",
      Config.claude_output_format(),
      "--max-turns",
      to_string(Config.claude_max_turns()),
      "--permission-mode",
      Config.claude_permission_mode()
    ]

    base
    |> maybe_add_flag(Config.claude_dangerously_skip_permissions?(), "--dangerously-skip-permissions")
  end

  defp maybe_add_flag(args, true, flag), do: args ++ [flag]
  defp maybe_add_flag(args, _, _flag), do: args

  defp maybe_add_option(args, nil, _opt), do: args
  defp maybe_add_option(args, value, opt), do: args ++ [opt, value]

  defp maybe_add_allowed_tools(args, nil), do: args
  defp maybe_add_allowed_tools(args, []), do: args

  defp maybe_add_allowed_tools(args, tools) when is_list(tools) do
    Enum.reduce(tools, args, fn tool, acc -> acc ++ ["--allowedTools", tool] end)
  end

  defp parse_command(command, extra_args) do
    parts = String.split(command, ~r/\s+/, trim: true)

    {cmd, cmd_args} =
      case parts do
        [cmd | rest] -> {cmd, rest ++ extra_args}
        [] -> {"claude", extra_args}
      end

    resolved_cmd = System.find_executable(cmd) || cmd
    {resolved_cmd, cmd_args}
  end

  defp validate_workspace(workspace) do
    expanded = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())

    cond do
      !File.dir?(expanded) -> {:error, {:invalid_workspace_cwd, :not_a_directory}}
      !String.starts_with?(expanded, root) -> {:error, {:invalid_workspace_cwd, :outside_root}}
      true -> :ok
    end
  end

  defp safe_port_close(port) do
    # Extract the OS PID before closing the port so we can kill the process group.
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

    # Kill the entire process group rooted at the wrapper shell.
    # The wrapper runs with `exec` so the Claude process inherits the PID.
    if is_integer(os_pid) and os_pid > 0 do
      System.cmd("kill", ["--", "-#{os_pid}"], stderr_to_stdout: true)
    end
  rescue
    ArgumentError -> :ok
  catch
    :error, :badarg -> :ok
  end

  defp build_wrapper_script(cmd, args) do
    # Shell-escape each argument, then exec the command.
    # exec replaces the shell so the process inherits the shell's PID/PGID,
    # making `kill -- -$PID` reach the entire tree.
    #
    # We wrap with `script -qfec` to allocate a PTY. Without this, Node.js
    # (which powers the Claude CLI) fully buffers stdout when writing to a pipe,
    # and stream-json events only appear when the internal buffer fills (~64KB)
    # or the process exits. The PTY tricks Node into line-buffering.
    escaped_args =
      Enum.map_join([cmd | args], " ", fn arg ->
        "'" <> String.replace(arg, "'", "'\\''") <> "'"
      end)

    "exec script -qfec #{shell_escape(escaped_args)} /dev/null"
  end

  defp shell_escape(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end
end
