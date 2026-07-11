defmodule Rondo.ChildLaunchIntegrationTest do
  use Rondo.TestSupport

  alias Rondo.Agent.Adapter
  alias Rondo.RunLedger

  defmodule FakePiAdapter do
    @behaviour Rondo.Agent.Adapter

    @impl true
    def id, do: "pi"

    @impl true
    def capabilities, do: %{launch: :test, resume: :session_id}

    @impl true
    def probe(_opts \\ []), do: Adapter.probe_result(:ok, %{model_selection: :ok})

    @impl true
    def invoke(%{on_event: on_event, opts: opts}) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      ledger = Keyword.fetch!(opts, :run_ledger)
      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      checkpoint_persisted? = Enum.any?(manifest["checkpoints"], &(&1["kind"] == "child_launch_policy_resolved"))
      send(test_pid, {:fake_pi_invoked, Keyword.fetch!(opts, :child_launch_envelope), checkpoint_persisted?})

      run_ref = Adapter.run_ref(id(), "fake-pi-session", "session_id", true)
      final_report = ~s({"schema":"rondo.final_report/v0","summary":"done","changed_files":[],"gates_run":[],"failures":[],"risks":[],"next_state":"Done"})

      on_event.(Adapter.event(:invocation_completed, adapter: id(), run_ref: run_ref, final_report: final_report))
      {:ok, Adapter.result(run_ref: run_ref, final_report: final_report, capabilities: capabilities())}
    end
  end

  test "real dispatch path records policy evidence and blocks unattended before adapter invocation" do
    {issue, ledger} = setup_run("BLOCK", action_policy_run_mode: "unattended-auto")

    assert_raise RuntimeError, ~r/child_launch_blocked/, fn ->
      AgentRunner.run(issue, self(),
        agent_adapter: FakePiAdapter,
        run_ledger: ledger,
        run_dir: ledger.run_dir,
        child_isolation_baseline: :env_home_scoped,
        gates: [],
        test_pid: self(),
        issue_state_fetcher: &AgentRunner.no_tracker_issue_state_fetcher/1
      )
    end

    assert_receive {:claude_worker_update, _, %{event: :child_launch_policy_resolved, evidence: evidence}}
    assert evidence["decision"] == "block"
    assert evidence["reason"] == "insufficient_isolation"
    refute_received {:fake_pi_invoked, _, _}
  end

  test "supervised run-once bypass is recorded before invoking and carries the same envelope" do
    {issue, ledger} = setup_run("BYPASS", action_policy_run_mode: "supervised-auto")

    assert :ok =
             AgentRunner.run(issue, self(),
               agent_adapter: FakePiAdapter,
               run_ledger: ledger,
               run_dir: ledger.run_dir,
               dispatch_origin: :run_once,
               unsafe_child_credential_bypass: true,
               child_isolation_baseline: :env_home_scoped,
               gates: [],
               test_pid: self(),
               issue_state_fetcher: &AgentRunner.no_tracker_issue_state_fetcher/1
             )

    assert_receive {:claude_worker_update, _, %{event: :child_launch_policy_resolved, evidence: evidence}}
    assert evidence["decision"] == "supervised_bypass"
    assert evidence["bypass"]["applied"]
    assert_receive {:fake_pi_invoked, envelope, true}
    assert envelope.decision == :supervised_bypass
  end

  defp setup_run(suffix, workflow_opts) do
    root = Path.join(System.tmp_dir!(), "rondo-child-launch-integration-#{suffix}-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [workspace_root: workspace_root, hook_after_create: "git init -q", max_turns: 1],
        workflow_opts
      )
    )

    issue = %Issue{
      id: "issue-#{suffix}",
      identifier: "MT-#{suffix}",
      title: "Child launch #{suffix}",
      description: "exercise child launch",
      state: "In Progress",
      labels: []
    }

    assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
    {issue, ledger}
  end
end
