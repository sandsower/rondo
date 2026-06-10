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

  defp assert_run_dir_option(agent_opts) do
    assert agent_opts |> Keyword.fetch!(:run_dir) |> File.dir?()
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
