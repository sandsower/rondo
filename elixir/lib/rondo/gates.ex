defmodule Rondo.Gates do
  @moduledoc """
  Runs deterministic workflow gates inside an issue workspace and persists results.
  """

  alias Rondo.{ActionPolicy, Config, PathSafety}

  @results_filename "results.json"
  @state_filename "state.json"
  @shell_timeout_exit_status 124
  @command_not_found_exit_status 127
  @reused_status :reused

  @type gate :: Config.gate()
  @type gate_status :: :pass | :reused | :fail | :error | :timeout | :policy_blocked | :policy_denied
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
          optional(:gate_selection) => map(),
          optional(:workspace_identity) => map(),
          optional(:gate_signature) => String.t(),
          optional(:state_path) => Path.t(),
          optional(:reused_from) => map()
        }

  @spec run([gate()], Path.t(), keyword()) :: {:ok, summary()} | {:error, summary() | term()}
  def run(gates, workspace, opts \\ []) when is_list(gates) and is_binary(workspace) do
    run_dir = Keyword.fetch!(opts, :run_dir)
    execution_id = Keyword.get(opts, :execution_id)
    gates_dir = Keyword.get(opts, :gates_dir) || "artifacts/gates"
    relative_gates_dir = relative_gates_dir(gates_dir, execution_id)
    results_path = Path.join(relative_gates_dir, @results_filename)
    state_path = Path.join(gates_dir, @state_filename)
    gate_selection = Keyword.get(opts, :gate_selection)

    with {:ok, workspace} <- validate_workspace(workspace),
         :ok <- File.mkdir_p(Path.join(run_dir, relative_gates_dir)) do
      execute_gate_flow(
        gates,
        workspace,
        run_dir,
        relative_gates_dir,
        results_path,
        state_path,
        gate_selection,
        opts
      )
    end
  end

  defp execute_gate_flow(
         gates,
         workspace,
         run_dir,
         relative_gates_dir,
         results_path,
         state_path,
         gate_selection,
         opts
       ) do
    policy_opts = action_policy_opts(opts, workspace)
    reuse_enabled = Keyword.get(opts, :gate_reuse_enabled, Config.gate_reuse_enabled?())
    workspace_identity = workspace_identity(workspace)
    gate_signature = gate_signature(gates, policy_opts)

    summary =
      case maybe_reused_summary(
             run_dir,
             workspace_identity,
             gate_signature,
             results_path,
             state_path,
             gate_selection,
             reuse_enabled
           ) do
        {:ok, reused_summary} ->
          reused_summary

        :run ->
          results =
            gates
            |> Enum.with_index(1)
            |> Enum.map(fn {gate, index} ->
              run_gate(gate, index, workspace, run_dir, relative_gates_dir, policy_opts)
            end)

          build_summary(results, results_path, state_path, gate_selection, workspace_identity, gate_signature)
      end

    with :ok <- write_results(run_dir, summary),
         :ok <- write_gate_state(run_dir, summary) do
      result_tuple(summary)
    end
  end

  @spec summary_to_json(summary()) :: map()
  def summary_to_json(summary) when is_map(summary) do
    %{
      status: summary.status,
      results_path: summary.results_path,
      state_path: Map.get(summary, :state_path),
      workspace_identity: Map.get(summary, :workspace_identity),
      gate_signature: Map.get(summary, :gate_signature),
      results: Enum.map(summary.results, &gate_result_to_json/1),
      gate_selection: Map.get(summary, :gate_selection),
      reused_from: Map.get(summary, :reused_from)
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
          %{status: policy_block_status(reason), exit_status: nil},
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

  defp build_summary(results, results_path, state_path, gate_selection, workspace_identity, gate_signature) do
    %{
      status: overall_status(results),
      results_path: results_path,
      state_path: state_path,
      workspace_identity: workspace_identity,
      gate_signature: gate_signature,
      results: results,
      gate_selection: gate_selection
    }
    |> drop_nil_values()
  end

  defp build_reused_summary(
         previous_state,
         results_path,
         state_path,
         gate_selection,
         workspace_identity,
         gate_signature
       ) do
    reused_from =
      %{
        status: state_value(previous_state, :status),
        results_path: state_value(previous_state, :results_path),
        workspace_identity: normalize_workspace_identity(state_value(previous_state, :workspace_identity)),
        gate_signature: state_value(previous_state, :gate_signature)
      }
      |> drop_nil_values()

    %{
      status: @reused_status,
      results_path: results_path,
      state_path: state_path,
      workspace_identity: workspace_identity,
      gate_signature: gate_signature,
      results: [],
      gate_selection: gate_selection,
      reused_from: reused_from
    }
    |> drop_nil_values()
  end

  defp maybe_reused_summary(run_dir, workspace_identity, gate_signature, results_path, state_path, gate_selection, true) do
    gate_state_path = Path.join(run_dir, state_path)

    case load_gate_state(gate_state_path) do
      {:ok, previous_state} ->
        if reusable_gate_state?(previous_state, workspace_identity, gate_signature) do
          {:ok,
           build_reused_summary(
             previous_state,
             results_path,
             state_path,
             gate_selection,
             workspace_identity,
             gate_signature
           )}
        else
          :run
        end

      _ ->
        :run
    end
  end

  defp maybe_reused_summary(_run_dir, _workspace_identity, _gate_signature, _results_path, _state_path, _gate_selection, false), do: :run

  defp load_gate_state(path) do
    with true <- File.exists?(path),
         {:ok, json} <- File.read(path),
         {:ok, state} <- Jason.decode(json) do
      {:ok, state}
    else
      _ -> :error
    end
  end

  defp reusable_gate_state?(state, workspace_identity, gate_signature) when is_map(state) do
    status = state_value(state, :status)

    status in [:pass, "pass", @reused_status, "reused"] and
      normalize_workspace_identity(state_value(state, :workspace_identity)) == workspace_identity and
      state_value(state, :gate_signature) == gate_signature
  end

  defp reusable_gate_state?(_state, _workspace_identity, _gate_signature), do: false

  defp overall_status(results) do
    cond do
      Enum.all?(results, &(&1.status == :pass)) -> :pass
      Enum.any?(results, &(&1.status == :policy_denied)) -> :policy_denied
      Enum.any?(results, &(&1.status == :policy_blocked)) -> :policy_blocked
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

  defp write_gate_state(run_dir, summary) do
    path = Path.join(run_dir, summary.state_path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(summary_to_json(summary)) do
      File.write(path, json)
    end
  end

  defp result_tuple(%{status: status} = summary) when status in [:pass, @reused_status], do: {:ok, summary}
  defp result_tuple(summary), do: {:error, summary}

  defp state_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_workspace_identity(nil), do: nil

  defp normalize_workspace_identity(identity) when is_map(identity) do
    %{
      head: state_value(identity, :head),
      tree_hash: state_value(identity, :tree_hash)
    }
    |> drop_nil_values()
  end

  defp workspace_identity(workspace) do
    %{
      head: git_head(workspace),
      tree_hash: workspace_tree_hash(workspace)
    }
    |> drop_nil_values()
  end

  defp git_head(workspace) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp workspace_tree_hash(workspace) do
    workspace
    |> workspace_tree_entries(workspace)
    |> Enum.sort()
    |> then(fn entries -> hash_string(Enum.join(entries, "\n")) end)
  end

  defp workspace_tree_entries(path, root) do
    rel = Path.relative_to(path, root)

    if ignored_workspace_path?(rel) do
      []
    else
      workspace_tree_entries_for_path(path, rel, root)
    end
  end

  defp workspace_tree_entries_for_path(path, rel, root) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        workspace_directory_entries(path, rel, root, mode)

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        [tree_entry(rel, "regular", Integer.to_string(mode), file_hash(path))]

      {:ok, %File.Stat{type: :symlink, mode: mode}} ->
        [tree_entry(rel, "symlink", Integer.to_string(mode), symlink_hash(path))]

      {:ok, %File.Stat{type: type, mode: mode}} ->
        [tree_entry(rel, Atom.to_string(type), Integer.to_string(mode), nil)]
    end
  end

  defp workspace_directory_entries(path, rel, root, mode) do
    directory_entry = tree_entry(rel, "directory", Integer.to_string(mode), nil)

    case File.ls(path) do
      {:ok, entries} ->
        [
          directory_entry
          | entries
            |> Enum.sort()
            |> Enum.flat_map(&workspace_tree_entries(Path.join(path, &1), root))
        ]

      {:error, reason} ->
        [directory_entry, tree_entry(rel, "directory-error", inspect(reason), nil)]
    end
  end

  defp ignored_workspace_path?(rel) do
    case Path.split(rel) do
      [".git" | _] -> true
      [".rondo_runs" | _] -> true
      _ -> false
    end
  end

  defp tree_entry(rel, type, meta, hash) do
    [rel, type, normalize_tree_value(meta), normalize_tree_value(hash)]
    |> Enum.join("\0")
  end

  defp normalize_tree_value(nil), do: ""
  defp normalize_tree_value(value), do: value

  defp file_hash(path) do
    case File.read(path) do
      {:ok, contents} -> hash_string(contents)
      _ -> "unreadable"
    end
  end

  defp symlink_hash(path) do
    {:ok, target} = File.read_link(path)
    hash_string(target)
  end

  defp hash_string(contents) when is_binary(contents) do
    :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
  end

  defp gate_signature(gates, policy_opts) do
    [
      {:gates, Enum.map(gates, &canonical_gate/1)},
      {:policy, canonical_policy_signature(policy_opts)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> :erlang.term_to_binary()
    |> hash_string()
  end

  defp canonical_gate(gate) when is_map(gate) do
    [
      {:name, Map.get(gate, :name)},
      {:command, Map.get(gate, :command)},
      {:timeout_ms, Map.get(gate, :timeout_ms)},
      {:action_id, Map.get(gate, :action_id)},
      {:action_classes, Map.get(gate, :action_classes, [])}
    ]
  end

  defp canonical_policy_signature(false), do: nil

  defp canonical_policy_signature(policy_opts) when is_list(policy_opts) do
    [
      {:enabled, true},
      {:command, Keyword.get(policy_opts, :command)},
      {:mode, Keyword.get(policy_opts, :mode)},
      {:sandbox_status, Keyword.get(policy_opts, :sandbox_status)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

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

  defp policy_block_status({:action_policy_blocked, decision}) when decision in ["ask", :ask], do: :policy_blocked
  defp policy_block_status({:action_policy_blocked, decision}) when decision in ["deny", :deny], do: :policy_denied
  defp policy_block_status(_reason), do: :error

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

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
