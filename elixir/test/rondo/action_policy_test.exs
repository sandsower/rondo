defmodule Rondo.ActionPolicyTest do
  use Rondo.TestSupport

  alias Rondo.ActionPolicy

  test "evaluates allowed Beislið policy envelopes" do
    command = fake_evaluator("allow")

    assert {:ok, envelope} =
             ActionPolicy.evaluate("gate.unit", ["read"],
               command: command,
               mode: "unattended-auto",
               sandbox_status: %{baseline: "separate-worktree", default_branch: false, uncommitted_changes: false}
             )

    assert envelope["decision"] == "allow"
    assert envelope["action"] == "gate.unit"
    assert envelope["classes"] == ["read"]
  end

  test "evaluates with configured defaults and nil workspace sandbox" do
    command = fake_evaluator("allow")
    write_workflow_file!(Workflow.workflow_file_path(), action_policy_command: command)

    assert {:ok, %{"decision" => "allow", "mode" => "unattended-auto"}} = ActionPolicy.evaluate("file.read", ["read"])
  end

  test "evaluates with configured defaults and sandbox flags" do
    command = fake_evaluator("allow")

    write_workflow_file!(Workflow.workflow_file_path(),
      action_policy_command: command,
      action_policy_run_mode: "supervised-auto"
    )

    sandbox_status = %{baseline: "host-sandbox", default_branch: true, uncommitted_changes: true}

    assert {:ok, %{"decision" => "allow", "mode" => "supervised-auto"}} =
             ActionPolicy.evaluate("file.read", ["read"], sandbox_status: sandbox_status)
  end

  test "authorize allows allow decisions and wraps evaluator errors" do
    command = fake_evaluator("allow")
    write_workflow_file!(Workflow.workflow_file_path(), action_policy_command: command)

    assert :ok = ActionPolicy.authorize("file.read", ["read"])

    sandbox_status = %{baseline: "separate-worktree", default_branch: false, uncommitted_changes: false}

    assert :ok = ActionPolicy.authorize("file.read", ["read"], command: fake_evaluator("allow"), sandbox_status: sandbox_status)

    assert :ok =
             ActionPolicy.authorize("release.publish", ["release"],
               command: fake_evaluator("allow"),
               sandbox_status: sandbox_status
             )

    assert {:error, {:action_policy_failed, {:invalid_action_class, ""}}} =
             ActionPolicy.authorize("release.publish", [""], command: fake_evaluator("allow"), sandbox_status: sandbox_status)
  end

  test "authorize blocks denied and approval-required decisions" do
    sandbox_status = %{baseline: "separate-worktree", default_branch: false, uncommitted_changes: false}

    assert {:error, {:action_policy_denied, %{"decision" => "deny"}}} =
             ActionPolicy.authorize("git.push", ["git-remote"],
               command: fake_evaluator("deny"),
               sandbox_status: sandbox_status
             )

    assert {:error, {:action_policy_requires_approval, %{"decision" => "ask"}}} =
             ActionPolicy.authorize("dependency.install", ["dependency-install"],
               command: fake_evaluator("ask"),
               sandbox_status: sandbox_status
             )
  end

  test "invalid classes, baselines, and malformed envelopes fail closed" do
    command = fake_evaluator("malformed")
    incomplete_command = fake_evaluator("incomplete")

    assert {:error, {:invalid_action_class, ""}} =
             ActionPolicy.evaluate("release.publish", [""],
               command: command,
               sandbox_status: %{baseline: "separate-worktree", default_branch: false, uncommitted_changes: false}
             )

    assert {:error, {:invalid_sandbox_baseline, "space-station"}} =
             ActionPolicy.evaluate("file.read", ["read"],
               command: command,
               sandbox_status: %{baseline: "space-station", default_branch: false, uncommitted_changes: false}
             )

    assert {:error, :invalid_evaluator_envelope} =
             ActionPolicy.evaluate("file.read", ["read"],
               command: command,
               sandbox_status: %{baseline: "separate-worktree", default_branch: false, uncommitted_changes: false}
             )

    assert {:error, :invalid_evaluator_envelope} =
             ActionPolicy.evaluate("file.read", ["read"],
               command: incomplete_command,
               sandbox_status: %{baseline: "separate-worktree", default_branch: false, uncommitted_changes: false}
             )
  end

  test "evaluator failures fail closed" do
    sandbox_status = %{baseline: "separate-worktree", default_branch: false, uncommitted_changes: false}

    assert {:error, {:evaluator_exit, 42, _output}} =
             ActionPolicy.evaluate("gate.unit", ["read"], command: fake_evaluator("exit"), sandbox_status: sandbox_status)

    assert {:error, {:invalid_evaluator_json, _message}} =
             ActionPolicy.evaluate("gate.unit", ["read"], command: fake_evaluator("invalid-json"), sandbox_status: sandbox_status)

    assert {:error, {:evaluator_unavailable, _message}} =
             ActionPolicy.evaluate("gate.unit", ["read"], command: Path.join(tmp_dir("missing"), "nope"), sandbox_status: sandbox_status)

    assert {:error, {:evaluator_unavailable, "rondo-missing-action-policy-command"}} =
             ActionPolicy.evaluate("gate.unit", ["read"], command: "rondo-missing-action-policy-command", sandbox_status: sandbox_status)

    non_executable_command = Path.join(tmp_dir("non-executable-command"), "beislid")
    File.mkdir_p!(Path.dirname(non_executable_command))
    File.write!(non_executable_command, "#!/bin/sh\n")

    assert {:error, {:evaluator_unavailable, ^non_executable_command}} =
             ActionPolicy.evaluate("gate.unit", ["read"], command: non_executable_command, sandbox_status: sandbox_status)

    assert {:error, {:evaluator_timeout, 10}} =
             ActionPolicy.evaluate("gate.unit", ["read"],
               command: fake_evaluator("sleep"),
               timeout_ms: 10,
               sandbox_status: sandbox_status
             )
  end

  test "nil and outside workspaces use the conservative none baseline" do
    assert ActionPolicy.sandbox_status(nil) == %{baseline: "none", default_branch: false, uncommitted_changes: false}

    outside = tmp_dir("policy-outside")
    File.mkdir_p!(outside)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: tmp_dir("policy-root"))

    assert %{baseline: "none"} = ActionPolicy.sandbox_status(outside)
  end

  test "maps git workspace state into Beislið sandbox status" do
    workspace_root = tmp_dir("policy-git-root")
    workspace = Path.join(workspace_root, "MT-GIT")
    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.invalid"], cd: workspace)
    {_output, 0} = System.cmd("git", ["config", "user.name", "Rondo Test"], cd: workspace)
    File.write!(Path.join(workspace, "tracked.txt"), "tracked")
    {_output, 0} = System.cmd("git", ["add", "tracked.txt"], cd: workspace)
    {_output, 0} = System.cmd("git", ["commit", "-m", "initial"], cd: workspace, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["remote", "add", "origin", "https://example.invalid/repo.git"], cd: workspace)
    {_output, 0} = System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace)
    {_output, 0} = System.cmd("git", ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], cd: workspace)
    File.write!(Path.join(workspace, "dirty.txt"), "dirty")

    assert %{baseline: "separate-worktree", default_branch: true, uncommitted_changes: true} = ActionPolicy.sandbox_status(workspace)
  end

  test "maps issue workspaces under the configured root to separate-worktree baseline" do
    workspace_root = tmp_dir("policy-sandbox-root")
    workspace = Path.join(workspace_root, "MT-1")
    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert %{baseline: "separate-worktree", default_branch: false, uncommitted_changes: false} = ActionPolicy.sandbox_status(workspace)
    assert %{baseline: "non-default-branch"} = ActionPolicy.sandbox_status(workspace_root)
  end

  defp fake_evaluator(decision) do
    path = Path.join(tmp_dir("fake-action-policy"), "beislid-fake")
    File.mkdir_p!(Path.dirname(path))

    body = """
    #!/bin/sh
    case #{decision} in
      exit) echo evaluator failed >&2; exit 42 ;;
      invalid-json) echo not-json; exit 0 ;;
      malformed) echo '[]'; exit 0 ;;
      incomplete) echo '{"decision":"allow"}'; exit 0 ;;
      sleep) sleep 1; exit 0 ;;
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

    printf '{"decision":"%s","action":"%s","mode":"%s","classes":["%s"],"matched_rules":[],"sandbox_status":{"baseline":"separate-worktree"},"requires_human":false,"log_level":"info","reason":"test","remediation":[]}' #{decision} "$action" "$mode" "$classes"
    """

    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive, :monotonic])}")
    File.rm_rf!(path)
    path
  end
end
