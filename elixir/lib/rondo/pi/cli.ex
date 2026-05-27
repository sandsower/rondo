defmodule Rondo.Pi.CLI do
  @moduledoc """
  Spawns `pi --mode json` subprocesses and streams JSON events back to the caller.
  """

  require Logger
  alias Rondo.{Config, PathSafety}
  alias Rondo.Pi.StreamParser

  @port_line_bytes 1_048_576
  @max_log_bytes 1_000

  @type run_result :: %{
          session_id: String.t() | nil,
          exit_code: integer(),
          usage: map() | nil
        }

  @doc """
  Run a first-turn pi JSON session with the given prompt.
  """
  @spec run(String.t(), Path.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(prompt, workspace, opts \\ []) do
    args = build_first_turn_args(prompt)
    execute(args, workspace, opts)
  end

  @doc """
  Resume an existing pi session by id or path with continuation guidance.
  """
  @spec resume(String.t(), String.t(), Path.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def resume(session_id, prompt, workspace, opts \\ []) do
    args = build_resume_args(session_id, prompt)
    execute(args, workspace, opts)
  end

  defp execute(args, workspace, opts) do
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, Config.pi_turn_timeout_ms())
    stall_timeout_ms = Keyword.get(opts, :stall_timeout_ms, Config.pi_stall_timeout_ms())

    with :ok <- validate_workspace(workspace) do
      command = Config.pi_command()

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
    full_line = String.trim_trailing(state.buffer <> line, "\r")
    state = %{state | buffer: ""}

    case StreamParser.parse_line(full_line) do
      {:ok, event} ->
        session_id = StreamParser.extract_session_id(event) || state.session_id
        usage = StreamParser.extract_usage(event) || state.usage
        on_event.(event)
        %{state | session_id: session_id, usage: usage}

      {:error, reason} ->
        Logger.debug("Unparseable pi stream line: #{inspect(reason)} line=#{String.slice(full_line, 0, @max_log_bytes)}")

        state
    end
  end

  defp build_first_turn_args(prompt), do: ["--mode", "json", prompt]
  defp build_resume_args(session_id, prompt), do: ["--mode", "json", "--session", session_id, prompt]

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

    case :os.type() do
      {:unix, :linux} ->
        "exec script -qfec #{shell_escape(inner_command)} /dev/null"

      {:unix, _} ->
        "exec script -q /dev/null /bin/sh -c #{shell_escape(inner_command)}"
    end
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
