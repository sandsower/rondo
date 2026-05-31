defmodule Rondo.CLI do
  @moduledoc """
  Escript entrypoint for running Rondo with an explicit WORKFLOW.md path.
  """

  alias Rondo.{LogFile, RunOnce}

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer, debug: :boolean]
  @run_once_switches @switches ++ [issue: :string, manifest: :string]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type evaluate_result :: :ok | :run_once_completed | {:error, String.t()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result()),
          run_once: (String.t() -> :ok | {:error, term()}),
          run_manifest: (Path.t() -> :ok | {:error, term()})
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
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- maybe_set_debug(opts) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- maybe_set_debug(opts) do
          run(workflow_path, deps)
        end

      {:run_once, opts, [workflow_path]} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- require_run_once_target(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_debug(opts),
             :ok <- run_once(workflow_path, opts, deps) do
          :run_once_completed
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @type parse_result ::
          {keyword(), [String.t()], [{String.t(), String.t() | nil}]} | {:run_once, keyword(), [String.t()]}

  @spec parse_args([String.t()]) :: parse_result()
  defp parse_args(["run-once" | rest]) do
    case OptionParser.parse(rest, strict: @run_once_switches) do
      {opts, argv, []} -> {:run_once, opts, argv}
      {_opts, _argv, invalid} -> {[], [], invalid}
    end
  end

  defp parse_args(args), do: OptionParser.parse(args, strict: @switches)

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
      run_once_target(opts, deps)
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  defp run_once_target(opts, deps) do
    case run_once_target_values(opts) do
      {issue_id, nil} when is_binary(issue_id) ->
        case Map.get(deps, :run_once, &RunOnce.run/1).(issue_id) do
          :ok -> :ok
          {:error, reason} -> {:error, "run-once failed for issue #{issue_id}: #{inspect(reason)}"}
        end

      {nil, manifest_path} when is_binary(manifest_path) ->
        expanded_manifest_path = Path.expand(manifest_path)

        case Map.get(deps, :run_manifest, &RunOnce.run_manifest/1).(expanded_manifest_path) do
          :ok -> :ok
          {:error, reason} -> {:error, "run-once failed for manifest #{expanded_manifest_path}: #{inspect(reason)}"}
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: rondo [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]\n       rondo run-once [--logs-root <path>] <path-to-WORKFLOW.md> (--issue <id> | --manifest <path>)"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &Rondo.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:rondo) end,
      run_once: &RunOnce.run/1,
      run_manifest: &RunOnce.run_manifest/1
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
    {normalize_target_value(Keyword.get(opts, :issue)), normalize_target_value(Keyword.get(opts, :manifest))}
  end

  defp normalize_target_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_target_value(_value), do: nil

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Rondo implementation is a low key engineering preview.",
      "Claude will run without any guardrails.",
      "Rondo is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
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
