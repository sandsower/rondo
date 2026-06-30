defmodule RondoWeb.Live.DashboardLiveTest do
  use Rondo.TestSupport

  alias RondoWeb.{ArchivedRuns, DashboardLive}

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
      ],
      archived: [
        %{
          issue_identifier: "MT-ARCHIVE",
          runs: [
            %{
              filename: "2026-05-10T15-30-00Z.json",
              issue_identifier: "MT-ARCHIVE",
              started_at: "2026-05-10T15:30:00Z",
              finished_at: "2026-05-10T15:31:00Z",
              exit_reason: "completed"
            }
          ]
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

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        payload: payload,
        archived_filters: ArchivedRuns.default_filters(),
        selected_issue: "stale",
        selected_issue_data: nil,
        selected_runs: [%{filename: "stale.json"}],
        selected_run_index: 9,
        selected_run_projection: %{stale: true},
        selected_event_index: 3,
        selected_event_mode: :raw,
        event_filters: %{query: "stale", role: "user"}
      }
    }

    {:noreply, updated_socket} =
      DashboardLive.handle_event(
        "select_archived_run",
        %{"identifier" => "MT-ARCHIVE", "filename" => "2026-05-10T15-30-00Z.json"},
        socket
      )

    assert updated_socket.assigns.selected_issue == "MT-ARCHIVE"
    assert updated_socket.assigns.selected_run_index == 0
    assert [%{filename: "2026-05-10T15-30-00Z.json"}] = updated_socket.assigns.selected_runs
    assert updated_socket.assigns.selected_issue_data.finished_at == "2026-05-10T15:31:00Z"
    assert updated_socket.assigns.selected_issue_data.event_log == []
    assert updated_socket.assigns.selected_run_projection.run_id == "run-live"
    assert updated_socket.assigns.selected_event_index == 0
    assert updated_socket.assigns.selected_event_mode == :pretty
    assert updated_socket.assigns.event_filters == %{query: "", role: "all"}
  end

  test "archive activity style handles zero-token runs without relying on exceptions" do
    assert DashboardLive.archive_activity_style_for_test(%{tokens: %{total_tokens: 0}}) == "width: 8%"
    assert DashboardLive.archive_activity_style_for_test(%{tokens: %{total_tokens: nil}}) == "width: 8%"
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
