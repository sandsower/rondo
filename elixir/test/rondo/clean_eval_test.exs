defmodule Rondo.CleanEvalTest do
  use Rondo.TestSupport

  alias Rondo.CleanEval
  alias Rondo.RunLedger

  test "exposes the clean-eval artifact contract" do
    assert CleanEval.schema() == "rondo.clean_eval/v0"
    assert CleanEval.result_relative_path() == "clean_eval/result.json"
  end

  test "is disabled by default and enabled via clean_eval config" do
    refute CleanEval.enabled?()

    write_workflow_file!(Workflow.workflow_file_path(), clean_eval_enabled: true)
    assert CleanEval.enabled?()
  end

  test "clean_eval gates fall back to top-level gates when unset" do
    write_workflow_file!(Workflow.workflow_file_path(),
      gates: [%{name: "unit", command: "true"}],
      clean_eval_enabled: true
    )

    assert [%{name: "unit", command: "true"}] = Config.clean_eval_gates()

    write_workflow_file!(Workflow.workflow_file_path(),
      gates: [%{name: "unit", command: "true"}],
      clean_eval_enabled: true,
      clean_eval_base_ref: "main",
      clean_eval_gates: [%{name: "eval", command: "false", timeout_ms: 2_000}]
    )

    assert [%{name: "eval", command: "false", timeout_ms: 2_000}] = Config.clean_eval_gates()
    assert Config.clean_eval_base_ref() == "main"
  end

  test "rejects invalid clean_eval config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      clean_eval_enabled: "maybe",
      clean_eval_base_ref: "",
      clean_eval_gates: [%{name: "", command: ""}]
    )

    assert {:error, {:invalid_workflow_config, _path, errors}} = Config.validate!()
    fields = Enum.map(errors, & &1.path)
    assert "clean_eval.enabled" in fields
    assert "clean_eval.base_ref" in fields
    assert "clean_eval.gates.0.name" in fields
    assert "clean_eval.gates.0.command" in fields
  end

  test "applies the patch on a clean worktree, runs gates, and reports pass in the ledger" do
    context = setup_run("clean-eval-pass")
    write_patch_artifacts!(context)

    gates = [%{name: "check files", command: "grep -q added file.txt && test -f new.txt", timeout_ms: 10_000}]

    assert {:ok, ledger, result} = CleanEval.run(context.ledger, gates: gates)
    assert result.status == :pass
    assert result.patch_status == "applied"
    assert result.apply_exit_status == 0
    assert result.base_ref == context.base_ref
    assert result.cleanup == %{removed: true, method: "worktree_remove"}
    assert result.gates.status == :pass

    # The dirty agent workspace is untouched; the eval workspace is gone.
    assert File.read!(Path.join(context.workspace, "file.txt")) =~ "added"
    refute File.exists?(eval_workspace(context))
    {worktrees, 0} = System.cmd("git", ["worktree", "list"], cd: context.workspace)
    refute worktrees =~ ".rondo_clean_eval"

    result_json = read_result_json!(context)
    assert result_json["schema"] == "rondo.clean_eval/v0"
    assert result_json["status"] == "pass"
    assert result_json["base_ref"] == context.base_ref
    assert result_json["patch_path"] == "artifacts/changes.patch"
    assert result_json["gates"]["status"] == "pass"
    assert result_json["cleanup"]["removed"] == true

    gate_results = context.ledger.run_dir |> Path.join("clean_eval/gates/results.json") |> File.read!() |> Jason.decode!()
    assert gate_results["status"] == "pass"

    assert ledger.manifest["clean_eval"] == %{"status" => "pass", "result_path" => "clean_eval/result.json"}
    assert Enum.any?(ledger.manifest["checkpoints"], &(&1["kind"] == "clean_eval_completed"))
    artifact_kinds = Enum.map(ledger.manifest["artifacts"], & &1["kind"])
    assert "clean_eval_result" in artifact_kinds
    assert "clean_eval_gate_results" in artifact_kinds
  end

  test "uses configured clean_eval gates when no gates are passed" do
    context =
      setup_run("clean-eval-config-gates",
        clean_eval_enabled: true,
        clean_eval_gates: [%{name: "configured", command: "test -f new.txt", timeout_ms: 10_000}]
      )

    write_patch_artifacts!(context)

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger)
    assert result.status == :pass
    assert [%{"name" => "configured", "status" => "pass"}] = read_result_json!(context)["gates"]["results"]
  end

  test "passes with apply-only evaluation when no gates are configured" do
    context = setup_run("clean-eval-no-gates")
    write_patch_artifacts!(context)

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger)
    assert result.status == :pass
    assert result.gates == nil
    refute Map.has_key?(read_result_json!(context), "gates")
  end

  test "records apply conflicts as evaluator failures" do
    context = setup_run("clean-eval-conflict")
    conflicting_base = context.base_ref
    commit_change!(context.workspace, "file.txt", "two\n")
    write_patch_artifacts!(context, change: "three\n")

    assert {:ok, ledger, result} = CleanEval.run(context.ledger, base_ref: conflicting_base)
    assert result.status == :fail
    assert result.patch_status == "apply_failed"
    assert result.apply_exit_status > 0
    assert is_binary(result.apply_output)
    assert result.cleanup.removed == true
    refute File.exists?(eval_workspace(context))

    result_json = read_result_json!(context)
    assert result_json["status"] == "fail"
    assert result_json["patch_status"] == "apply_failed"
    assert result_json["base_ref"] == conflicting_base
    assert ledger.manifest["clean_eval"]["status"] == "fail"
  end

  test "records gate failures as evaluator failures and still cleans up" do
    context = setup_run("clean-eval-gate-fail")
    write_patch_artifacts!(context)

    gates = [%{name: "boom", command: "echo nope; exit 7", timeout_ms: 10_000}]

    assert {:ok, ledger, result} = CleanEval.run(context.ledger, gates: gates)
    assert result.status == :fail
    assert result.patch_status == "applied"
    assert result.gates.status == :fail
    assert result.cleanup.removed == true
    refute File.exists?(eval_workspace(context))
    assert ledger.manifest["clean_eval"]["status"] == "fail"
  end

  test "maps gate environment failures to errors" do
    context = setup_run("clean-eval-gate-error")
    write_patch_artifacts!(context)

    gates = [%{name: "missing tool", command: "rondo-no-such-tool-xyz", timeout_ms: 10_000}]

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, gates: gates)
    assert result.status == :error
    assert result.gates.status == :error
    refute File.exists?(eval_workspace(context))
  end

  test "records gate runner infrastructure failures as errors" do
    context = setup_run("clean-eval-runner-error")
    write_patch_artifacts!(context)

    gate_runner = fn _gates, _workspace, _opts -> {:error, :gate_runner_unavailable} end
    gates = [%{name: "any", command: "true", timeout_ms: 10_000}]

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, gates: gates, gate_runner: gate_runner)
    assert result.status == :error
    assert result.reason =~ "gate_runner_failed"
    assert result.reason =~ "gate_runner_unavailable"
    refute File.exists?(eval_workspace(context))
  end

  test "skips when the run has no patch artifact" do
    context = setup_run("clean-eval-skip")

    assert {:ok, ledger, result} = CleanEval.run(context.ledger)
    assert result == %{status: :skipped, reason: "missing_patch_artifact"}
    assert read_result_json!(context)["status"] == "skipped"
    assert ledger.manifest["clean_eval"]["status"] == "skipped"
  end

  test "errors when the source workspace is missing" do
    context = setup_run("clean-eval-no-workspace")
    write_patch_artifacts!(context)

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, workspace: Path.join(context.root, "nope"))
    assert result == %{status: :error, reason: "missing_workspace"}
  end

  test "errors when patch metadata is missing or invalid" do
    context = setup_run("clean-eval-bad-metadata")
    write_patch_artifacts!(context)
    metadata_path = Path.join(context.ledger.run_dir, "artifacts/patch.json")

    File.rm!(metadata_path)
    assert {:ok, _ledger, %{status: :error, reason: "missing_patch_metadata"}} = CleanEval.run(context.ledger)

    File.write!(metadata_path, "not json")
    assert {:ok, _ledger, %{status: :error, reason: "invalid_patch_metadata"}} = CleanEval.run(context.ledger)

    File.write!(metadata_path, Jason.encode!(%{"schema" => "rondo.patch/v0"}))
    assert {:ok, _ledger, %{status: :error, reason: "missing_base_ref"}} = CleanEval.run(context.ledger)
  end

  test "errors when the clean worktree cannot be created" do
    context = setup_run("clean-eval-bad-base")
    write_patch_artifacts!(context)

    assert {:ok, ledger, result} = CleanEval.run(context.ledger, base_ref: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
    assert result.status == :error
    assert result.reason =~ "worktree_create_failed"
    refute File.exists?(eval_workspace(context))
    assert ledger.manifest["clean_eval"]["status"] == "error"
  end

  test "falls back to rm_rf cleanup when worktree removal fails" do
    context = setup_run("clean-eval-cleanup-fallback")
    write_patch_artifacts!(context)

    runner = fn
      ["worktree", "remove" | _rest], _cwd -> {"forced removal failure", 1}
      args, cwd -> System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    end

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, runner: runner)
    assert result.status == :pass
    assert result.cleanup == %{removed: true, method: "rm_rf"}
    refute File.exists?(eval_workspace(context))
  end

  test "caps oversized apply output in the result artifact" do
    context = setup_run("clean-eval-apply-output-cap")
    write_patch_artifacts!(context)

    runner = fn
      ["apply" | _rest], _cwd -> {String.duplicate("x", 20_000), 1}
      args, cwd -> System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    end

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, runner: runner)
    assert result.status == :fail
    assert result.patch_status == "apply_failed"
    assert String.ends_with?(result.apply_output, "... (truncated)")
    assert byte_size(result.apply_output) < 20_000
  end

  test "returns an error when the result artifact cannot be persisted" do
    context = setup_run("clean-eval-persist-error")
    File.write!(Path.join(context.ledger.run_dir, "clean_eval"), "blocking file")

    assert {:error, {:clean_eval_result_dir_failed, _reason}} = CleanEval.run(context.ledger)
  end

  defp setup_run(name, workflow_overrides \\ []) do
    root = tmp_dir(name)
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), [workspace_root: root] ++ workflow_overrides)

    workspace = Path.join(root, "RON-1")
    File.mkdir_p!(workspace)
    git!(workspace, ["init"])
    git!(workspace, ["config", "user.email", "clean-eval@example.com"])
    git!(workspace, ["config", "user.name", "Clean Eval"])
    git!(workspace, ["config", "commit.gpgsign", "false"])
    base_ref = commit_change!(workspace, "file.txt", "one\n")

    {:ok, ledger} =
      RunLedger.create_run(
        %{id: "ron-1", identifier: "RON-1", title: "Clean eval", state: "In Progress"},
        workspace_root: root
      )

    %{root: root, workspace: workspace, base_ref: base_ref, ledger: ledger}
  end

  defp commit_change!(workspace, file, contents) do
    File.write!(Path.join(workspace, file), contents)
    git!(workspace, ["add", "--all"])
    git!(workspace, ["commit", "-m", "change #{file}"])
    workspace |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp write_patch_artifacts!(context, opts \\ []) do
    change = Keyword.get(opts, :change, "one\nadded\n")
    File.write!(Path.join(context.workspace, "file.txt"), change)
    File.write!(Path.join(context.workspace, "new.txt"), "brand new\n")
    git!(context.workspace, ["add", "--all", "--intent-to-add"])
    diff = git!(context.workspace, ["diff", "--binary", "HEAD"])
    git!(context.workspace, ["reset", "-q"])

    base_ref = context.workspace |> git!(["rev-parse", "HEAD"]) |> String.trim()
    File.write!(Path.join(context.ledger.run_dir, "artifacts/changes.patch"), diff)

    metadata = %{
      "schema" => "rondo.patch/v0",
      "format" => "git-diff",
      "base_ref" => base_ref,
      "base_branch" => "main",
      "includes_untracked" => true,
      "patch_path" => "artifacts/changes.patch"
    }

    File.write!(Path.join(context.ledger.run_dir, "artifacts/patch.json"), Jason.encode!(metadata))
  end

  defp read_result_json!(context) do
    context.ledger.run_dir |> Path.join("clean_eval/result.json") |> File.read!() |> Jason.decode!()
  end

  defp eval_workspace(context) do
    Path.join([context.root, ".rondo_clean_eval", context.ledger.run_id])
  end

  defp git!(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    output
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
  end
end
