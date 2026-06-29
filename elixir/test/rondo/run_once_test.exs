defmodule Rondo.RunOnceTest do
  use Rondo.TestSupport

  import ExUnit.CaptureLog

  alias Rondo.RunOnce

  test "runs exactly one visible active issue" do
    parent = self()

    issue = issue("issue-1", state: "In Progress")

    assert :ok =
             RunOnce.run("issue-1",
               deps: deps(issue, parent)
             )

    assert_received {:fetch_issue_states_by_ids, ["issue-1"]}
    assert_received {:agent_run, %Issue{id: "issue-1", state: "In Progress"}, agent_opts}
    assert_run_dir_option(agent_opts)
    refute_received {:update_issue_state, _, _}
  end

  test "returns clear error when issue is missing or not visible" do
    parent = self()

    assert {:error, {:issue_not_visible, "missing-1"}} =
             RunOnce.run("missing-1",
               deps: deps([], parent)
             )

    assert_received {:fetch_issue_states_by_ids, ["missing-1"]}
    refute_received {:agent_run, _, _}
  end

  test "returns clear error for filtered issues omitted by tracker visibility" do
    parent = self()

    assert {:error, {:issue_not_visible, "filtered-1"}} =
             RunOnce.run("filtered-1",
               deps: deps([], parent)
             )

    refute_received {:agent_run, _, _}
  end

  test "rejects terminal issues" do
    parent = self()

    assert {:error, {:issue_not_dispatchable, context, :terminal_state}} =
             RunOnce.run("issue-done",
               deps: deps(issue("issue-done", state: "Done"), parent)
             )

    assert context =~ "issue_identifier=GH-1"
    refute_received {:agent_run, _, _}
  end

  test "rejects inactive issues" do
    parent = self()

    assert {:error, {:issue_not_dispatchable, _context, :inactive_state}} =
             RunOnce.run("issue-backlog",
               deps: deps(issue("issue-backlog", state: "Backlog"), parent)
             )

    refute_received {:agent_run, _, _}
  end

  test "rejects Todo issues blocked by non-terminal blockers" do
    parent = self()

    blocked_issue =
      issue("issue-blocked",
        state: "Todo",
        blocked_by: [%{id: "blocker-1", identifier: "GH-2", state: "In Progress"}]
      )

    assert {:error, {:issue_not_dispatchable, _context, :blocked}} =
             RunOnce.run("issue-blocked",
               deps: deps(blocked_issue, parent)
             )

    refute_received {:agent_run, _, _}
  end

  test "transitions Todo issues to In Progress before running the agent" do
    parent = self()

    assert :ok =
             RunOnce.run("issue-todo",
               deps: deps(issue("issue-todo", state: "Todo"), parent)
             )

    assert_received {:action_policy_evaluate, "tracker.issue.transition", ["git-remote"]}
    assert_received {:update_issue_state, "issue-todo", "In Progress"}
    assert_received {:agent_run, %Issue{id: "issue-todo", state: "In Progress"}, agent_opts}
    assert_run_dir_option(agent_opts)
  end

  test "records Todo transition action policy decisions in the run ledger" do
    parent = self()
    workspace_root = tmp_dir("run-once-policy-ledger")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert :ok =
             RunOnce.run("issue-todo",
               deps: deps(issue("issue-todo", state: "Todo"), parent)
             )

    assert_received {:agent_run, %Issue{id: "issue-todo", state: "In Progress"}, agent_opts}
    manifest = agent_opts |> Keyword.fetch!(:run_dir) |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "action_policy_decision"))
  end

  test "blocks Todo transitions when action policy asks for guidance" do
    parent = self()
    workspace_root = tmp_dir("run-once-policy-ask-ledger")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, {:action_policy_guidance_required, interrupt}} =
             RunOnce.run("issue-todo",
               deps: deps(issue("issue-todo", state: "Todo"), parent, policy_decision: "ask")
             )

    assert interrupt["reason"] == "action_policy_guidance_required"
    assert interrupt["blocked_side_effect"]["action"] == "tracker.issue.transition"
    assert interrupt["blocked_side_effect"]["resume_safe"] == true
    assert interrupt["suggested_responses"] |> Enum.any?(&(&1["id"] == "approve_once"))
    refute_received {:update_issue_state, _, _}
    refute_received {:agent_run, _, _}

    manifest = latest_run_manifest!(workspace_root, "GH-1")
    assert manifest["status"] == "paused"
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "action_policy_decision"))
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "interrupt_created"))
  end

  test "blocks Todo transitions when action policy denies" do
    parent = self()

    assert {:error, {:action_policy_denied, %{"decision" => "deny"}}} =
             RunOnce.run("issue-todo",
               deps: deps(issue("issue-todo", state: "Todo"), parent, policy_decision: "deny")
             )

    refute_received {:update_issue_state, _, _}
    refute_received {:agent_run, _, _}
  end

  test "returns clear error and fails the ledger when Todo transition fails" do
    parent = self()
    workspace_root = tmp_dir("run-once-transition-failure-ledger")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, {:issue_transition_failed, _context, :boom}} =
             RunOnce.run("issue-todo",
               deps: deps(issue("issue-todo", state: "Todo"), parent, update_result: {:error, :boom})
             )

    refute_received {:agent_run, _, _}

    manifest = latest_run_manifest!(workspace_root, "GH-1")
    assert manifest["status"] == "failed"
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "failed"))
  end

  test "pauses the ledger when agent workspace policy exits with guidance" do
    parent = self()
    workspace_root = tmp_dir("run-once-agent-guidance-ledger")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    interrupt =
      Rondo.SideEffectPolicy.guidance_interrupt(
        %{
          action: "workspace.hook.before_run",
          classes: ["workspace-write"],
          label: "Before-run hook",
          required: true,
          resume_safe: false,
          skip_behavior: "abort"
        },
        %{"decision" => "ask", "action" => "workspace.hook.before_run", "mode" => "unattended-auto"}
      )

    agent_runner = fn _issue, _agent_opts -> exit({:action_policy_guidance_required, interrupt}) end

    assert {:error, {:action_policy_guidance_required, ^interrupt}} =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: agent_runner)
             )

    manifest = latest_run_manifest!(workspace_root, "GH-1")
    assert manifest["status"] == "paused"
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "interrupt_created"))
  end

  test "converts adapter exceptions into errors" do
    parent = self()

    assert {:error, {:agent_run_failed, "agent exploded"}} =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: :raise)
             )

    assert_received {:agent_run, %Issue{id: "issue-1"}, agent_opts}
    assert_run_dir_option(agent_opts)
  end

  test "creates a run ledger so run-once gate artifacts can be persisted" do
    parent = self()
    workspace_root = tmp_dir("run-once-gates")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      gates: [%{name: "proof", command: "echo run-once", timeout_ms: 1_000}]
    )

    agent_runner = fn issue, agent_opts ->
      run_dir = Keyword.fetch!(agent_opts, :run_dir)
      workspace = Path.join(workspace_root, issue.identifier)
      File.mkdir_p!(workspace)

      assert {:ok, summary} = Rondo.Gates.run(Config.gates(), workspace, run_dir: run_dir, execution_id: "turn-0001")
      send(parent, {:run_once_gate_results, run_dir, summary.results_path})
      :ok
    end

    assert :ok =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: agent_runner)
             )

    assert_received {:run_once_gate_results, run_dir, "artifacts/gates/turn-0001/results.json"}
    assert File.exists?(Path.join(run_dir, "manifest.json"))
    assert File.read!(Path.join(run_dir, "artifacts/gates/turn-0001/0001-proof-stdout.log")) == "run-once\n"
  end

  test "marks run-once ledgers failed and records gate evidence when the agent raises" do
    parent = self()
    workspace_root = tmp_dir("run-once-gate-failure")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      gates: [%{name: "proof", command: "echo nope; exit 3", timeout_ms: 1_000}]
    )

    agent_runner = fn issue, agent_opts ->
      run_dir = Keyword.fetch!(agent_opts, :run_dir)
      workspace = Path.join(workspace_root, issue.identifier)
      File.mkdir_p!(workspace)

      assert {:error, summary} = Rondo.Gates.run(Config.gates(), workspace, run_dir: run_dir, execution_id: "turn-0001")

      send(
        self(),
        {:claude_worker_update, issue.id,
         %{
           event: :gates_completed,
           timestamp: DateTime.utc_now(),
           session_id: nil,
           usage: nil,
           raw: Rondo.Gates.summary_to_json(summary)
         }}
      )

      send(parent, {:run_once_failed_gate_run_dir, run_dir})
      raise "gate_failed"
    end

    assert {:error, {:agent_run_failed, "gate_failed"}} =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: agent_runner)
             )

    assert_received {:run_once_failed_gate_run_dir, run_dir}
    manifest = run_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert manifest["status"] == "failed"
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "gates_completed"))
    assert Enum.any?(manifest["artifacts"], &(&1["kind"] == "gate_results"))
    assert File.read!(Path.join(run_dir, "artifacts/gates/turn-0001/0001-proof-stdout.log")) == "nope\n"
  end

  test "surfaces terminal run ledger completion failures" do
    parent = self()

    agent_runner = fn _issue, agent_opts ->
      manifest_path = Path.join(Keyword.fetch!(agent_opts, :run_dir), "manifest.json")
      File.rm!(manifest_path)
      File.mkdir_p!(manifest_path)
      :ok
    end

    assert {:error, {:run_once_ledger_completion_failed, reason, :ok}} =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: agent_runner)
             )

    assert reason in [:eisdir, :eacces]
  end

  test "logs run context when agent event persistence fails" do
    parent = self()

    agent_runner = fn issue, agent_opts ->
      run_dir = Keyword.fetch!(agent_opts, :run_dir)
      File.mkdir_p!(Path.join(run_dir, "artifacts/agent-events.ndjson"))

      send(
        self(),
        {:claude_worker_update, issue.id,
         %{
           event: :assistant,
           timestamp: DateTime.utc_now(),
           session_id: "session-1",
           usage: nil,
           raw: %{message: "hello"}
         }}
      )

      :ok
    end

    log =
      capture_log(fn ->
        assert :ok =
                 RunOnce.run("issue-1",
                   deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: agent_runner)
                 )
      end)

    assert log =~ "Failed to append run-once ledger agent event"
    assert log =~ "issue_identifier=GH-1"
    assert log =~ "issue_id=issue-1"
    assert log =~ "session_id=session-1"
    assert log =~ "run_id=GH-1-"
    assert log =~ "run_dir="
  end

  test "records model routing decisions in run-once manifest" do
    parent = self()
    workspace_root = tmp_dir("run-once-model-routing")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    fallback = %{
      failed_candidate: %{model: "openai-codex/gpt-5.4-mini"},
      next_candidate: %{model: "openrouter/deepseek/deepseek-v4-pro"},
      failure_class: "usage_limit",
      failure_reason: "Codex error: The usage limit has been reached",
      turn_number: 1,
      attempt_number: 2,
      exhausted: false
    }

    routing = %{
      status: :fallback,
      mode: :prefer,
      candidates: [fallback.failed_candidate, fallback.next_candidate],
      resolved: fallback.next_candidate,
      reason: "fallback to OpenRouter",
      fallback: fallback
    }

    agent_runner = fn issue, _agent_opts ->
      send(self(), {:claude_worker_update, issue.id, %{event: :model_routing_decision, model_routing: routing, source: %{turn_number: 1}}})
      :ok
    end

    assert :ok =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: agent_runner)
             )

    assert_received {:agent_run, %Issue{id: "issue-1"}, agent_opts}
    manifest = agent_opts |> Keyword.fetch!(:run_dir) |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert manifest["agent"]["model_routing"]["status"] == "fallback"
    assert manifest["agent"]["model_routing"]["resolved"]["model"] == "openrouter/deepseek/deepseek-v4-pro"
    assert manifest["agent"]["model_routing"]["fallback"]["failed_candidate"]["model"] == "openai-codex/gpt-5.4-mini"
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "model_routing_decision"))
  end

  test "passes agent opts through to the agent runner" do
    parent = self()

    assert :ok =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent),
               agent_opts: [agent_adapter: TestAdapter]
             )

    assert_received {:agent_run, %Issue{id: "issue-1"}, agent_opts}
    assert Keyword.fetch!(agent_opts, :agent_adapter) == TestAdapter
    assert_run_dir_option(agent_opts)
  end

  test "runs a valid execution request manifest without tracker fetch or state transition" do
    parent = self()
    manifest_path = write_manifest!(%{schema: "rondo-execution-request-v1", slice_id: "slice-123", prompt: "Do the slice."})

    assert :ok =
             RunOnce.run_manifest(manifest_path,
               deps: deps([], parent)
             )

    assert_received {:agent_run, %Issue{id: "slice-123", identifier: "slice-123", state: "In Progress"}, agent_opts}
    assert_run_dir_option(agent_opts)
    assert %{schema: "rondo-execution-request-v1", slice_id: "slice-123", path: ^manifest_path} = Keyword.fetch!(agent_opts, :source_contract)
    assert {:ok, []} = agent_opts |> Keyword.fetch!(:issue_state_fetcher) |> then(& &1.(["slice-123"]))
    refute_received {:fetch_issue_states_by_ids, _}
    refute_received {:update_issue_state, _, _}
  end

  test "manifest runner_extensions policy file overrides config and is recorded in the run ledger" do
    parent = self()
    workspace_root = tmp_dir("run-once-policy-file")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    config_policy_file = Path.join(tmp_dir("run-once-config-policy"), "config-policy.json")
    File.mkdir_p!(Path.dirname(config_policy_file))
    File.write!(config_policy_file, ~s({"modes": {"unattended-auto": {}}}))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      action_policy_policy_file: config_policy_file
    )

    manifest_dir = tmp_dir("manifest-policy")
    File.mkdir_p!(manifest_dir)
    manifest_policy_contents = ~s({"modes": {"unattended-auto": {"actions": {"tracker.issue.transition": "allow"}}}})
    File.write!(Path.join(manifest_dir, "policy.json"), manifest_policy_contents)

    manifest_path = Path.join(manifest_dir, "request.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        schema: "rondo-execution-request-v1",
        slice_id: "slice-123",
        prompt: "Do the slice.",
        runner_extensions: %{action_policy: %{policy_file: "policy.json"}}
      })
    )

    assert :ok = RunOnce.run_manifest(manifest_path, deps: deps([], parent))
    assert_received {:agent_run, %Issue{id: "slice-123"}, agent_opts}

    expected_sha256 = :crypto.hash(:sha256, manifest_policy_contents) |> Base.encode16(case: :lower)
    manifest = latest_run_manifest!(workspace_root, "slice-123")
    frozen_path = Path.join(manifest["run_dir"], "artifacts/action-policy.json")

    assert Keyword.fetch!(agent_opts, :action_policy_policy_file) == frozen_path
    assert manifest["action_policy"]["policy_file"] == frozen_path
    assert manifest["action_policy"]["policy_file_source"] == Path.join(manifest_dir, "policy.json")
    assert manifest["action_policy"]["policy_file_sha256"] == expected_sha256
    assert File.read!(frozen_path) == manifest_policy_contents
  end

  test "manifest runs without a policy override record the configured policy file" do
    parent = self()
    workspace_root = tmp_dir("run-once-config-policy-fallback")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    config_policy_file = Path.join(tmp_dir("run-once-config-policy"), "config-policy.json")
    File.mkdir_p!(Path.dirname(config_policy_file))
    config_policy_contents = ~s({"modes": {"unattended-auto": {}}})
    File.write!(config_policy_file, config_policy_contents)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      action_policy_policy_file: config_policy_file
    )

    manifest_path = write_manifest!(%{schema: "rondo-execution-request-v1", slice_id: "slice-123", prompt: "Do the slice."})

    assert :ok = RunOnce.run_manifest(manifest_path, deps: deps([], parent))

    expected_sha256 = :crypto.hash(:sha256, config_policy_contents) |> Base.encode16(case: :lower)
    manifest = latest_run_manifest!(workspace_root, "slice-123")
    frozen_path = Path.join(manifest["run_dir"], "artifacts/action-policy.json")

    assert manifest["action_policy"]["policy_file"] == frozen_path
    assert manifest["action_policy"]["policy_file_source"] == Path.expand(config_policy_file)
    assert manifest["action_policy"]["policy_file_sha256"] == expected_sha256
  end

  test "run/2 passes the frozen policy file to the tracker-transition evaluator" do
    parent = self()
    workspace_root = tmp_dir("run-once-frozen-transition")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    config_policy_file = Path.join(tmp_dir("run-once-frozen-policy"), "config-policy.json")
    File.mkdir_p!(Path.dirname(config_policy_file))
    File.write!(config_policy_file, ~s({"modes": {"unattended-auto": {}}}))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      action_policy_policy_file: config_policy_file
    )

    base_deps = deps(issue("issue-1", state: "Todo"), parent)
    evaluator = base_deps.action_policy_evaluator

    deps = %{
      base_deps
      | action_policy_evaluator: fn action, classes, opts ->
          send(parent, {:evaluator_policy_file, Keyword.get(opts, :policy_file)})
          evaluator.(action, classes, opts)
        end
    }

    assert :ok = RunOnce.run("issue-1", deps: deps)

    assert_received {:evaluator_policy_file, frozen_path}
    assert is_binary(frozen_path)
    assert String.ends_with?(frozen_path, "artifacts/action-policy.json")
    refute frozen_path == Path.expand(config_policy_file)

    assert_received {:agent_run, _issue, agent_opts}
    assert Keyword.fetch!(agent_opts, :action_policy_policy_file) == frozen_path
  end

  test "manifest policy file that does not exist fails closed before agent execution" do
    parent = self()

    manifest_path =
      write_manifest!(%{
        schema: "rondo-execution-request-v1",
        slice_id: "slice-123",
        prompt: "Do the slice.",
        runner_extensions: %{action_policy: %{policy_file: "missing-policy.json"}}
      })

    expected_path = Path.join(Path.dirname(manifest_path), "missing-policy.json")

    assert {:error, {:manifest_policy_file_unreadable, ^expected_path}} =
             RunOnce.run_manifest(manifest_path, deps: deps([], parent))

    refute_received {:agent_run, _, _}
  end

  test "manifest policy file with a non-string value fails closed before agent execution" do
    parent = self()

    manifest_path =
      write_manifest!(%{
        schema: "rondo-execution-request-v1",
        slice_id: "slice-123",
        prompt: "Do the slice.",
        runner_extensions: %{action_policy: %{policy_file: 42}}
      })

    assert {:error, {:invalid_manifest_policy_file, 42}} = RunOnce.run_manifest(manifest_path, deps: deps([], parent))
    refute_received {:agent_run, _, _}
  end

  test "misshapen manifest runner_extensions fail closed before agent execution" do
    parent = self()

    flat_extensions =
      write_manifest!(%{
        schema: "rondo-execution-request-v1",
        slice_id: "slice-123",
        prompt: "Do the slice.",
        runner_extensions: "policy.json"
      })

    assert {:error, {:invalid_manifest_runner_extensions, "policy.json"}} =
             RunOnce.run_manifest(flat_extensions, deps: deps([], parent))

    flat_action_policy =
      write_manifest!(%{
        schema: "rondo-execution-request-v1",
        slice_id: "slice-123",
        prompt: "Do the slice.",
        runner_extensions: %{action_policy: "policy.json"}
      })

    assert {:error, {:invalid_manifest_runner_extensions, "policy.json"}} =
             RunOnce.run_manifest(flat_action_policy, deps: deps([], parent))

    refute_received {:agent_run, _, _}
  end

  test "invalid execution request manifests fail before agent execution" do
    parent = self()
    manifest_path = write_manifest!(%{schema: "unknown-v1", slice_id: "slice-123", prompt: "Do the slice."})

    assert {:error, {:unsupported_execution_request_schema, "unknown-v1"}} =
             RunOnce.run_manifest(manifest_path,
               deps: deps([], parent)
             )

    refute_received {:agent_run, _, _}
    refute_received {:fetch_issue_states_by_ids, _}
    refute_received {:update_issue_state, _, _}
  end

  test "runs clean eval after successful runs when enabled and reports it in the ledger" do
    parent = self()
    workspace_root = tmp_dir("run-once-clean-eval")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      clean_eval_enabled: true
    )

    agent_runner = fn run_issue, agent_opts ->
      run_dir = Keyword.fetch!(agent_opts, :run_dir)
      workspace = Path.join(workspace_root, run_issue.identifier)
      File.mkdir_p!(workspace)
      git = fn args -> {_output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true) end
      git.(["init"])
      git.(["config", "user.email", "run-once@example.com"])
      git.(["config", "user.name", "Run Once"])
      git.(["config", "commit.gpgsign", "false"])
      File.write!(Path.join(workspace, "file.txt"), "one\n")
      git.(["add", "--all"])
      git.(["commit", "-m", "base"])
      {base_ref, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
      File.write!(Path.join(workspace, "file.txt"), "one\ntwo\n")
      {diff, 0} = System.cmd("git", ["diff", "--binary", "HEAD"], cd: workspace)
      File.write!(Path.join(run_dir, "artifacts/changes.patch"), diff)

      metadata = %{"schema" => "rondo.patch/v0", "base_ref" => String.trim(base_ref), "patch_path" => "artifacts/changes.patch"}
      File.write!(Path.join(run_dir, "artifacts/patch.json"), Jason.encode!(metadata))
      :ok
    end

    log =
      capture_log(fn ->
        assert :ok =
                 RunOnce.run("issue-1",
                   deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: agent_runner)
                 )
      end)

    assert log =~ "Run-once clean eval"
    assert log =~ "status=pass"

    manifest = latest_run_manifest!(workspace_root, "GH-1")
    assert manifest["clean_eval"] == %{"status" => "pass", "result_path" => "clean_eval/result.json"}
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "clean_eval_completed"))
  end

  test "does not run clean eval when disabled" do
    parent = self()
    workspace_root = tmp_dir("run-once-clean-eval-disabled")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert :ok =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent)
             )

    manifest = latest_run_manifest!(workspace_root, "GH-1")
    refute Map.has_key?(manifest, "clean_eval")
  end

  test "captures patch and final report artifacts for completed runs with local changes" do
    parent = self()
    workspace_root = tmp_dir("run-once-artifacts")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    report = %{
      "schema" => "rondo.final_report/v0",
      "summary" => "Implemented the change",
      "changed_files" => ["tracked.txt"],
      "gates_run" => [],
      "failures" => [],
      "risks" => [],
      "next_state" => "ready_for_review"
    }

    agent_runner = fn issue, _agent_opts ->
      workspace = Path.join(workspace_root, issue.identifier)
      File.mkdir_p!(workspace)
      git!(workspace, ["init", "--quiet"])
      git!(workspace, ["config", "user.email", "test@example.org"])
      git!(workspace, ["config", "user.name", "Rondo Test"])
      File.write!(Path.join(workspace, "tracked.txt"), "before\n")
      git!(workspace, ["add", "tracked.txt"])
      git!(workspace, ["commit", "--quiet", "-m", "initial"])
      File.write!(Path.join(workspace, "tracked.txt"), "after\n")

      send(
        self(),
        {:claude_worker_update, issue.id,
         %{
           event: :invocation_completed,
           timestamp: DateTime.utc_now(),
           adapter: "claude_code",
           session_id: "session-final",
           usage: nil,
           final_report: "Done.\n```json\n#{Jason.encode!(report)}\n```\n",
           raw: %{}
         }}
      )

      :ok
    end

    assert :ok =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: agent_runner)
             )

    manifest = latest_run_manifest!(workspace_root, "GH-1")
    assert manifest["status"] == "completed"
    refute Map.has_key?(manifest, "failure_classification")

    artifact_kinds = Enum.map(manifest["artifacts"], & &1["kind"])
    assert "patch" in artifact_kinds
    assert "patch_metadata" in artifact_kinds
    assert "final_report" in artifact_kinds
    assert manifest["final_report"] == %{"status" => "valid", "errors" => [], "path" => "artifacts/final-report.json"}

    run_dir = manifest["run_dir"]
    assert File.read!(Path.join(run_dir, "artifacts/changes.patch")) =~ "after"
    patch_metadata = Path.join(run_dir, "artifacts/patch.json") |> File.read!() |> Jason.decode!()
    assert patch_metadata["schema"] == "rondo.patch/v0"
    assert patch_metadata["changed_paths"] == ["tracked.txt"]
    persisted_report = Path.join(run_dir, "artifacts/final-report.json") |> File.read!() |> Jason.decode!()
    assert persisted_report["summary"] == "Implemented the change"

    events_lines = Path.join(run_dir, "artifacts/agent-events.ndjson") |> File.read!() |> String.split("\n", trim: true)
    assert events_lines != []

    Enum.each(events_lines, fn line ->
      assert Jason.decode!(line)["schema"] == "rondo.events/v0"
    end)
  end

  test "classifies malformed final reports distinctly while keeping the run completed" do
    parent = self()
    workspace_root = tmp_dir("run-once-bad-report")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    agent_runner = fn issue, _agent_opts ->
      send(
        self(),
        {:claude_worker_update, issue.id,
         %{
           event: :invocation_completed,
           timestamp: DateTime.utc_now(),
           adapter: "claude_code",
           session_id: "session-bad",
           usage: nil,
           final_report: ~s(```json\n{"schema": "rondo.final_report/v0", "summary": ""}\n```),
           raw: %{}
         }}
      )

      :ok
    end

    assert :ok =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: agent_runner)
             )

    manifest = latest_run_manifest!(workspace_root, "GH-1")
    assert manifest["status"] == "completed"
    assert manifest["failure_classification"] == "final_report_invalid"
    assert manifest["final_report"]["status"] == "invalid"
    assert Enum.any?(manifest["final_report"]["errors"], &(&1 =~ "summary must be"))
  end

  test "classifies absent final reports as missing and keeps task failures distinct" do
    parent = self()
    workspace_root = tmp_dir("run-once-missing-report")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert :ok =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent)
             )

    assert {:error, {:agent_run_failed, "agent exploded"}} =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: :raise)
             )

    manifests = all_run_manifests!(workspace_root, "GH-1")

    completed_manifest = Enum.find(manifests, &(&1["status"] == "completed"))
    assert completed_manifest["failure_classification"] == "final_report_missing"
    assert completed_manifest["final_report"]["status"] == "missing"

    failed_manifest = Enum.find(manifests, &(&1["status"] == "failed"))
    assert failed_manifest["failure_classification"] == "task_failure"
    refute Map.has_key?(failed_manifest, "final_report")
  end

  defp assert_run_dir_option(agent_opts) do
    assert agent_opts |> Keyword.fetch!(:run_dir) |> File.dir?()
  end

  defp git!(cd, args) do
    {output, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(output)
  end

  defp all_run_manifests!(workspace_root, identifier) do
    workspace_root
    |> Path.join(Path.join([".rondo_runs", identifier, "*", "manifest.json"]))
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
  end

  defp latest_run_manifest!(workspace_root, identifier) do
    [manifest_path | _] =
      workspace_root
      |> Path.join(Path.join([".rondo_runs", identifier, "*", "manifest.json"]))
      |> Path.wildcard()
      |> Enum.sort(:desc)

    manifest_path |> File.read!() |> Jason.decode!()
  end

  defp write_manifest!(payload) do
    dir = tmp_dir("manifest")
    File.mkdir_p!(dir)
    path = Path.join(dir, "request.json")
    File.write!(path, Jason.encode!(payload))
    path
  end

  defp deps(fetch_result, parent, opts \\ []) do
    update_result = Keyword.get(opts, :update_result, :ok)
    agent_runner = Keyword.get(opts, :agent_runner, :ok)
    policy_decision = Keyword.get(opts, :policy_decision, "allow")

    %{
      fetch_issue_states_by_ids: fn issue_ids ->
        send(parent, {:fetch_issue_states_by_ids, issue_ids})
        {:ok, List.wrap(fetch_result)}
      end,
      update_issue_state: fn issue_id, state_name ->
        send(parent, {:update_issue_state, issue_id, state_name})
        update_result
      end,
      action_policy_evaluator: fn action, classes, _opts ->
        send(parent, {:action_policy_evaluate, action, classes})

        {:ok,
         %{
           "decision" => policy_decision,
           "action" => action,
           "classes" => classes,
           "mode" => "supervised-auto",
           "log_level" => if(policy_decision == "deny", do: "error", else: "warning"),
           "requires_human" => policy_decision == "ask",
           "reason" => "test #{policy_decision}",
           "matched_rules" => []
         }}
      end,
      agent_runner: fn issue, agent_opts ->
        send(parent, {:agent_run, issue, agent_opts})

        cond do
          is_function(agent_runner, 2) -> agent_runner.(issue, agent_opts)
          agent_runner == :ok -> :ok
          agent_runner == :raise -> raise "agent exploded"
        end
      end
    }
  end

  defp issue(id, attrs) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: id,
          identifier: "GH-1",
          title: "Run once",
          description: "Run this issue once",
          state: "In Progress",
          labels: []
        ],
        attrs
      )
    )
  end
end
