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
    assert result.stdout_path == "artifacts/gates/0001-unit-stdout.log"
    assert result.stderr_path == "artifacts/gates/0001-unit-stderr.log"
    assert File.read!(Path.join(run_dir, result.stdout_path)) == "workspace input\n"
    assert File.read!(Path.join(run_dir, result.stderr_path)) == "err\n"

    results_json = run_dir |> Path.join("artifacts/gates/results.json") |> File.read!() |> Jason.decode!()
    assert results_json["status"] == "pass"
    assert [%{"name" => "unit", "status" => "pass"}] = results_json["results"]
  end

  test "persists provider gate selection explanations with results" do
    test_root = tmp_dir("gates-selection")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-SELECTION")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-SELECTION/run-1")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    gate_selection = %{
      selected: [%{name: "unit", reason: "matched stage verify"}],
      skipped: [%{name: "slow", reason: "not required for this stage"}],
      warnings: [%{message: "selector unavailable; used fallback"}],
      metadata: %{provider: "native", stage: "verify"}
    }

    assert {:ok, summary} =
             Gates.run([%{name: "unit", command: "true", timeout_ms: 1_000}], workspace,
               run_dir: run_dir,
               gate_selection: gate_selection
             )

    assert summary.gate_selection == gate_selection

    results_json = run_dir |> Path.join("artifacts/gates/results.json") |> File.read!() |> Jason.decode!()
    assert results_json["gate_selection"]["selected"] == [%{"name" => "unit", "reason" => "matched stage verify"}]
    assert results_json["gate_selection"]["skipped"] == [%{"name" => "slow", "reason" => "not required for this stage"}]
    assert results_json["gate_selection"]["warnings"] == [%{"message" => "selector unavailable; used fallback"}]
    assert results_json["gate_selection"]["metadata"] == %{"provider" => "native", "stage" => "verify"}
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
    exit_path = Path.join(run_dir, "artifacts/gates/0001-slow-exit-status")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:error, summary} =
             Gates.run(
               [%{name: "slow", command: "printf 7 > #{inspect(exit_path)}; sleep 1", timeout_ms: 100}],
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

  test "keeps artifact paths distinct when gate names collide" do
    test_root = tmp_dir("gates-colliding-names")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-COLLIDE")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-COLLIDE/run-1")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:ok, summary} =
             Gates.run(
               [
                 %{name: "unit/test", command: "echo first", timeout_ms: 1_000},
                 %{name: "unit test", command: "echo second", timeout_ms: 1_000}
               ],
               workspace,
               run_dir: run_dir
             )

    assert [%{stdout_path: first_path}, %{stdout_path: second_path}] = summary.results
    assert first_path == "artifacts/gates/0001-unit-test-stdout.log"
    assert second_path == "artifacts/gates/0002-unit-test-stdout.log"
    assert File.read!(Path.join(run_dir, first_path)) == "first\n"
    assert File.read!(Path.join(run_dir, second_path)) == "second\n"
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

    assert [%{stdout_path: "artifacts/gates/0001-gate-stdout.log"}] = summary.results
    assert Gates.summary_to_json(summary)["missing"] == nil
    assert Gates.summary_to_json(summary).status == :pass
  end

  test "evaluates action policy before executing gates" do
    test_root = tmp_dir("gates-action-policy-allow")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-POLICY")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-POLICY/run-1")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:ok, summary} =
             Gates.run([%{name: "unit", command: "echo ran", timeout_ms: 1_000}], workspace,
               run_dir: run_dir,
               action_policy: true,
               action_policy_command: fake_action_policy("allow")
             )

    assert [%{policy_decision: %{"decision" => "allow"}}] = summary.results
    assert File.read!(Path.join(run_dir, "artifacts/gates/0001-unit-stdout.log")) == "ran\n"

    results_json = run_dir |> Path.join("artifacts/gates/results.json") |> File.read!() |> Jason.decode!()
    assert [%{"policy_decision" => %{"decision" => "allow"}}] = results_json["results"]
  end

  test "uses injected process-provider action policy evaluator" do
    test_root = tmp_dir("gates-action-policy-provider")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-PROVIDER")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-PROVIDER/run-1")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    evaluator = fn action, classes, opts ->
      {:ok,
       %{
         "decision" => "allow",
         "action" => action,
         "classes" => classes,
         "mode" => Keyword.fetch!(opts, :mode),
         "provider" => "native-test"
       }}
    end

    assert {:ok, summary} =
             Gates.run([%{name: "unit", command: "echo provider", timeout_ms: 1_000}], workspace,
               run_dir: run_dir,
               action_policy: true,
               action_policy_evaluator: evaluator
             )

    assert [%{policy_decision: %{"provider" => "native-test"}}] = summary.results
  end

  test "blocks gates when action policy denies or requires approval" do
    test_root = tmp_dir("gates-action-policy-block")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-POLICY-BLOCK")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-POLICY-BLOCK/run-1")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:error, denied_summary} =
             Gates.run([%{name: "deny", command: "touch should-not-run", timeout_ms: 1_000}], workspace,
               run_dir: run_dir,
               execution_id: "deny",
               action_policy: true,
               action_policy_command: fake_action_policy("deny")
             )

    assert [
             %{
               status: :error,
               retryable: false,
               environment_failure: false,
               policy_decision: %{"decision" => "deny", "side_effect_status" => "blocked"}
             }
           ] = denied_summary.results

    refute File.exists?(Path.join(workspace, "should-not-run"))

    assert {:error, ask_summary} =
             Gates.run([%{name: "ask", command: "touch should-not-run-either", timeout_ms: 1_000}], workspace,
               run_dir: run_dir,
               execution_id: "ask",
               action_policy: true,
               action_policy_command: fake_action_policy("ask")
             )

    assert [%{policy_decision: %{"decision" => "ask", "side_effect_status" => "blocked"}}] = ask_summary.results
    refute File.exists?(Path.join(workspace, "should-not-run-either"))
  end

  test "passes configured gate action metadata to action policy" do
    test_root = tmp_dir("gates-action-policy-metadata")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-POLICY-META")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-POLICY-META/run-1")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:error, summary} =
             Gates.run(
               [
                 %{
                   name: "deps",
                   command: "touch should-not-run",
                   timeout_ms: 1_000,
                   action_id: "dependency.install",
                   action_classes: ["workspace-write", "dependency-install"]
                 }
               ],
               workspace,
               run_dir: run_dir,
               action_policy: true,
               action_policy_command: fake_action_policy("deny")
             )

    assert [
             %{
               policy_decision: %{
                 "action" => "dependency.install",
                 "classes" => ["workspace-write", "dependency-install"],
                 "side_effect_status" => "blocked"
               }
             }
           ] = summary.results

    refute File.exists?(Path.join(workspace, "should-not-run"))
  end

  test "blocks gates when provider action policy evaluator returns an invalid envelope" do
    test_root = tmp_dir("gates-action-policy-invalid-provider")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-POLICY-INVALID-PROVIDER")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-POLICY-INVALID-PROVIDER/run-1")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    evaluator = fn _action, _classes, _opts -> {:ok, %{"decision" => "allow"}} end

    assert {:error, summary} =
             Gates.run([%{name: "invalid provider", command: "touch should-not-run", timeout_ms: 1_000}], workspace,
               run_dir: run_dir,
               action_policy: true,
               action_policy_evaluator: evaluator
             )

    assert [
             %{
               status: :error,
               retryable: false,
               environment_failure: false,
               policy_decision: %{"decision" => "allow", "side_effect_status" => "blocked"}
             }
           ] = summary.results

    refute File.exists?(Path.join(workspace, "should-not-run"))
  end

  test "blocks gates when action policy evaluation fails closed" do
    test_root = tmp_dir("gates-action-policy-failure")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-POLICY-FAIL")
    run_dir = Path.join(workspace_root, ".rondo_runs/MT-POLICY-FAIL/run-1")

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:error, summary} =
             Gates.run([%{name: "policy fail", command: "touch should-not-run", timeout_ms: 1_000}], workspace,
               run_dir: run_dir,
               action_policy: true,
               action_policy_command: fake_action_policy("invalid-json")
             )

    assert [%{policy_decision: %{side_effect_status: :blocked}}] = summary.results
    refute File.exists?(Path.join(workspace, "should-not-run"))
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

  defp fake_action_policy(decision) do
    path = Path.join(tmp_dir("fake-action-policy"), "beislid-fake")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/bin/sh
    case #{decision} in
      invalid-json) echo not-json; exit 0 ;;
    esac
    action=""
    mode=""
    classes=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --action) action="$2"; shift 2 ;;
        --mode) mode="$2"; shift 2 ;;
        --class) classes="$classes${classes:+,}$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    classes_json=$(printf '%s' "$classes" | awk 'BEGIN{FS=","; printf "["} {for(i=1;i<=NF;i++){if(i>1)printf ","; printf "\\\"" $i "\\\""}} END{printf "]"}')
    printf '{"decision":"#{decision}","action":"%s","mode":"%s","classes":%s,"matched_rules":[],"sandbox_status":{"baseline":"separate-worktree"},"requires_human":false,"log_level":"info","reason":"test","remediation":[]}' "$action" "$mode" "$classes_json"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
  end
end
