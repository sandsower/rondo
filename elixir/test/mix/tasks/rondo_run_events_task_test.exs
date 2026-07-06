defmodule Mix.Tasks.Rondo.RunEventsTaskTest do
  use Rondo.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.Rondo.RunEvents
  alias Rondo.RunLedger

  @started ~U[2026-05-10 15:30:00Z]
  @done ~U[2026-05-10 15:30:40Z]

  setup do
    Mix.Task.reenable("rondo.run_events")
    :ok
  end

  defp build_run(root) do
    issue = %{id: "i1", identifier: "RON-TASK", title: "task", state: "open"}

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        now: @started,
        random_suffix: "taskcafe",
        started_at: DateTime.to_iso8601(@started)
      )

    :ok = RunLedger.append_agent_event(ledger, %{event: :session_started}, timestamp: @started)
    {:ok, ledger} = RunLedger.complete_run(ledger, "completed", %{summary: "done"}, timestamp: @done)
    ledger
  end

  test "prints the run.events JSON response" do
    root = tmp_dir("run-events-task")
    ledger = build_run(root)

    output =
      capture_io(fn ->
        assert :ok = RunEvents.run(["--repo-id", "repo-x", "--run-id", ledger.run_id, "--service-id", "svc", "--workspace-root", root])
      end)

    decoded = Jason.decode!(output)
    assert decoded["next_event_cursor"] =~ ~r{^rondo\.core/v1:\d+$}
    types = decoded["events"] |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort()
    assert types == ["rondo.run.evidence_recorded", "rondo.run.status_changed", "rondo.service.status_changed"]
  end

  test "prints the run.status JSON response with --status" do
    root = tmp_dir("run-status-task")
    ledger = build_run(root)

    output =
      capture_io(fn ->
        assert :ok = RunEvents.run(["--repo-id", "repo", "--run-id", ledger.run_id, "--status", "--workspace-root", root])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "completed"
    assert decoded["event_cursor"] == "rondo.core/v1:0"
  end

  test "resolves a run directly via --run-dir" do
    root = tmp_dir("run-events-task-dir")
    ledger = build_run(root)

    output =
      capture_io(fn ->
        assert :ok = RunEvents.run(["--repo-id", "repo", "--run-id", ledger.run_id, "--run-dir", ledger.run_dir])
      end)

    assert Jason.decode!(output)["events"] != []
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
