defmodule Rondo.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Claude agents.
  """

  require Logger
  alias Rondo.Config
  alias Rondo.PathSafety
  alias Rondo.RemoteShell
  alias Rondo.SideEffectPolicy

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])

  @spec create_for_issue(map() | String.t() | nil, keyword()) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, opts \\ []) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id),
           :ok <- validate_workspace_path(workspace, opts),
           {:ok, created?} <- ensure_workspace(workspace, issue_context, opts),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, opts) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, issue_context, opts) do
    fresh? = Keyword.get(opts, :fresh, false)
    remote? = remote_workspace?(opts)

    cond do
      remote? -> ensure_remote_workspace(workspace, issue_context, opts, fresh?)
      fresh? -> ensure_fresh_workspace(workspace, issue_context, opts)
      File.dir?(workspace) -> ensure_clean_workspace(workspace, issue_context, opts)
      File.exists?(workspace) -> ensure_stale_workspace_removed(workspace, issue_context, opts)
      true -> create_workspace(workspace, issue_context, opts)
    end
  end

  defp ensure_remote_workspace(workspace, issue_context, opts, fresh?) do
    if fresh? do
      with :ok <- authorize_workspace_action(:remove, workspace, issue_context, opts),
           :ok <- remove_workspace_dir(workspace, opts) do
        create_workspace(workspace, issue_context, opts)
      end
    else
      create_workspace(workspace, issue_context, opts)
    end
  end

  defp ensure_fresh_workspace(workspace, issue_context, opts) do
    if File.dir?(workspace) do
      with :ok <- authorize_workspace_action(:remove, workspace, issue_context, opts),
           :ok <- remove_workspace_dir(workspace, opts) do
        create_workspace(workspace, issue_context, opts)
      end
    else
      ensure_stale_workspace_removed(workspace, issue_context, opts)
    end
  end

  defp ensure_clean_workspace(workspace, issue_context, opts) do
    with :ok <- clean_tmp_artifacts(workspace, issue_context, opts) do
      {:ok, false}
    end
  end

  defp ensure_stale_workspace_removed(workspace, issue_context, opts) do
    with :ok <- authorize_workspace_action(:remove_stale_path, workspace, issue_context, opts),
         {:ok, _removed} <- File.rm_rf(workspace) do
      create_workspace(workspace, issue_context, opts)
    end
  end

  defp remove_workspace_dir(workspace, opts) do
    if remote_workspace?(opts) do
      case RemoteShell.run("rm -rf #{RemoteShell.shell_escape(workspace)}", opts) do
        {_output, 0} -> :ok
        result -> result
      end
    else
      case File.rm_rf(workspace) do
        {:ok, _removed} -> :ok
        error -> error
      end
    end
  end

  defp create_workspace(workspace, issue_context, opts) do
    with :ok <- authorize_workspace_action(:create, workspace, issue_context, opts),
         :ok <- create_workspace_dir(workspace, opts) do
      {:ok, true}
    end
  end

  defp create_workspace_dir(workspace, opts) do
    if remote_workspace?(opts) do
      case RemoteShell.run("mkdir -p #{RemoteShell.shell_escape(workspace)}", opts) do
        {_output, 0} -> :ok
        result -> result
      end
    else
      File.mkdir_p(workspace)
    end
  end

  @spec remove(Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()} | {:error, term(), String.t()}
  def remove(workspace, opts \\ []) do
    if remote_workspace?(opts) or File.exists?(workspace) do
      remove_existing_workspace(workspace, opts)
    else
      File.rm_rf(workspace)
    end
  end

  @spec verify_clean(Path.t(), keyword()) :: {:ok, :clean | :dirty} | {:error, term()}
  def verify_clean(workspace, opts \\ []) when is_binary(workspace) do
    case RemoteShell.run_in_workspace("git status --porcelain --untracked-files=all", workspace, opts) do
      {output, 0} ->
        if String.trim(output) == "" do
          {:ok, :clean}
        else
          {:ok, :dirty}
        end

      {output, status} ->
        {:error, {:workspace_clean_check_failed, status, output}}
    end
  end

  defp remove_existing_workspace(workspace, opts) do
    case validate_workspace_path(workspace, opts) do
      :ok -> remove_validated_workspace(workspace, opts)
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp remove_validated_workspace(workspace, opts) do
    issue_context = %{issue_id: nil, issue_identifier: Path.basename(workspace)}

    with :ok <- authorize_workspace_action(:remove, workspace, issue_context, opts),
         :ok <- maybe_run_before_remove_hook(workspace, opts),
         :ok <- remove_workspace_dir(workspace, opts) do
      if remote_workspace?(opts), do: {:ok, []}, else: File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, [])

  @spec remove_issue_workspaces(term(), keyword()) :: :ok
  def remove_issue_workspaces(identifier, opts) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id) do
      {:ok, workspace} -> remove(workspace, opts)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _opts) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, keyword()) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, opts \\ []) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:before_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", opts)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, keyword()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, opts \\ []) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:after_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", opts)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Config.workspace_root()
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp clean_tmp_artifacts(workspace, issue_context, opts) do
    cleanup_targets =
      @excluded_entries
      |> MapSet.to_list()
      |> Enum.map(&Path.join(workspace, &1))
      |> Enum.filter(&(remote_workspace?(opts) or File.exists?(&1)))

    if cleanup_targets == [] do
      :ok
    else
      with :ok <- authorize_workspace_action(:cleanup_tmp, workspace, issue_context, opts) do
        clean_tmp_targets(cleanup_targets, opts)
      end
    end
  end

  defp clean_tmp_targets(cleanup_targets, opts) do
    if remote_workspace?(opts) do
      case Enum.map_join(cleanup_targets, " ", &RemoteShell.shell_escape/1) do
        "" -> :ok
        paths -> RemoteShell.run("rm -rf #{paths}", opts)
      end
    else
      Enum.each(cleanup_targets, &File.rm_rf/1)
      :ok
    end
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, opts) do
    case created? do
      true ->
        case Config.workspace_hooks()[:after_create] do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", opts)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, opts) do
    if remote_workspace?(opts) or File.dir?(workspace) do
      case Config.workspace_hooks()[:before_remove] do
        nil ->
          :ok

        command ->
          run_hook(
            command,
            workspace,
            %{issue_id: nil, issue_identifier: Path.basename(workspace)},
            "before_remove",
            opts
          )
          |> ignore_optional_hook_failure()
      end
    else
      :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp ignore_optional_hook_failure(:ok), do: :ok
  defp ignore_optional_hook_failure({:error, {:action_policy_guidance_required, _interrupt} = reason}), do: {:error, reason}
  defp ignore_optional_hook_failure({:error, {:action_policy_denied, _envelope} = reason}), do: {:error, reason}
  defp ignore_optional_hook_failure({:error, {:action_policy_failed, _failure} = reason}), do: {:error, reason}
  defp ignore_optional_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, opts) do
    timeout_ms = Config.workspace_hooks()[:timeout_ms]
    command = interpolate_hook_command(command, workspace, issue_context)

    with :ok <- authorize_hook(workspace, issue_context, hook_name, opts) do
      Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

      task =
        Task.async(fn ->
          RemoteShell.run_in_workspace(command, workspace, opts)
        end)

      case Task.yield(task, timeout_ms) do
        {:ok, cmd_result} ->
          handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

        nil ->
          Task.shutdown(task, :brutal_kill)

          Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

          {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
      end
    end
  end

  defp authorize_hook(workspace, issue_context, hook_name, opts) do
    side_effect = %{
      action: "workspace.hook.#{hook_name}",
      classes: ["workspace-write"],
      label: "Workspace #{hook_name} hook",
      operation: "Run configured #{hook_name} workspace hook",
      required: hook_required?(hook_name),
      resume_safe: false,
      skip_behavior: hook_skip_behavior(hook_name),
      side_effect_id: "workspace-hook:#{hook_name}:#{issue_context.issue_identifier}"
    }

    case evaluate_side_effect(side_effect, workspace, opts) do
      {:ok, _decision} ->
        :ok

      {:blocked, %{block_reason: :action_policy_requires_guidance, interrupt: interrupt}} ->
        {:error, {:action_policy_guidance_required, interrupt}}

      {:blocked, %{block_reason: :action_policy_denied, envelope: envelope}} ->
        {:error, {:action_policy_denied, envelope}}

      {:blocked, %{block_reason: {:action_policy_failed, reason}}} ->
        {:error, {:action_policy_failed, reason}}
    end
  end

  defp authorize_workspace_action(action, workspace, issue_context, opts) do
    side_effect = workspace_side_effect(action, issue_context)

    case evaluate_side_effect(side_effect, workspace, opts) do
      {:ok, _decision} ->
        :ok

      {:blocked, %{block_reason: :action_policy_requires_guidance, interrupt: interrupt}} ->
        {:error, {:action_policy_guidance_required, interrupt}}

      {:blocked, %{block_reason: :action_policy_denied, envelope: envelope}} ->
        {:error, {:action_policy_denied, envelope}}

      {:blocked, %{block_reason: {:action_policy_failed, reason}}} ->
        {:error, {:action_policy_failed, reason}}
    end
  end

  defp workspace_side_effect(:create, issue_context) do
    %{
      action: "workspace.lifecycle.create",
      classes: ["workspace-write"],
      label: "Workspace create",
      operation: "Create workspace for #{issue_context.issue_identifier}",
      required: true,
      resume_safe: false,
      skip_behavior: "abort",
      side_effect_id: "workspace-create:#{issue_context.issue_identifier}"
    }
  end

  defp workspace_side_effect(:cleanup_tmp, issue_context) do
    %{
      action: "workspace.cleanup.tmp",
      classes: ["workspace-write", "destructive"],
      label: "Workspace temporary artifact cleanup",
      operation: "Remove temporary artifacts for #{issue_context.issue_identifier}",
      required: false,
      resume_safe: false,
      skip_behavior: "continue",
      side_effect_id: "workspace-cleanup-tmp:#{issue_context.issue_identifier}"
    }
  end

  defp workspace_side_effect(:remove_stale_path, issue_context) do
    %{
      action: "workspace.lifecycle.remove_stale_path",
      classes: ["workspace-write", "destructive"],
      label: "Workspace stale path removal",
      operation: "Remove stale non-directory workspace path for #{issue_context.issue_identifier}",
      required: true,
      resume_safe: false,
      skip_behavior: "abort",
      side_effect_id: "workspace-remove-stale:#{issue_context.issue_identifier}"
    }
  end

  defp workspace_side_effect(:remove, issue_context) do
    %{
      action: "workspace.lifecycle.remove",
      classes: ["workspace-write", "destructive"],
      label: "Workspace removal",
      operation: "Remove workspace for #{issue_context.issue_identifier}",
      required: true,
      resume_safe: false,
      skip_behavior: "abort",
      side_effect_id: "workspace-remove:#{issue_context.issue_identifier}"
    }
  end

  defp evaluate_side_effect(side_effect, workspace, opts) do
    policy_opts = Keyword.take(opts, [:evaluator, :ledger, :mode, :command, :now, :resume, :timeout_ms, :policy_file])
    SideEffectPolicy.evaluate(side_effect, Keyword.put(policy_opts, :workspace, workspace))
  end

  defp hook_required?(hook_name), do: hook_name in ["after_create", "before_run"]
  defp hook_skip_behavior(hook_name) when hook_name in ["after_run", "before_remove"], do: "continue"
  defp hook_skip_behavior(_hook_name), do: "abort"

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, opts) when is_binary(workspace) do
    if remote_workspace?(opts) do
      validate_remote_workspace_path(workspace)
    else
      validate_local_workspace_path(workspace)
    end
  end

  defp validate_remote_workspace_path(workspace) do
    if String.trim(workspace) == "" do
      {:error, {:workspace_path_unreadable, workspace, :empty}}
    else
      :ok
    end
  end

  defp validate_local_workspace_path(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.workspace_root())
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      validate_workspace_paths(canonical_workspace, canonical_root, expanded_workspace, expanded_root_prefix)
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_paths(canonical_workspace, canonical_root, expanded_workspace, expanded_root_prefix) do
    canonical_root_prefix = canonical_root <> "/"

    cond do
      canonical_workspace == canonical_root ->
        {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

      String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
        :ok

      String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
        {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

      true ->
        {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
    end
  end

  defp interpolate_hook_command(command, workspace, issue_context) do
    command
    |> String.replace("{{ workspace.path }}", shell_escape(workspace))
    |> String.replace("{{ issue.identifier }}", shell_escape(issue_context.issue_identifier))
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp remote_workspace?(opts) do
    RemoteShell.enabled?(opts)
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
