defmodule Rondo.ChangedFiles do
  @moduledoc """
  Collects changed file paths from a workspace for provider-backed gate selection.

  The collector is intentionally small and git-backed for v1. It compares the
  current workspace to the run-start base commit when available, and also includes
  staged, unstaged, and untracked paths so post-turn gate selection sees the edit
  batch before final patch-artifact capture.
  """

  alias Rondo.RunLedger

  @type snapshot :: %{
          required(:changed_files) => [String.t()],
          required(:source) => String.t(),
          optional(:base_ref) => String.t(),
          optional(:head_ref) => String.t(),
          optional(:run_dir) => Path.t()
        }

  @type runner :: ([String.t()], Path.t() -> {String.t(), non_neg_integer()})

  @doc "Collects changed paths for `workspace`."
  @spec collect(Path.t(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def collect(workspace, opts \\ []) when is_binary(workspace) do
    runner = Keyword.get(opts, :runner, &run_git/2)

    cond do
      !File.dir?(workspace) ->
        {:ok, %{changed_files: [], source: "missing_workspace"}}

      !git_repo?(runner, workspace) ->
        {:ok, %{changed_files: [], source: "not_git_repo"}}

      true ->
        collect_from_git(workspace, runner, opts)
    end
  end

  defp collect_from_git(workspace, runner, opts) do
    case git(runner, workspace, ["rev-parse", "HEAD"]) do
      {:ok, head_output} ->
        head_ref = String.trim(head_output)
        base_ref = base_ref(workspace, runner, head_ref, opts)

        with {:ok, committed_paths} <- committed_paths(runner, workspace, base_ref, head_ref),
             {:ok, staged_paths} <- git_paths(runner, workspace, ["diff", "--name-only", "--cached"]),
             {:ok, unstaged_paths} <- git_paths(runner, workspace, ["diff", "--name-only"]),
             {:ok, untracked_paths} <- git_paths(runner, workspace, ["ls-files", "--others", "--exclude-standard"]) do
          changed_files = normalize_paths(committed_paths ++ staged_paths ++ unstaged_paths ++ untracked_paths)

          {:ok,
           %{
             changed_files: changed_files,
             source: "git_diff",
             base_ref: base_ref,
             head_ref: head_ref
           }
           |> maybe_put_run_dir(opts)}
        end

      {:error, _status, _output} ->
        {:ok, %{changed_files: [], source: "git_no_commits"}}
    end
  end

  defp base_ref(workspace, runner, head_ref, opts) do
    explicit_ref = Keyword.get(opts, :base_ref)
    manifest_ref = opts |> Keyword.get(:run_dir) |> manifest_base_ref()

    [explicit_ref, manifest_ref, head_ref]
    |> Enum.find(head_ref, fn ref -> valid_ref?(ref, runner, workspace) end)
  end

  defp manifest_base_ref(nil), do: nil

  defp manifest_base_ref(run_dir) when is_binary(run_dir) do
    case RunLedger.load_manifest(run_dir) do
      {:ok, manifest} -> get_in(manifest, ["repo", "base_commit"])
      {:error, _reason} -> nil
    end
  end

  defp valid_ref?(ref, runner, workspace) when is_binary(ref) and ref != "" do
    match?({:ok, _output}, git(runner, workspace, ["cat-file", "-e", ref <> "^{commit}"]))
  end

  defp valid_ref?(_ref, _runner, _workspace), do: false

  defp committed_paths(_runner, _workspace, base_ref, base_ref), do: {:ok, []}

  defp committed_paths(runner, workspace, base_ref, head_ref) do
    git_paths(runner, workspace, ["diff", "--name-only", base_ref, head_ref])
  end

  defp git_paths(runner, workspace, args) do
    case git(runner, workspace, args) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      {:error, status, output} -> {:error, {:changed_files_git_failed, args, status, output}}
    end
  end

  defp normalize_paths(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.replace(&1, "\\", "/"))
    |> Enum.map(&String.trim_leading(&1, "./"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp maybe_put_run_dir(snapshot, opts) do
    case Keyword.get(opts, :run_dir) do
      run_dir when is_binary(run_dir) -> Map.put(snapshot, :run_dir, run_dir)
      _other -> snapshot
    end
  end

  defp git_repo?(runner, workspace), do: match?({:ok, _output}, git(runner, workspace, ["rev-parse", "--git-dir"]))

  defp git(runner, workspace, args) do
    case runner.(args, workspace) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, status, output}
    end
  end

  defp run_git(args, workspace), do: System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
end
