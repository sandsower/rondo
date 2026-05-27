defmodule Rondo.GatesTest do
  use Rondo.TestSupport

  alias Rondo.Gates

  test "runs successful gates in the workspace and stores stable artifacts" do
    test_root = tmp_dir("gates-success")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-1")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-1/run-1")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "input.txt"), "workspace input\n")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, summary} =
             Gates.run(
               [
                 %{name: "unit", command: "cat input.txt && echo err >&2", timeout_ms: 1_000}
               ],
               workspace,
               run_dir: run_dir
             )

    assert summary.status == :pass
    assert [%{status: :pass, name: "unit"} = result] = summary.results
    assert result.stdout_path == "artifacts/gates/unit-stdout.log"
    assert result.stderr_path == "artifacts/gates/unit-stderr.log"
    assert File.read!(Path.join(run_dir, result.stdout_path)) == "workspace input\n"
    assert File.read!(Path.join(run_dir, result.stderr_path)) == "err\n"

    results_json = run_dir |> Path.join("artifacts/gates/results.json") |> File.read!() |> Jason.decode!()
    assert results_json["status"] == "pass"
    assert [%{"name" => "unit", "status" => "pass"}] = results_json["results"]
  end

  test "classifies non-zero exits as gate failures" do
    test_root = tmp_dir("gates-fail")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-2")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-2/run-1")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, summary} =
             Gates.run([%{name: "unit", command: "echo nope; exit 2", timeout_ms: 1_000}], workspace, run_dir: run_dir)

    assert summary.status == :fail
    assert [%{status: :fail, exit_status: 2, retryable: false, environment_failure: false}] = summary.results
  end

  test "classifies timeouts as retryable environment failures" do
    test_root = tmp_dir("gates-timeout")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-3")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-3/run-1")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, summary} =
             Gates.run([%{name: "slow", command: "sleep 1", timeout_ms: 10}], workspace, run_dir: run_dir)

    assert summary.status == :timeout
    assert [%{status: :timeout, retryable: true, environment_failure: true}] = summary.results
  end

  test "preserves an exit status written before timeout" do
    test_root = tmp_dir("gates-timeout-exit-status")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-3B")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-3B/run-1")
    exit_path = Path.join(run_dir, "artifacts/gates/slow-exit-status")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:error, summary} =
             Gates.run(
               [%{name: "slow", command: "printf 7 > #{inspect(exit_path)}; sleep 1", timeout_ms: 10}],
               workspace,
               run_dir: run_dir
             )

    assert [%{status: :timeout, exit_status: 7}] = summary.results
  end

  test "classifies missing commands as retryable environment errors" do
    test_root = tmp_dir("gates-missing-command")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-4")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-4/run-1")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    missing_command = "rondo-missing-gate-command-#{System.unique_integer([:positive])}"

    assert {:error, summary} =
             Gates.run([%{name: "missing", command: missing_command, timeout_ms: 1_000}], workspace, run_dir: run_dir)

    assert summary.status == :error
    assert [%{status: :error, exit_status: 127, retryable: true, environment_failure: true}] = summary.results
  end

  test "supports workspace root as the gate cwd" do
    test_root = tmp_dir("gates-root-workspace")
    workspace_root = Path.join(test_root, "workspaces")
    run_dir = Path.join(workspace_root, ".rondo_runs/root/run-1")

    File.mkdir_p!(workspace_root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:ok, summary} =
             Gates.run([%{name: "", command: "echo root", timeout_ms: 1_000}], workspace_root, run_dir: run_dir)

    assert [%{stdout_path: "artifacts/gates/gate-stdout.log"}] = summary.results
    assert Gates.summary_to_json(summary)["missing"] == nil
    assert Gates.summary_to_json(summary).status == :pass
  end

  test "requires a run_dir option" do
    test_root = tmp_dir("gates-run-dir-required")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert_raise KeyError, fn -> Gates.run([], workspace_root) end
  end

  test "surfaces artifact write failures" do
    test_root = tmp_dir("gates-write-failure")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-WRITE")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-WRITE/run-1")

    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(run_dir, "artifacts/gates/results.json"))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:error, :eisdir} =
             Gates.run([%{name: "unit", command: "true", timeout_ms: 1_000}], workspace, run_dir: run_dir)
  end

  test "surfaces workspace canonicalization failures" do
    test_root = tmp_dir("gates-canonicalize-failure")
    workspace_root = Path.join(test_root, "workspaces")
    loop_path = Path.join(workspace_root, "loop")

    File.mkdir_p!(workspace_root)
    File.ln_s!(loop_path, loop_path)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:error, {:path_canonicalize_failed, _, :symlink_loop}} =
             Gates.run([%{name: "unit", command: "true", timeout_ms: 1_000}], loop_path, run_dir: Path.join(workspace_root, ".rondo_runs/loop/run-1"))
  end

  test "rejects workspaces outside the configured root" do
    test_root = tmp_dir("gates-workspace-safety")
    on_exit(fn -> File.rm_rf(test_root) end)
    workspace_root = Path.join(test_root, "workspaces")
    outside_workspace = Path.join(test_root, "outside")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-5/run-1")

    File.mkdir_p!(outside_workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, {:invalid_workspace_cwd, :outside_root}} =
             Gates.run([%{name: "unit", command: "true", timeout_ms: 1_000}], outside_workspace, run_dir: run_dir)
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
  end
end
