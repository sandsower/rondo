defmodule Rondo.ChangedFilesTest do
  use Rondo.TestSupport

  alias Rondo.ChangedFiles
  alias Rondo.RunLedger

  test "collects committed, staged, unstaged, and untracked paths from a git workspace" do
    workspace = tmp_dir("changed-files-git")
    git!(workspace, ["init"])
    git!(workspace, ["config", "user.email", "rondo@example.test"])
    git!(workspace, ["config", "user.name", "Rondo Test"])

    write_file!(workspace, "committed.txt", "before\n")
    write_file!(workspace, "tracked.txt", "before\n")
    git!(workspace, ["add", "."])
    git!(workspace, ["commit", "-m", "base"])
    base_ref = git!(workspace, ["rev-parse", "HEAD"])

    write_file!(workspace, "committed.txt", "after\n")
    git!(workspace, ["add", "committed.txt"])
    git!(workspace, ["commit", "-m", "committed change"])

    write_file!(workspace, "tracked.txt", "after\n")
    write_file!(workspace, "staged.txt", "staged\n")
    git!(workspace, ["add", "staged.txt"])
    write_file!(workspace, "untracked.txt", "new\n")

    assert {:ok,
            %{
              changed_files: ["committed.txt", "staged.txt", "tracked.txt", "untracked.txt"],
              source: "git_diff",
              base_ref: ^base_ref
            }} = ChangedFiles.collect(workspace, base_ref: base_ref)
  end

  test "uses the run manifest base commit when available" do
    workspace_root = tmp_dir("changed-files-manifest")
    workspace = Path.join(workspace_root, "MT-BASE")
    File.mkdir_p!(workspace)
    git!(workspace, ["init"])
    git!(workspace, ["config", "user.email", "rondo@example.test"])
    git!(workspace, ["config", "user.name", "Rondo Test"])

    write_file!(workspace, "tracked.txt", "base\n")
    git!(workspace, ["add", "tracked.txt"])
    git!(workspace, ["commit", "-m", "base"])
    base_ref = git!(workspace, ["rev-parse", "HEAD"])

    issue = %{id: "issue-base-ref", identifier: "MT-BASE", title: "Base ref", state: "In Progress", labels: []}
    {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root, workspace: workspace)

    write_file!(workspace, "tracked.txt", "changed\n")
    write_file!(workspace, "new.txt", "new\n")

    assert {:ok,
            %{
              changed_files: ["new.txt", "tracked.txt"],
              source: "git_diff",
              base_ref: ^base_ref
            }} = ChangedFiles.collect(workspace, run_dir: ledger.run_dir)
  end

  test "returns git_no_commits for an initialized repo without commits" do
    workspace = tmp_dir("changed-files-no-commits")
    git!(workspace, ["init"])

    assert {:ok, %{changed_files: [], source: "git_no_commits"}} = ChangedFiles.collect(workspace)
  end

  test "returns a git diff failure when a git command fails" do
    workspace = tmp_dir("changed-files-git-failure")
    File.mkdir_p!(workspace)

    runner = fn
      ["rev-parse", "--git-dir"], _workspace -> {".git\n", 0}
      ["rev-parse", "HEAD"], _workspace -> {"HEAD\n", 0}
      ["cat-file", "-e", "HEAD^{commit}"], _workspace -> {"", 0}
      ["diff", "--name-only", "--cached"], _workspace -> {"boom\n", 1}
      ["diff", "--name-only"], _workspace -> {"", 0}
      ["ls-files", "--others", "--exclude-standard"], _workspace -> {"", 0}
      _args, _workspace -> {"", 0}
    end

    assert {:error, {:changed_files_git_failed, ["diff", "--name-only", "--cached"], 1, "boom\n"}} =
             ChangedFiles.collect(workspace, runner: runner)
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp write_file!(workspace, relative_path, contents) do
    path = Path.join(workspace, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp git!(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    String.trim(output)
  end
end
