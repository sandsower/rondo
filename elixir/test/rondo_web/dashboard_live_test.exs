defmodule RondoWeb.DashboardLiveArchivedSelectionTest do
  use Rondo.TestSupport

  alias RondoWeb.ArchivedRuns

  test "selecting an archived row opens the run inspector" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        payload: %{
          archived: [
            %{
              issue_identifier: "MT-ARCH-1",
              issue_title: "Archived visibility",
              runs: [
                %{
                  filename: "2026-06-29T10-00-00Z.json",
                  issue_identifier: "MT-ARCH-1",
                  started_at: "2026-06-29T10:00:00Z",
                  finished_at: "2026-06-29T10:10:00Z",
                  exit_reason: "completed"
                }
              ]
            }
          ]
        },
        archived_filters: ArchivedRuns.default_filters(),
        selected_issue: nil,
        selected_issue_data: nil,
        selected_runs: nil,
        selected_run_index: 0
      }
    }

    {:noreply, updated_socket} =
      RondoWeb.DashboardLive.handle_event(
        "select_archived_run",
        %{"identifier" => "MT-ARCH-1", "filename" => "2026-06-29T10-00-00Z.json"},
        socket
      )

    assert updated_socket.assigns.selected_issue == "MT-ARCH-1"
    assert updated_socket.assigns.selected_run_index == 0
    assert [%{filename: "2026-06-29T10-00-00Z.json"}] = updated_socket.assigns.selected_runs
    assert updated_socket.assigns.selected_issue_data.finished_at == "2026-06-29T10:10:00Z"
    assert updated_socket.assigns.selected_issue_data.event_log == []
  end
end
