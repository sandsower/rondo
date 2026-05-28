defmodule Rondo.ActionPolicy do
  @moduledoc """
  Thin adapter for Beislið's deterministic action-policy evaluator.

  Rondo owns orchestration boundaries and durable evidence, but Beislið owns the
  policy vocabulary and decision table. This module shells out to
  `beislid action-policy evaluate`, validates the returned envelope, and maps
  Rondo workspace state into Beislið sandbox-status flags.
  """

  alias Rondo.{Config, PathSafety}

  @decisions ["allow", "ask", "deny"]
  @classes [
    "read",
    "workspace-write",
    "dependency-install",
    "network-read",
    "git-local",
    "git-remote",
    "destructive",
    "secret-bearing"
  ]
  @baselines ["none", "non-default-branch", "separate-worktree", "host-sandbox"]

  @type envelope :: map()
  @type sandbox_status :: %{
          baseline: String.t(),
          default_branch: boolean(),
          uncommitted_changes: boolean()
        }

  @spec evaluate(String.t(), [String.t()], keyword()) :: {:ok, envelope()} | {:error, term()}
  def evaluate(action, classes, opts \\ []) when is_binary(action) and is_list(classes) do
    command = Keyword.get(opts, :command, Config.action_policy_command())
    mode = Keyword.get(opts, :mode, Config.action_policy_run_mode())
    sandbox_status = Keyword.get_lazy(opts, :sandbox_status, fn -> sandbox_status(Keyword.get(opts, :workspace)) end)

    with :ok <- validate_classes(classes),
         :ok <- validate_baseline(Map.fetch!(sandbox_status, :baseline)),
         {:ok, output} <- run_evaluator(command, evaluator_args(mode, action, classes, sandbox_status)) do
      decode_envelope(output)
    end
  end

  @spec authorize(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def authorize(action, classes, opts \\ []) do
    case evaluate(action, classes, opts) do
      {:ok, %{"decision" => "allow"}} -> :ok
      {:ok, %{"decision" => "ask"} = envelope} -> {:error, {:action_policy_requires_approval, envelope}}
      {:ok, %{"decision" => "deny"} = envelope} -> {:error, {:action_policy_denied, envelope}}
      {:error, reason} -> {:error, {:action_policy_failed, reason}}
    end
  end

  @spec sandbox_status(Path.t() | nil) :: sandbox_status()
  def sandbox_status(nil) do
    %{baseline: "none", default_branch: false, uncommitted_changes: false}
  end

  def sandbox_status(workspace) when is_binary(workspace) do
    baseline = sandbox_baseline(workspace)

    %{
      baseline: baseline,
      default_branch: git_default_branch?(workspace),
      uncommitted_changes: git_uncommitted_changes?(workspace)
    }
  end

  defp evaluator_args(mode, action, classes, sandbox_status) do
    ["action-policy", "evaluate", "--mode", mode, "--action", action]
    |> Kernel.++(Enum.flat_map(classes, &["--class", &1]))
    |> Kernel.++(["--sandbox-baseline", sandbox_status.baseline])
    |> maybe_add_flag(sandbox_status.default_branch, "--default-branch")
    |> maybe_add_flag(sandbox_status.uncommitted_changes, "--uncommitted-changes")
  end

  defp maybe_add_flag(args, true, flag), do: args ++ [flag]
  defp maybe_add_flag(args, _false, _flag), do: args

  defp run_evaluator(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:evaluator_exit, status, String.trim(output)}}
    end
  rescue
    error in ErlangError -> {:error, {:evaluator_unavailable, Exception.message(error)}}
  end

  defp decode_envelope(output) do
    with {:ok, envelope} when is_map(envelope) <- Jason.decode(output),
         :ok <- validate_envelope(envelope) do
      {:ok, envelope}
    else
      {:ok, _other} -> {:error, :invalid_evaluator_envelope}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_evaluator_json, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_envelope(%{"decision" => decision, "action" => action, "mode" => mode})
       when decision in @decisions and is_binary(action) and is_binary(mode),
       do: :ok

  defp validate_envelope(_envelope), do: {:error, :invalid_evaluator_envelope}

  defp validate_classes(classes) do
    case Enum.find(classes, &(&1 not in @classes)) do
      nil -> :ok
      invalid -> {:error, {:invalid_action_class, invalid}}
    end
  end

  defp validate_baseline(baseline) when baseline in @baselines, do: :ok
  defp validate_baseline(baseline), do: {:error, {:invalid_sandbox_baseline, baseline}}

  defp sandbox_baseline(workspace) do
    with {:ok, root} <- PathSafety.canonicalize(Config.workspace_root()),
         {:ok, workspace} <- PathSafety.canonicalize(workspace) do
      cond do
        workspace == root -> "non-default-branch"
        String.starts_with?(workspace <> "/", root <> "/") -> "separate-worktree"
        true -> "none"
      end
    else
      _ -> "none"
    end
  end

  defp git_default_branch?(workspace) do
    with {branch, 0} <- System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: workspace, stderr_to_stdout: true),
         {default_branch, 0} <- System.cmd("git", ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], cd: workspace, stderr_to_stdout: true) do
      String.trim(branch) == String.trim(String.replace(default_branch, "origin/", ""))
    else
      _ -> false
    end
  end

  defp git_uncommitted_changes?(workspace) do
    case System.cmd("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _other -> false
    end
  end
end
