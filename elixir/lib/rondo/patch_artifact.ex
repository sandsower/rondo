defmodule Rondo.PatchArtifact do
  @moduledoc """
  Captures the final diff produced by a run as a patch artifact in the run ledger.

  For completed runs with local workspace changes, `capture/2` writes:

  - `artifacts/changes.patch` — `git diff --binary` output against the
    run-start base commit recorded in the manifest `repo.base_commit` (falling
    back to the capture-time `HEAD` when no base commit was recorded), so both
    work the agent committed during the run and uncommitted/untracked changes
    (via intent-to-add) are included. The patch is suitable for `git apply` on
    a clean checkout of the recorded base ref.
  - `artifacts/patch.json` — `rondo.patch/v0` metadata recording the base
    ref/branch, capture-time head ref, diff format, capture timestamp, and
    changed paths.

  Both artifacts are linked from the run manifest with kinds `"patch"` and
  `"patch_metadata"`. Patch content is intentionally not redacted: a modified
  patch would no longer apply for clean evaluation.
  """

  alias Rondo.RunLedger

  @schema "rondo.patch/v0"
  @patch_relative_path "artifacts/changes.patch"
  @metadata_relative_path "artifacts/patch.json"

  @type capture_status ::
          :captured
          | :no_changes
          | :skipped_missing_workspace
          | :skipped_not_a_git_repo
          | :skipped_no_commits

  @type runner :: ([String.t()], Path.t() -> {String.t(), non_neg_integer()})

  @doc "Returns the patch metadata schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Returns the run-dir-relative path of the patch artifact."
  @spec patch_relative_path() :: String.t()
  def patch_relative_path, do: @patch_relative_path

  @doc "Returns the run-dir-relative path of the patch metadata artifact."
  @spec metadata_relative_path() :: String.t()
  def metadata_relative_path, do: @metadata_relative_path

  @doc """
  Captures the workspace diff into the run ledger.

  Options:

  - `:workspace` — overrides the manifest `repo.workspace` path.
  - `:runner` — git runner function for tests, `fn args, cd -> {output, exit_status} end`.
  - `:now` — capture timestamp override.
  """
  @spec capture(RunLedger.t(), keyword()) :: {:ok, RunLedger.t(), capture_status()} | {:error, term()}
  def capture(%RunLedger{} = ledger, opts \\ []) do
    workspace = Keyword.get(opts, :workspace, get_in(ledger.manifest, ["repo", "workspace"]))
    runner = Keyword.get(opts, :runner, &run_git/2)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    cond do
      !is_binary(workspace) or !File.dir?(workspace) ->
        {:ok, ledger, :skipped_missing_workspace}

      !git_repo?(runner, workspace) ->
        {:ok, ledger, :skipped_not_a_git_repo}

      true ->
        capture_in_repo(ledger, workspace, runner, now)
    end
  end

  defp capture_in_repo(ledger, workspace, runner, now) do
    case git(runner, workspace, ["rev-parse", "HEAD"]) do
      {:ok, head_output} ->
        head_ref = String.trim(head_output)
        base_ref = resolve_base_ref(ledger, workspace, runner, head_ref)
        capture_against_base(ledger, workspace, runner, now, base_ref, head_ref)

      {:error, _status, _output} ->
        {:ok, ledger, :skipped_no_commits}
    end
  end

  # Prefer the run-start base commit recorded in the manifest so work the
  # agent committed during the run is part of the diff; fall back to the
  # capture-time HEAD when the base is absent or no longer resolvable.
  defp resolve_base_ref(ledger, workspace, runner, head_ref) do
    case get_in(ledger.manifest, ["repo", "base_commit"]) do
      base_commit when is_binary(base_commit) and base_commit != "" ->
        if commit_exists?(runner, workspace, base_commit), do: base_commit, else: head_ref

      _other ->
        head_ref
    end
  end

  defp commit_exists?(runner, workspace, ref) do
    match?({:ok, _output}, git(runner, workspace, ["cat-file", "-e", ref <> "^{commit}"]))
  end

  defp capture_against_base(ledger, workspace, runner, now, base_ref, head_ref) do
    with {:ok, status_output} <- step(runner, workspace, :status, ["status", "--porcelain"]),
         {:ok, committed_paths} <- committed_paths(runner, workspace, base_ref, head_ref) do
      case Enum.uniq(committed_paths ++ changed_paths(status_output)) do
        [] -> {:ok, ledger, :no_changes}
        changed_paths -> write_patch(ledger, workspace, runner, now, base_ref, head_ref, changed_paths)
      end
    end
  end

  defp committed_paths(_runner, _workspace, base_ref, base_ref), do: {:ok, []}

  defp committed_paths(runner, workspace, base_ref, head_ref) do
    with {:ok, output} <- step(runner, workspace, :committed_paths, ["diff", "--name-only", base_ref, head_ref]) do
      {:ok, String.split(output, "\n", trim: true)}
    end
  end

  defp write_patch(ledger, workspace, runner, now, base_ref, head_ref, changed_paths) do
    with {:ok, _output} <- step(runner, workspace, :intent_to_add, ["add", "--all", "--intent-to-add"]),
         {:ok, diff} <- collect_diff(runner, workspace, base_ref) do
      metadata = metadata(base_ref, head_ref, base_branch(runner, workspace), now, changed_paths)
      persist_patch(ledger, diff, metadata)
    end
  end

  defp collect_diff(runner, workspace, base_ref) do
    result = step(runner, workspace, :diff, ["diff", "--binary", base_ref])
    _reset = git(runner, workspace, ["reset", "-q"])
    result
  end

  defp persist_patch(ledger, diff, metadata) do
    with :ok <- write_artifact(ledger, @patch_relative_path, diff),
         {:ok, metadata_json} <- Jason.encode(metadata),
         :ok <- write_artifact(ledger, @metadata_relative_path, metadata_json),
         {:ok, ledger} <-
           RunLedger.link_artifacts(ledger, [
             %{"kind" => "patch", "path" => @patch_relative_path},
             %{"kind" => "patch_metadata", "path" => @metadata_relative_path}
           ]) do
      {:ok, ledger, :captured}
    end
  end

  defp metadata(base_ref, head_ref, base_branch, now, changed_paths) do
    %{
      "schema" => @schema,
      "format" => "git-diff",
      "base_ref" => base_ref,
      "head_ref" => head_ref,
      "base_branch" => base_branch,
      "includes_untracked" => true,
      "includes_committed" => true,
      "captured_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "changed_paths" => changed_paths,
      "patch_path" => @patch_relative_path
    }
  end

  defp base_branch(runner, workspace) do
    case git(runner, workspace, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, output} -> String.trim(output)
      {:error, _status, _output} -> nil
    end
  end

  defp changed_paths(status_output) do
    status_output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.slice(&1, 3..-1//1))
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp git_repo?(runner, workspace) do
    match?({:ok, _output}, git(runner, workspace, ["rev-parse", "--git-dir"]))
  end

  defp step(runner, workspace, step_name, args) do
    case git(runner, workspace, args) do
      {:ok, output} -> {:ok, output}
      {:error, status, output} -> {:error, {:patch_capture_failed, step_name, status, output}}
    end
  end

  defp git(runner, workspace, args) do
    case runner.(args, workspace) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, status, output}
    end
  end

  defp run_git(args, workspace) do
    System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
  end

  defp write_artifact(ledger, relative_path, content) do
    path = Path.join(ledger.run_dir, relative_path)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, content)
    end
  end
end
