defmodule RondoWeb.Live.DashboardLiveTest do
  use Rondo.TestSupport

  alias RondoWeb.DashboardLive

  test "selects the matching run projection for live and archived selections" do
    payload = %{
      run_timelines: [
        %{
          identifier: "MT-ARCHIVE",
          run_id: "run-old",
          session_id: "session-old",
          started_at: "2026-05-10T15:29:00Z",
          timeline: []
        },
        %{
          identifier: "MT-ARCHIVE",
          run_id: "run-live",
          session_id: "session-live",
          started_at: "2026-05-10T15:30:00Z",
          timeline: []
        },
        %{
          identifier: "MT-OTHER",
          run_id: "run-other",
          session_id: "session-other",
          started_at: "2026-05-10T15:31:00Z",
          timeline: []
        }
      ]
    }

    assert %{run_id: "run-live"} =
             DashboardLive.selected_run_projection_for_test(payload, %{
               identifier: "MT-ARCHIVE",
               run_id: "run-live"
             })

    assert %{run_id: "run-live"} =
             DashboardLive.selected_run_projection_for_test(payload, %{
               issue_identifier: "MT-ARCHIVE",
               session_id: "session-live"
             })

    assert %{run_id: "run-live"} =
             DashboardLive.selected_run_projection_for_test(payload, %{
               issue_identifier: "MT-ARCHIVE",
               started_at: "2026-05-10T15:30:00Z"
             })
  end

  test "renders ledger browser metadata from run timeline steps" do
    step = %{
      status: "completed",
      kind: "dispatch",
      summary: "dispatch",
      source: %{kind: "checkpoint", path: "checkpoints/0001-dispatch.json"},
      artifacts: [
        %{kind: "checkpoint", path: "checkpoints/0001-dispatch.json"},
        %{kind: "final_report", path: "artifacts/final-report.json"}
      ]
    }

    assert DashboardLive.ledger_step_class_for_test(step) =~ "state-badge"
    assert DashboardLive.ledger_step_meta_for_test(step) =~ "checkpoint: checkpoints/0001-dispatch.json"
    assert DashboardLive.ledger_step_meta_for_test(step) =~ "final_report: artifacts/final-report.json"
  end

  test "formats event-log sources with one-based indices" do
    step = %{source: %{kind: "event_log", event_index: 2}, artifacts: []}

    assert DashboardLive.ledger_step_meta_for_test(step) == "event log #3"
  end
end
