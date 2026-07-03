defmodule Rondo.OrchestratorEscalationTelemetryTest do
  use Rondo.TestSupport

  alias Rondo.RunLedger

  test "emits [:rondo, :escalation, :decision] telemetry when a finished attempt is escalated" do
    test_pid = self()
    handler_id = "escalation-telemetry-#{inspect(test_pid)}"

    :telemetry.attach(
      handler_id,
      [:rondo, :escalation, :decision],
      fn event, measurements, metadata, _config -> send(test_pid, {:telemetry, event, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    workspace_root = tmp_dir("orchestrator-escalation-telemetry")
    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), escalation_enabled: true, workspace_root: workspace_root)

    issue_id = "issue-escalation-telemetry"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-900",
      title: "Escalation telemetry test",
      description: "Trigger escalation decision telemetry via a non-normal agent exit",
      state: "In Progress",
      url: "https://example.org/issues/MT-900"
    }

    assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)

    orchestrator_name = Module.concat(__MODULE__, :EscalationTelemetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      ledger: ledger,
      run_dir: ledger.run_dir,
      attempt_chain: [],
      session_id: nil,
      turn_count: 0,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, process_ref, :process, self(), {:agent_run_failed, "simulated failure"}})

    assert_receive {:telemetry, [:rondo, :escalation, :decision], %{}, metadata}, 2_000
    assert metadata.run_id == ledger.run_id
    assert metadata.decision == :escalate
    assert metadata.next_tier == "standard"
  end

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(path)
    path
  end
end
