defmodule Rondo.CLI do
  @moduledoc """
  Escript entrypoint for running Rondo with an explicit WORKFLOW.md path.
  """

  alias Rondo.{LogFile, RunOnce}

  @switches [logs_root: :string, port: :integer, debug: :boolean]
  @run_once_switches @switches ++ [issue: :string, manifest: :string, unsafe_child_credential_bypass: :boolean]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type evaluate_result :: :ok | :run_once_completed | {:error, String.t()}
  @type deps :: %{
          required(:file_regular?) => (String.t() -> boolean()),
          required(:set_workflow_file_path) => (String.t() -> :ok | {:error, term()}),
          required(:set_logs_root) => (String.t() -> :ok | {:error, term()}),
          required(:set_server_port_override) => (non_neg_integer() | nil -> :ok | {:error, term()}),
          required(:ensure_all_started) => (-> ensure_started_result()),
          optional(:ensure_run_once_dependencies_started) => (-> ensure_started_result()),
          required(:run_once) => (String.t(), keyword() -> :ok | {:error, term()}),
          required(:run_manifest) => (String.t(), keyword() -> :ok | {:error, term()})
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      :run_once_completed ->
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: evaluate_result()
  def evaluate(args, deps \\ runtime_deps()) do
    case parse_args(args) do
      {:run_once, opts, [workflow_path]} ->
        with :ok <- require_run_once_target(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_debug(opts),
             :ok <- run_once(workflow_path, opts, deps) do
          :run_once_completed
        end

      {:run_once, _opts, _argv} ->
        {:error, usage_message()}

      {opts, [], []} ->
        with :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- maybe_set_debug(opts) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- maybe_set_debug(opts) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @type parse_result ::
          {keyword(), [String.t()], [{String.t(), String.t() | nil}]} | {:run_once, keyword(), [String.t()]}

  @spec parse_args([String.t()]) :: parse_result()
  defp parse_args(["run-once" | rest]) do
    if duplicate_run_once_flags?(rest) do
      {[], [], [{"run-once", "duplicate target flag"}]}
    else
      case OptionParser.parse(rest, strict: @run_once_switches) do
        {opts, argv, []} -> {:run_once, opts, argv}
        {_opts, _argv, invalid} -> {[], [], invalid}
      end
    end
  end

  defp parse_args(args), do: OptionParser.parse(args, strict: @switches)

  defp duplicate_run_once_flags?(args) do
    Enum.count(args, &target_flag?(&1, "--issue")) > 1 or Enum.count(args, &target_flag?(&1, "--manifest")) > 1
  end

  defp target_flag?(arg, flag), do: arg == flag or String.starts_with?(arg, flag <> "=")

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Rondo with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec run_once(String.t(), keyword(), deps()) :: :ok | {:error, String.t()}
  defp run_once(workflow_path, opts, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case ensure_run_once_dependencies_started(deps) do
        {:ok, _started_apps} ->
          run_once_target(opts, deps)

        {:error, reason} ->
          {:error, "Failed to start run-once dependencies for workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  defp run_once_target(opts, deps) do
    case run_once_target_values(opts) do
      {issue_id, nil} when is_binary(issue_id) ->
        run_opts = [
          agent_opts: [
            dispatch_origin: :run_once,
            unsafe_child_credential_bypass: Keyword.get(opts, :unsafe_child_credential_bypass, false)
          ]
        ]

        case invoke_runner(Map.get(deps, :run_once, &RunOnce.run/2), issue_id, run_opts) do
          :ok -> :ok
          {:error, reason} -> {:error, "run-once failed for issue #{issue_id}: #{inspect(reason)}"}
        end

      {nil, manifest_path} when is_binary(manifest_path) ->
        run_once_manifest(manifest_path, opts, deps)

      _ ->
        {:error, usage_message()}
    end
  end

  defp run_once_manifest(manifest_path, opts, deps) do
    expanded_manifest_path = Path.expand(manifest_path)

    run_opts = [
      agent_opts: [
        dispatch_origin: :manifest,
        unsafe_child_credential_bypass: Keyword.get(opts, :unsafe_child_credential_bypass, false)
      ]
    ]

    case invoke_runner(Map.get(deps, :run_manifest, &RunOnce.run_manifest/2), expanded_manifest_path, run_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, "run-once failed for manifest #{expanded_manifest_path}: #{inspect(reason)}"}
    end
  end

  defp invoke_runner(runner, target, opts) when is_function(runner, 2), do: runner.(target, opts)
  defp invoke_runner(_runner, _target, _opts), do: {:error, :invalid_runner_contract}

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: rondo [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]\n       rondo run-once [--logs-root <path>] [--unsafe-child-credential-bypass] <path-to-WORKFLOW.md> (--issue <id> | --manifest <path>)"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &Rondo.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:rondo) end,
      ensure_run_once_dependencies_started: &ensure_run_once_dependency_applications_started/0,
      run_once: &RunOnce.run/2,
      run_manifest: &RunOnce.run_manifest/2
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  @spec require_run_once_target(keyword()) :: :ok | {:error, String.t()}
  defp require_run_once_target(opts) do
    case run_once_target_values(opts) do
      {issue, nil} when is_binary(issue) -> :ok
      {nil, manifest} when is_binary(manifest) -> :ok
      _ -> {:error, usage_message()}
    end
  end

  defp run_once_target_values(opts) do
    with {:ok, issue} <- one_target_value(opts, :issue),
         {:ok, manifest} <- one_target_value(opts, :manifest) do
      {issue, manifest}
    end
  end

  defp one_target_value(opts, key) do
    case Keyword.get_values(opts, key) do
      [] -> {:ok, nil}
      [value] -> {:ok, normalize_target_value(value)}
      _values -> {:error, {:duplicate_run_once_target, key}}
    end
  end

  defp normalize_target_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_target_value(_value), do: nil

  defp ensure_run_once_dependencies_started(deps) do
    Map.get(deps, :ensure_run_once_dependencies_started, &ensure_run_once_dependency_applications_started/0).()
  end

  defp ensure_run_once_dependency_applications_started do
    with :ok <- load_rondo_application(),
         applications when is_list(applications) <- Application.spec(:rondo, :applications) do
      ensure_applications_started(applications)
    else
      nil -> {:error, :missing_rondo_application_spec}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_rondo_application do
    case Application.load(:rondo) do
      :ok -> :ok
      {:error, {:already_loaded, :rondo}} -> :ok
      {:error, reason} -> {:error, {:rondo_application_load_failed, reason}}
    end
  end

  defp ensure_applications_started(applications) do
    Enum.reduce_while(applications, {:ok, []}, fn application, {:ok, started} ->
      case Application.ensure_all_started(application) do
        {:ok, newly_started} -> {:cont, {:ok, started ++ newly_started}}
        {:error, reason} -> {:halt, {:error, {application, reason}}}
      end
    end)
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:rondo, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp maybe_set_debug(opts) do
    if Keyword.get(opts, :debug, false) do
      Rondo.Config.set_debug(true)
    end

    :ok
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:rondo, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(Rondo.Supervisor) do
      nil ->
        IO.puts(:stderr, "Rondo supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
