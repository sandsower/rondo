defmodule Rondo.Gates do
  @moduledoc """
  Runs deterministic workflow gates inside an issue workspace and persists results.
  """

  alias Rondo.{Config, PathSafety}

  @results_path "artifacts/gates/results.json"
  @shell_timeout_exit_status 124
  @command_not_found_exit_status 127

  @type gate :: Config.gate()
  @type gate_status :: :pass | :fail | :error | :timeout
  @type gate_result :: %{
          name: String.t(),
          command: String.t(),
          status: gate_status(),
          retryable: boolean(),
          environment_failure: boolean(),
          exit_status: integer() | nil,
          duration_ms: non_neg_integer(),
          cwd: Path.t(),
          stdout_path: Path.t(),
          stderr_path: Path.t()
        }
  @type summary :: %{
          status: gate_status(),
          results_path: Path.t(),
          results: [gate_result()]
        }

  @spec run([gate()], Path.t(), keyword()) :: {:ok, summary()} | {:error, summary() | term()}
  def run(gates, workspace, opts \\ []) when is_list(gates) and is_binary(workspace) do
    run_dir = Keyword.fetch!(opts, :run_dir)

    with {:ok, workspace} <- validate_workspace(workspace),
         :ok <- File.mkdir_p(gates_dir(run_dir)) do
      results = gates |> Enum.with_index(1) |> Enum.map(fn {gate, index} -> run_gate(gate, index, workspace, run_dir) end)
      summary = build_summary(results, @results_path)

      case write_results(run_dir, summary) do
        :ok -> result_tuple(summary)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec summary_to_json(summary()) :: map()
  def summary_to_json(summary) when is_map(summary) do
    %{
      status: summary.status,
      results_path: summary.results_path,
      results: Enum.map(summary.results, &gate_result_to_json/1)
    }
  end

  defp validate_workspace(workspace) do
    with {:ok, workspace_root} <- PathSafety.canonicalize(Config.workspace_root()),
         {:ok, workspace} <- PathSafety.canonicalize(workspace),
         true <- under_root?(workspace, workspace_root) do
      {:ok, workspace}
    else
      false -> {:error, {:invalid_workspace_cwd, :outside_root}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp under_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp run_gate(gate, index, workspace, run_dir) do
    name = Map.fetch!(gate, :name)
    command = Map.fetch!(gate, :command)
    timeout_ms = Map.fetch!(gate, :timeout_ms)
    safe_name = indexed_safe_name(name, index)
    stdout_path = Path.join("artifacts/gates", "#{safe_name}-stdout.log")
    stderr_path = Path.join("artifacts/gates", "#{safe_name}-stderr.log")
    stdout_abs = Path.join(run_dir, stdout_path)
    stderr_abs = Path.join(run_dir, stderr_path)
    exit_abs = Path.join(gates_dir(run_dir), "#{safe_name}-exit-status")
    started_ms = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        File.rm(exit_abs)
        shell = gate_shell(command, stdout_abs, stderr_abs, exit_abs)
        {_output, exit_status} = System.cmd("sh", ["-lc", shell], cd: workspace, stderr_to_stdout: true)
        exit_status
      end)

    status = await_gate(task, timeout_ms, exit_abs)
    duration_ms = System.monotonic_time(:millisecond) - started_ms

    build_result(name, command, status, duration_ms, workspace, stdout_path, stderr_path)
  end

  defp gate_shell(command, stdout_abs, stderr_abs, exit_abs) do
    """
    ( #{command} ) > #{shell_escape(stdout_abs)} 2> #{shell_escape(stderr_abs)}
    code=$?
    printf '%s' "$code" > #{shell_escape(exit_abs)}
    exit "$code"
    """
  end

  defp await_gate(task, timeout_ms, exit_abs) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, exit_status} ->
        classify_exit(exit_status)

      nil ->
        %{status: :timeout, exit_status: read_exit_status(exit_abs) || @shell_timeout_exit_status}
    end
  end

  defp classify_exit(0), do: %{status: :pass, exit_status: 0}
  defp classify_exit(@command_not_found_exit_status), do: %{status: :error, exit_status: @command_not_found_exit_status}
  defp classify_exit(exit_status) when is_integer(exit_status), do: %{status: :fail, exit_status: exit_status}

  defp read_exit_status(path) do
    with {:ok, contents} <- File.read(path),
         {exit_status, _rest} <- Integer.parse(String.trim(contents)) do
      exit_status
    else
      _ -> nil
    end
  end

  defp build_result(name, command, %{status: status, exit_status: exit_status}, duration_ms, workspace, stdout_path, stderr_path) do
    %{
      name: name,
      command: command,
      status: status,
      retryable: retryable?(status),
      environment_failure: environment_failure?(status),
      exit_status: exit_status,
      duration_ms: max(duration_ms, 0),
      cwd: workspace,
      stdout_path: stdout_path,
      stderr_path: stderr_path
    }
  end

  defp retryable?(status) when status in [:error, :timeout], do: true
  defp retryable?(_status), do: false

  defp environment_failure?(status) when status in [:error, :timeout], do: true
  defp environment_failure?(_status), do: false

  defp build_summary(results, results_path) do
    %{status: overall_status(results), results_path: results_path, results: results}
  end

  defp overall_status(results) do
    cond do
      Enum.all?(results, &(&1.status == :pass)) -> :pass
      Enum.any?(results, &(&1.status == :timeout)) -> :timeout
      Enum.any?(results, &(&1.status == :error)) -> :error
      true -> :fail
    end
  end

  defp write_results(run_dir, summary) do
    path = Path.join(run_dir, @results_path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(summary_to_json(summary)) do
      File.write(path, json)
    end
  end

  defp result_tuple(%{status: :pass} = summary), do: {:ok, summary}
  defp result_tuple(summary), do: {:error, summary}

  defp gate_result_to_json(result) do
    %{
      name: result.name,
      command: result.command,
      status: result.status,
      retryable: result.retryable,
      environment_failure: result.environment_failure,
      exit_status: result.exit_status,
      duration_ms: result.duration_ms,
      cwd: result.cwd,
      stdout_path: result.stdout_path,
      stderr_path: result.stderr_path
    }
  end

  defp gates_dir(run_dir), do: Path.join(run_dir, "artifacts/gates")

  defp indexed_safe_name(name, index) when is_integer(index) and index > 0 do
    index_prefix = index |> Integer.to_string() |> String.pad_leading(4, "0")
    "#{index_prefix}-#{safe_name(name)}"
  end

  defp safe_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "gate"
      safe -> safe
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
