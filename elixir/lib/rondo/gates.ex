defmodule Rondo.Gates do
  @moduledoc """
  Runs deterministic workflow gates inside an issue workspace and persists results.
  """

  alias Rondo.{ActionPolicy, Config, PathSafety}

  @results_filename "results.json"
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
          required(:status) => gate_status(),
          required(:results_path) => Path.t(),
          required(:results) => [gate_result()],
          optional(:gate_selection) => map()
        }

  @spec run([gate()], Path.t(), keyword()) :: {:ok, summary()} | {:error, summary() | term()}
  def run(gates, workspace, opts \\ []) when is_list(gates) and is_binary(workspace) do
    run_dir = Keyword.fetch!(opts, :run_dir)
    execution_id = Keyword.get(opts, :execution_id)
    relative_gates_dir = relative_gates_dir(Keyword.get(opts, :gates_dir), execution_id)
    results_path = Path.join(relative_gates_dir, @results_filename)
    gate_selection = Keyword.get(opts, :gate_selection)

    with {:ok, workspace} <- validate_workspace(workspace),
         :ok <- File.mkdir_p(Path.join(run_dir, relative_gates_dir)) do
      policy_opts = action_policy_opts(opts, workspace)

      results =
        gates
        |> Enum.with_index(1)
        |> Enum.map(fn {gate, index} -> run_gate(gate, index, workspace, run_dir, relative_gates_dir, policy_opts) end)

      summary = build_summary(results, results_path, gate_selection)

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
      results: Enum.map(summary.results, &gate_result_to_json/1),
      gate_selection: Map.get(summary, :gate_selection)
    }
    |> drop_nil_values()
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

  defp run_gate(gate, index, workspace, run_dir, relative_gates_dir, policy_opts) do
    name = Map.fetch!(gate, :name)
    command = Map.fetch!(gate, :command)
    timeout_ms = Map.fetch!(gate, :timeout_ms)
    safe_name = indexed_safe_name(name, index)
    stdout_path = Path.join(relative_gates_dir, "#{safe_name}-stdout.log")
    stderr_path = Path.join(relative_gates_dir, "#{safe_name}-stderr.log")
    stdout_abs = Path.join(run_dir, stdout_path)
    stderr_abs = Path.join(run_dir, stderr_path)
    exit_abs = Path.join(run_dir, Path.join(relative_gates_dir, "#{safe_name}-exit-status"))
    started_ms = System.monotonic_time(:millisecond)

    case evaluate_gate_policy(gate, policy_opts) do
      {:ok, policy_decision} ->
        task =
          Task.async(fn ->
            File.rm(exit_abs)
            shell = gate_shell(command, stdout_abs, stderr_abs, exit_abs)
            {_output, exit_status} = System.cmd("sh", ["-lc", shell], cd: workspace, stderr_to_stdout: true)
            exit_status
          end)

        status = await_gate(task, timeout_ms, exit_abs)
        duration_ms = System.monotonic_time(:millisecond) - started_ms

        build_result(name, command, status, duration_ms, workspace, stdout_path, stderr_path, policy_decision)

      {:error, reason, policy_decision} ->
        duration_ms = System.monotonic_time(:millisecond) - started_ms

        build_result(
          name,
          command,
          %{status: :error, exit_status: nil},
          duration_ms,
          workspace,
          stdout_path,
          stderr_path,
          blocked_policy_decision(reason, policy_decision)
        )
    end
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
    case Task.yield(task, timeout_ms) do
      {:ok, exit_status} ->
        classify_exit(exit_status)

      nil ->
        Task.shutdown(task, :brutal_kill)
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

  defp build_result(name, command, %{status: status, exit_status: exit_status}, duration_ms, workspace, stdout_path, stderr_path, policy_decision) do
    %{
      name: name,
      command: command,
      status: status,
      retryable: retryable?(status, policy_decision),
      environment_failure: environment_failure?(status, policy_decision),
      exit_status: exit_status,
      duration_ms: max(duration_ms, 0),
      cwd: workspace,
      stdout_path: stdout_path,
      stderr_path: stderr_path,
      policy_decision: policy_decision
    }
    |> drop_nil_values()
  end

  defp retryable?(status, policy_decision) do
    cond do
      is_map(policy_decision) and blocked_policy_decision?(policy_decision) -> false
      status in [:error, :timeout] -> true
      true -> false
    end
  end

  defp environment_failure?(status, policy_decision) do
    cond do
      is_map(policy_decision) and blocked_policy_decision?(policy_decision) -> false
      status in [:error, :timeout] -> true
      true -> false
    end
  end

  defp blocked_policy_decision?(policy_decision) do
    Map.get(policy_decision, :side_effect_status) == :blocked or Map.get(policy_decision, "side_effect_status") == "blocked"
  end

  defp build_summary(results, results_path, gate_selection) do
    %{status: overall_status(results), results_path: results_path, results: results, gate_selection: gate_selection}
    |> drop_nil_values()
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
    path = Path.join(run_dir, summary.results_path)

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
      exit_status: Map.get(result, :exit_status),
      duration_ms: result.duration_ms,
      cwd: result.cwd,
      stdout_path: result.stdout_path,
      stderr_path: result.stderr_path,
      policy_decision: Map.get(result, :policy_decision)
    }
    |> drop_nil_values()
  end

  defp action_policy_opts(opts, workspace) do
    if Keyword.get(opts, :action_policy, false) do
      [
        workspace: workspace,
        command: Keyword.get(opts, :action_policy_command, Config.action_policy_command()),
        evaluator: Keyword.get(opts, :action_policy_evaluator, &ActionPolicy.evaluate/3),
        mode: Keyword.get(opts, :action_policy_run_mode, Config.action_policy_run_mode()),
        sandbox_status: Keyword.get_lazy(opts, :sandbox_status, fn -> ActionPolicy.sandbox_status(workspace) end)
      ]
    else
      false
    end
  end

  defp evaluate_gate_policy(_gate, false), do: {:ok, nil}

  defp evaluate_gate_policy(gate, policy_opts) do
    name = Map.fetch!(gate, :name)
    classes = Map.get(gate, :action_classes, [])
    action = Map.get(gate, :action_id) || default_gate_action_id(name, classes)

    evaluator = Keyword.get(policy_opts, :evaluator, &ActionPolicy.evaluate/3)

    case evaluator.(action, classes, policy_opts) do
      {:ok, envelope} ->
        evaluate_gate_policy_envelope(envelope)

      {:error, reason} ->
        {:error, {:action_policy_failed, reason}, nil}
    end
  end

  defp evaluate_gate_policy_envelope(%{"decision" => "allow", "action" => action, "mode" => mode} = envelope)
       when is_binary(action) and is_binary(mode),
       do: {:ok, envelope}

  defp evaluate_gate_policy_envelope(%{"decision" => decision, "action" => action, "mode" => mode} = envelope)
       when decision in ["ask", "deny"] and is_binary(action) and is_binary(mode),
       do: {:error, {:action_policy_blocked, decision}, envelope}

  defp evaluate_gate_policy_envelope(envelope), do: {:error, {:action_policy_failed, :invalid_evaluator_envelope}, envelope}

  defp default_gate_action_id(_name, ["read"]), do: "file.read"
  defp default_gate_action_id(name, _classes), do: "gate." <> safe_name(name)

  defp blocked_policy_decision(reason, nil), do: %{side_effect_status: :blocked, reason: inspect(reason)}

  defp blocked_policy_decision(reason, envelope) do
    envelope
    |> Map.put("side_effect_status", "blocked")
    |> Map.put("block_reason", inspect(reason))
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp relative_gates_dir(nil, execution_id), do: relative_gates_dir("artifacts/gates", execution_id)
  defp relative_gates_dir(gates_dir, nil) when is_binary(gates_dir), do: gates_dir

  defp relative_gates_dir(gates_dir, execution_id) when is_binary(gates_dir) and is_binary(execution_id) do
    Path.join(gates_dir, safe_name(execution_id))
  end

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
