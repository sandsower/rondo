defmodule RondoWeb.DashboardLiveArchivedSelectionTest do
  use Rondo.TestSupport

  alias RondoWeb.{ArchivedRuns, DashboardEventStream, DashboardLive}

  test "renders timeline steps and projections that omit optional keys" do
    # Mirrors real checkpoint steps (e.g. action_policy_decision) where
    # RunTimeline drops nil values: no :summary/:outcome on the step and no
    # :run_id/:session_id/:status on the projection.
    projection = %{
      identifier: "RON-115",
      timeline: [
        %{
          kind: "action_policy_decision",
          status: "completed",
          at: "2026-06-30T11:37:44Z",
          source: %{kind: "checkpoint", path: "checkpoints/0008-action_policy_decision.json"},
          artifacts: []
        }
      ]
    }

    selected_issue_data = %{
      issue_id: "issue-115",
      issue_identifier: "RON-115",
      state: "In Progress",
      session_id: "session-115",
      turn_count: 1,
      last_event: nil,
      last_message: nil,
      last_result_payload: nil,
      final_report: nil,
      started_at: "2026-06-30T11:35:42Z",
      last_event_at: nil,
      latest_gate: nil,
      model_routing: nil,
      model_fallback: nil,
      tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      adapter: "codex",
      event_log: []
    }

    html =
      render_dashboard(%{
        payload: dashboard_payload(),
        now: DateTime.utc_now(),
        selected_issue: "RON-115",
        selected_issue_data: selected_issue_data,
        selected_runs: nil,
        selected_run_index: 0,
        selected_run_projection: projection,
        event_stream_view: DashboardEventStream.build(%{run_timelines: [projection]}, selected_issue_data, nil, 0, %{})
      })

    assert html =~ "Run timeline"
    assert html =~ "action_policy_decision"
    assert html =~ "run n/a"
    refute html =~ "Ledger browser"
  end

  test "renders a per-run breakdown table for multi-run selections" do
    base_run = %{
      issue_identifier: "RON-9",
      session_id: "session-a",
      state: "Done",
      exit_reason: "completed",
      status: "Completed",
      outcome_display: %{class: "state-badge state-badge-active", label: "Completed", detail: nil},
      model: "claude-sonnet-5",
      provider: "anthropic",
      adapter: "claude_code"
    }

    runs = [
      Map.merge(base_run, %{
        started_at: "2026-06-30T10:00:00Z",
        finished_at: "2026-06-30T10:10:00Z",
        duration_ms: 600_000,
        turn_count: 4,
        tokens: %{input_tokens: 1200, output_tokens: 300, total_tokens: 1500},
        cost: 0.42
      }),
      Map.merge(base_run, %{
        started_at: "2026-06-30T11:00:00Z",
        finished_at: "2026-06-30T11:02:30Z",
        duration_ms: 150_000,
        turn_count: 2,
        tokens: %{input_tokens: 800, output_tokens: 150, total_tokens: 950},
        cost: nil
      })
    ]

    selected_issue_data = %{
      issue_id: "issue-9",
      issue_identifier: "RON-9",
      state: "Done",
      session_id: "session-a",
      turn_count: 4,
      last_event: nil,
      last_message: nil,
      last_result_payload: nil,
      final_report: nil,
      started_at: "2026-06-30T10:00:00Z",
      last_event_at: nil,
      latest_gate: nil,
      model_routing: nil,
      model_fallback: nil,
      tokens: %{input_tokens: 1200, output_tokens: 300, total_tokens: 1500},
      adapter: "claude_code",
      event_log: []
    }

    html =
      render_dashboard(%{
        payload: dashboard_payload(),
        now: DateTime.utc_now(),
        selected_issue: "RON-9",
        selected_issue_data: selected_issue_data,
        selected_runs: runs,
        selected_run_index: 1,
        event_stream_view: DashboardEventStream.build(%{}, selected_issue_data, runs, 1, %{})
      })

    assert html =~ "Run breakdown"
    assert html =~ "run-breakdown-table"
    assert html =~ "$0.4200"
    assert html =~ "10m 0s"
    assert html =~ "2m 30s"
    assert html =~ "1,500"
    assert html =~ "950"
    # The second run is selected, so its row carries the selected style.
    assert html =~ "data-table-row-selected"
  end

  test "stream switches show cumulative token spend at each switch point" do
    event_log = [
      %{at: "2026-06-30T10:00:00Z", event: :assistant, message: "turn 1", tokens: %{input_tokens: 100, output_tokens: 50, total_tokens: 150}},
      %{
        at: "2026-06-30T10:01:00Z",
        event: :system,
        message: "switching to sonnet",
        tokens: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
        model_change: %{provider: "anthropic", model: "claude-sonnet-5"}
      },
      %{at: "2026-06-30T10:02:00Z", event: :assistant, message: "turn 2", tokens: %{input_tokens: 200, output_tokens: 100, total_tokens: 300}},
      %{
        at: "2026-06-30T10:03:00Z",
        event: :system,
        message: "switching to opus",
        model_change: %{provider: "anthropic", model: "claude-opus-4-8"}
      }
    ]

    selected_issue_data = %{
      issue_id: "issue-77",
      issue_identifier: "RON-77",
      state: "In Progress",
      session_id: "session-77",
      turn_count: 2,
      last_event: nil,
      last_message: nil,
      last_result_payload: nil,
      final_report: nil,
      started_at: "2026-06-30T10:00:00Z",
      last_event_at: nil,
      latest_gate: nil,
      model_routing: nil,
      model_fallback: nil,
      tokens: %{input_tokens: 310, output_tokens: 155, total_tokens: 465},
      adapter: "claude_code",
      event_log: event_log
    }

    html =
      render_dashboard(%{
        payload: dashboard_payload(),
        now: DateTime.utc_now(),
        selected_issue: "RON-77",
        selected_issue_data: selected_issue_data,
        selected_runs: nil,
        selected_run_index: 0
      })

    assert html =~ "Stream switches"
    assert html =~ "165 tokens spent"
    assert html =~ "465 tokens spent"
  end

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
    # Interrupted runs expose the Guidance tab with an alert dot.
    assert html =~ "panel-tab-alert"
    assert html =~ "Guidance"
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
      selected_event_detail: nil,
      show_event_filters: false,
      panel_tab: "overview",
      event_stream_view: DashboardEventStream.build(%{}, nil, nil, 0, %{})
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
