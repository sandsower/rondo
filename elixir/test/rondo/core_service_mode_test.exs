defmodule Rondo.CoreServiceModeTest do
  use Rondo.TestSupport

  alias Rondo.RunSupervisor

  test "trackerless orchestrator starts recovery-capable without scheduling tracker polling" do
    task_supervisor = unique_name(:TaskSupervisor)
    orchestrator = unique_name(:Orchestrator)
    start_supervised!({Task.Supervisor, name: task_supervisor})

    start_supervised!({Orchestrator, name: orchestrator, task_supervisor: task_supervisor, tracker_polling: false})

    state = :sys.get_state(orchestrator)
    assert state.tracker_polling == false
    assert state.next_poll_due_at_ms == nil
    assert state.tick_timer_ref == nil
    assert state.tick_token == nil
    assert Orchestrator.active_run_count(orchestrator) == 0
  end

  test "RunSupervisor propagates trackerless Core mode to the coupled orchestrator" do
    supervisor = unique_name(:RunSupervisor)
    task_supervisor = unique_name(:TaskSupervisor)
    orchestrator = unique_name(:Orchestrator)

    opts = [
      name: supervisor,
      task_supervisor: task_supervisor,
      orchestrator: orchestrator,
      service_mode: :trackerless_core
    ]

    start_supervised!({RunSupervisor, opts})

    state = :sys.get_state(orchestrator)
    assert state.tracker_polling == false
    assert state.run_recovery == true
  end

  defp unique_name(suffix) do
    Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
  end
end
