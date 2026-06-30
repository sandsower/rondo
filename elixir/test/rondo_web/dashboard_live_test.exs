defmodule RondoWeb.DashboardLiveTest do
  use Rondo.TestSupport

  alias RondoWeb.{ArchivedRuns, DashboardLive}

  test "renders readable last result summaries for active and archived runs" do
    report = %{
      "schema" => "rondo.final_report/v0",
      "summary" => "Did the work",
      "changed_files" => ["lib/rondo_web/result_summary.ex"],
      "gates_run" => [%{"name" => "format", "status" => "pass"}],
      "failures" => [],
      "risks" => [],
      "next_state" => "ready_for_review"
    }

    active_html =
      render_dashboard(%{
        payload: dashboard_payload(),
        now: DateTime.utc_now(),
        selected_issue: "MT-ACTIVE-RESULT",
        selected_issue_data: %{
          issue_id: "issue-active-result",
          issue_identifier: "MT-ACTIVE-RESULT",
          state: "In Progress",
          session_id: "session-active-result",
          turn_count: 2,
          last_event: :result,
          last_message: "ready_for_review · Did the work",
          last_result_payload: Jason.encode!(report),
          final_report: nil,
          started_at: "2026-05-27T11:59:00Z",
          last_event_at: "2026-05-27T12:00:00Z",
          latest_gate: nil,
          model_routing: nil,
          model_fallback: nil,
          tokens: %{input_tokens: 4, output_tokens: 5, total_tokens: 9},
          adapter: "claude_code",
          event_log: []
        },
        selected_runs: nil,
        selected_run_index: 0
      })

    assert active_html =~ "Last result"
    assert active_html =~ "ready_for_review · Did the work"
    assert active_html =~ "Files changed"
    assert active_html =~ "Raw JSON"
    assert active_html =~ "lib/rondo_web/result_summary.ex"

    archived_html =
      render_dashboard(%{
        payload: dashboard_payload(),
        now: DateTime.utc_now(),
        selected_issue: "MT-ARCHIVED-RESULT",
        selected_issue_data: %{
          issue_id: "issue-archived-result",
          issue_identifier: "MT-ARCHIVED-RESULT",
          state: "Done",
          session_id: "session-archive-result",
          turn_count: 2,
          last_event: :result,
          last_message: "completed",
          last_result_payload: nil,
          final_report: report,
          started_at: "2026-05-27T10:00:00Z",
          finished_at: "2026-05-27T10:10:00Z",
          last_event_at: "2026-05-27T10:05:00Z",
          latest_gate: nil,
          model_routing: nil,
          model_fallback: nil,
          tokens: %{input_tokens: 10, output_tokens: 20, total_tokens: 30},
          adapter: "claude_code",
          event_log: []
        },
        selected_runs: nil,
        selected_run_index: 0
      })

    assert archived_html =~ "Last result"
    assert archived_html =~ "ready_for_review · Did the work"
    assert archived_html =~ "Files changed"
    assert archived_html =~ "Raw JSON"
    assert archived_html =~ "lib/rondo_web/result_summary.ex"
    assert archived_html =~ "Archived run"
  end

  test "renders paused final report diagnostics from interrupt payloads" do
    html =
      render_dashboard(%{
        payload: dashboard_payload(),
        now: DateTime.utc_now(),
        selected_issue: "MT-PAUSED-RESULT",
        selected_issue_data: %{
          issue_id: "issue-paused-result",
          issue_identifier: "MT-PAUSED-RESULT",
          state: "In Progress",
          session_id: "session-paused-result",
          turn_count: 3,
          last_event: :result,
          last_message: "Blocked: still waiting on external auth. next_state: blocked",
          last_result_payload: "Blocked: still waiting on external auth. next_state: blocked",
          final_report: nil,
          started_at: "2026-05-27T11:59:00Z",
          paused_at: "2026-05-27T12:10:00Z",
          last_event_at: "2026-05-27T12:00:00Z",
          latest_gate: nil,
          model_routing: nil,
          model_fallback: nil,
          tokens: %{input_tokens: 4, output_tokens: 5, total_tokens: 9},
          adapter: "claude_code",
          interrupt: %{
            reason: "final_report_invalid",
            final_report: %{
              status: "missing",
              reported_next_state: "blocked",
              errors: ["final report missing or not parseable as rondo.final_report/v0 JSON"],
              excerpt: "Blocked: still waiting on external auth. next_state: blocked",
              continuation_count: 0,
              fingerprint: "blocked: still waiting on external auth. next_state: blocked"
            }
          },
          event_log: []
        },
        selected_runs: nil,
        selected_run_index: 0
      })

    assert html =~ "Last result"
    assert html =~ "JSON object · missing"
    assert html =~ "Status"
    assert html =~ "Reported Next State"
    assert html =~ "blocked"
    assert html =~ "Raw JSON"
    assert html =~ "missing"
  end

  defp render_dashboard(assigns) do
    defaults = %{
      log_filters: %{query: "", status: "all", window: "all", sort_by: "date", sort_dir: "desc"},
      archived_filters: ArchivedRuns.default_filters(),
      selected_outcome: nil,
      selected_run_projection: nil,
      event_query: "",
      event_category: :all,
      selected_event_index: nil,
      selected_event_view: :summary,
      selected_event_detail: nil
    }

    DashboardLive.render(Map.merge(defaults, assigns))
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  defp dashboard_payload do
    %{
      counts: %{running: 0, retrying: 0, paused: 0, needs_guidance: 0},
      running: [],
      retrying: [],
      needs_guidance: [],
      paused: [],
      archived: [],
      run_timelines: [],
      model_usage: %{codex_pct: 0, openrouter_pct: 0, total_runs: 0, by_provider: %{}, by_model: %{}},
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  end

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
