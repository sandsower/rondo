defmodule Rondo.PatchArtifactTest do
  use Rondo.TestSupport

  alias Rondo.{PatchArtifact, RunLedger}

  @now ~U[2026-06-10 12:00:00Z]

  test "exposes the patch contract constants" do
    assert PatchArtifact.schema() == "rondo.patch/v0"
    assert PatchArtifact.patch_relative_path() == "artifacts/changes.patch"
    assert PatchArtifact.metadata_relative_path() == "artifacts/patch.json"
  end

  test "captures a git patch with tracked and untracked changes and links it from the manifest" do
    {workspace_root, workspace, ledger} = ledger_with_git_workspace("patch-captured")
    base_ref = git!(workspace, ["rev-parse", "HEAD"])

    File.write!(Path.join(workspace, "tracked.txt"), "changed line\n")
    File.write!(Path.join(workspace, "brand_new.txt"), "new file contents\n")

    assert {:ok, ledger, :captured} = PatchArtifact.capture(ledger, now: @now)

    patch = File.read!(Path.join(ledger.run_dir, "artifacts/changes.patch"))
    assert patch =~ "tracked.txt"
    assert patch =~ "changed line"
    assert patch =~ "brand_new.txt"
    assert patch =~ "new file contents"

    metadata = Path.join(ledger.run_dir, "artifacts/patch.json") |> File.read!() |> Jason.decode!()
    assert metadata["schema"] == "rondo.patch/v0"
    assert metadata["format"] == "git-diff"
    assert metadata["base_ref"] == base_ref
    assert metadata["head_ref"] == base_ref
    assert metadata["base_branch"] == git!(workspace, ["rev-parse", "--abbrev-ref", "HEAD"])
    assert metadata["includes_untracked"] == true
    assert metadata["includes_committed"] == true
    assert metadata["captured_at"] == "2026-06-10T12:00:00Z"
    assert Enum.sort(metadata["changed_paths"]) == ["brand_new.txt", "tracked.txt"]
    assert metadata["patch_path"] == "artifacts/changes.patch"

    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
    assert %{"kind" => "patch", "path" => "artifacts/changes.patch"} in manifest["artifacts"]
    assert %{"kind" => "patch_metadata", "path" => "artifacts/patch.json"} in manifest["artifacts"]

    # the patch applies cleanly to a fresh checkout of the recorded base ref
    eval_dir = Path.join(workspace_root, "clean-eval")
    git!(workspace_root, ["clone", "--quiet", workspace, eval_dir])
    git!(eval_dir, ["checkout", "--quiet", metadata["base_ref"]])
    git!(eval_dir, ["apply", Path.join(ledger.run_dir, "artifacts/changes.patch")])
    assert File.read!(Path.join(eval_dir, "tracked.txt")) == "changed line\n"
    assert File.read!(Path.join(eval_dir, "brand_new.txt")) == "new file contents\n"

    # capture leaves the workspace index clean of intent-to-add entries
    assert git!(workspace, ["diff", "--cached", "--name-only"]) == ""
  end

  test "captures work the agent committed during the run against the run-start base commit" do
    workspace_root = tmp_dir("patch-committed")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    workspace = Path.join(workspace_root, "MT-501")
    init_git_workspace(workspace)
    run_start_ref = git!(workspace, ["rev-parse", "HEAD"])

    {:ok, ledger} =
      RunLedger.create_run(issue_fixture(),
        workspace_root: workspace_root,
        workspace: workspace,
        now: @now,
        random_suffix: "feedc0de"
      )

    assert get_in(ledger.manifest, ["repo", "base_commit"]) == run_start_ref

    # the agent commits work during the run and leaves an untracked file behind
    File.write!(Path.join(workspace, "tracked.txt"), "committed change\n")
    git!(workspace, ["commit", "--quiet", "-am", "agent work"])
    File.write!(Path.join(workspace, "notes.txt"), "uncommitted notes\n")

    assert {:ok, ledger, :captured} = PatchArtifact.capture(ledger, now: @now)

    metadata = Path.join(ledger.run_dir, "artifacts/patch.json") |> File.read!() |> Jason.decode!()
    assert metadata["base_ref"] == run_start_ref
    assert metadata["head_ref"] == git!(workspace, ["rev-parse", "HEAD"])
    assert metadata["head_ref"] != run_start_ref
    assert Enum.sort(metadata["changed_paths"]) == ["notes.txt", "tracked.txt"]

    # the patch applies cleanly on a fresh checkout of the run-start base commit
    eval_dir = Path.join(workspace_root, "clean-eval")
    git!(workspace_root, ["clone", "--quiet", workspace, eval_dir])
    git!(eval_dir, ["checkout", "--quiet", run_start_ref])
    git!(eval_dir, ["apply", Path.join(ledger.run_dir, "artifacts/changes.patch")])
    assert File.read!(Path.join(eval_dir, "tracked.txt")) == "committed change\n"
    assert File.read!(Path.join(eval_dir, "notes.txt")) == "uncommitted notes\n"
  end

  test "falls back to the capture-time HEAD when the recorded base commit is unresolvable" do
    {:ok, ledger} = create_ledger("patch-stale-base")
    ledger = put_in(ledger.manifest["repo"]["base_commit"], "feedfacefeedfacefeedfacefeedfacefeedface")
    workspace = get_in(ledger.manifest, ["repo", "workspace"])
    File.mkdir_p!(workspace)

    runner = fn
      ["rev-parse", "--git-dir"], _cd -> {".git\n", 0}
      ["rev-parse", "HEAD"], _cd -> {"abc123\n", 0}
      ["cat-file", "-e", "feedfacefeedfacefeedfacefeedfacefeedface^{commit}"], _cd -> {"fatal: bad object\n", 128}
      ["status", "--porcelain"], _cd -> {" M tracked.txt\n", 0}
      ["add", "--all", "--intent-to-add"], _cd -> {"", 0}
      ["diff", "--binary", "abc123"], _cd -> {"diff --git a/tracked.txt b/tracked.txt\n", 0}
      ["reset", "-q"], _cd -> {"", 0}
      ["rev-parse", "--abbrev-ref", "HEAD"], _cd -> {"main\n", 0}
    end

    assert {:ok, ledger, :captured} = PatchArtifact.capture(ledger, runner: runner, now: @now)

    metadata = Path.join(ledger.run_dir, "artifacts/patch.json") |> File.read!() |> Jason.decode!()
    assert metadata["base_ref"] == "abc123"
    assert metadata["head_ref"] == "abc123"
  end

  test "classifies secret-bearing patches without rewriting patch bytes" do
    {_workspace_root, workspace, ledger} = ledger_with_git_workspace("patch-secret")
    secret_line = "API_KEY=supersecretvalue"
    File.write!(Path.join(workspace, "tracked.txt"), "#{secret_line}\n")

    assert {:ok, ledger, :captured} = PatchArtifact.capture(ledger, now: @now)

    patch = File.read!(Path.join(ledger.run_dir, "artifacts/changes.patch"))
    assert patch =~ secret_line

    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
    assert manifest["failure_classification"] == "patch_contains_secret"
    assert manifest["patch_secret_scan"]["status"] == "fail"
    assert manifest["patch_secret_scan"]["patch_path"] == "artifacts/changes.patch"

    assert %{
             "kind" => "patch",
             "path" => "artifacts/changes.patch",
             "exportable" => false,
             "blocked_reason" => "patch_contains_secret"
           } in manifest["artifacts"]

    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "patch_secret_scan"))
  end

  test "reports no_changes for a clean workspace without writing artifacts" do
    {_workspace_root, _workspace, ledger} = ledger_with_git_workspace("patch-clean")

    assert {:ok, ledger, :no_changes} = PatchArtifact.capture(ledger, now: @now)

    refute File.exists?(Path.join(ledger.run_dir, "artifacts/changes.patch"))
    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
    refute Enum.any?(manifest["artifacts"], &(&1["kind"] == "patch"))
  end

  test "skips when the workspace directory is missing" do
    {:ok, ledger} = create_ledger("patch-missing-workspace")

    assert {:ok, ^ledger, :skipped_missing_workspace} = PatchArtifact.capture(ledger, now: @now)
    assert {:ok, ^ledger, :skipped_missing_workspace} = PatchArtifact.capture(ledger, workspace: nil)
  end

  test "skips when the workspace is not a git repository" do
    {:ok, ledger} = create_ledger("patch-not-git")
    workspace = get_in(ledger.manifest, ["repo", "workspace"])
    File.mkdir_p!(workspace)

    runner = fn ["rev-parse", "--git-dir"], ^workspace -> {"fatal: not a git repository\n", 128} end

    assert {:ok, ^ledger, :skipped_not_a_git_repo} = PatchArtifact.capture(ledger, runner: runner)
  end

  test "skips repositories without commits" do
    {:ok, ledger} = create_ledger("patch-no-commits")
    workspace = get_in(ledger.manifest, ["repo", "workspace"])
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "--quiet"])

    assert {:ok, ^ledger, :skipped_no_commits} = PatchArtifact.capture(ledger, now: @now)
  end

  test "returns step errors when git fails mid-capture" do
    {:ok, ledger} = create_ledger("patch-step-error")
    workspace = get_in(ledger.manifest, ["repo", "workspace"])
    File.mkdir_p!(workspace)

    runner = fn
      ["rev-parse", "--git-dir"], _cd -> {".git\n", 0}
      ["rev-parse", "HEAD"], _cd -> {"abc123\n", 0}
      ["status", "--porcelain"], _cd -> {"boom\n", 1}
    end

    assert {:error, {:patch_capture_failed, :status, 1, "boom\n"}} = PatchArtifact.capture(ledger, runner: runner)
  end

  test "tolerates detached or unresolvable branch names" do
    {:ok, ledger} = create_ledger("patch-branch-error")
    workspace = get_in(ledger.manifest, ["repo", "workspace"])
    File.mkdir_p!(workspace)

    runner = fn
      ["rev-parse", "--git-dir"], _cd -> {".git\n", 0}
      ["rev-parse", "HEAD"], _cd -> {"abc123\n", 0}
      ["status", "--porcelain"], _cd -> {" M tracked.txt\n", 0}
      ["add", "--all", "--intent-to-add"], _cd -> {"", 0}
      ["diff", "--binary", "abc123"], _cd -> {"diff --git a/tracked.txt b/tracked.txt\n", 0}
      ["reset", "-q"], _cd -> {"", 0}
      ["rev-parse", "--abbrev-ref", "HEAD"], _cd -> {"", 128}
    end

    assert {:ok, ledger, :captured} = PatchArtifact.capture(ledger, runner: runner, now: @now)

    metadata = Path.join(ledger.run_dir, "artifacts/patch.json") |> File.read!() |> Jason.decode!()
    assert metadata["base_ref"] == "abc123"
    assert metadata["base_branch"] == nil
    assert metadata["changed_paths"] == ["tracked.txt"]
  end

  defp ledger_with_git_workspace(name) do
    {:ok, ledger} = create_ledger(name)
    workspace_root = get_in(ledger.manifest, ["repo", "workspace_root"])
    workspace = get_in(ledger.manifest, ["repo", "workspace"])
    init_git_workspace(workspace)

    {workspace_root, workspace, ledger}
  end

  defp init_git_workspace(workspace) do
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "--quiet"])
    git!(workspace, ["config", "user.email", "test@example.org"])
    git!(workspace, ["config", "user.name", "Rondo Test"])
    File.write!(Path.join(workspace, "tracked.txt"), "original line\n")
    git!(workspace, ["add", "tracked.txt"])
    git!(workspace, ["commit", "--quiet", "-m", "initial"])
    workspace
  end

  defp create_ledger(name) do
    workspace_root = tmp_dir(name)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    RunLedger.create_run(issue_fixture(), workspace_root: workspace_root, now: @now, random_suffix: "feedc0de")
  end

  defp issue_fixture do
    %Issue{
      id: "issue-patch",
      identifier: "MT-501",
      title: "Patch artifact",
      description: "Capture diffs",
      state: "In Progress",
      url: "https://example.org/issues/MT-501",
      labels: [],
      priority: 2
    }
  end

  defp git!(cd, args) do
    {output, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(output)
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
  end
end
