defmodule Rondo.CoreServiceModeTest do
  use Rondo.TestSupport

  alias Rondo.RunSupervisor

  test "trackerless orchestrator starts recovery-capable without scheduling tracker polling" do
    task_supervisor = unique_name(:TaskSupervisor)
    orchestrator = unique_name(:Orchestrator)
    start_supervised!({Task.Supervisor, name: task_supervisor})

    orchestrator_opts = [
      name: orchestrator,
      task_supervisor: task_supervisor,
      tracker_polling: true,
      service_mode: :trackerless_core,
      core_maintenance_interval_ms: 60_000
    ]

    start_supervised!({Orchestrator, orchestrator_opts})

    state = :sys.get_state(orchestrator)
    assert state.tracker_polling == false
    assert state.next_poll_due_at_ms == nil
    assert state.tick_timer_ref == nil
    assert state.tick_token == nil
    assert is_reference(state.core_maintenance_timer_ref)
    assert Orchestrator.active_run_count(orchestrator) == 0

    assert %{
             queued: false,
             coalesced: false,
             operations: []
           } = Orchestrator.request_refresh(orchestrator)

    refreshed_state = :sys.get_state(orchestrator)
    assert refreshed_state.next_poll_due_at_ms == nil
    assert refreshed_state.tick_timer_ref == nil
    assert refreshed_state.tick_token == nil

    first_maintenance_ref = refreshed_state.core_maintenance_timer_ref
    Process.cancel_timer(first_maintenance_ref)
    send(orchestrator, :core_maintenance)

    maintained_state = :sys.get_state(orchestrator)
    assert is_reference(maintained_state.core_maintenance_timer_ref)
    refute maintained_state.core_maintenance_timer_ref == first_maintenance_ref
  end

  test "RunSupervisor propagates trackerless Core mode to the coupled orchestrator" do
    supervisor = unique_name(:RunSupervisor)
    task_supervisor = unique_name(:TaskSupervisor)
    orchestrator = unique_name(:Orchestrator)

    opts = [
      name: supervisor,
      task_supervisor: task_supervisor,
      orchestrator: orchestrator,
      service_mode: :trackerless_core,
      orchestrator_opts: [tracker_polling: true]
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
