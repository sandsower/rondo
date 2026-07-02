defmodule RondoWeb.DashboardLiveTest do
  use Rondo.TestSupport

  alias Phoenix.LiveView.Socket
  alias RondoWeb.{ArchivedRuns, DashboardLive}

  test "select_event loads the clicked event detail" do
    run_dir = Path.join(System.tmp_dir!(), "rondo-dashboard-live-#{System.unique_integer([:positive])}")
    artifact_dir = Path.join(run_dir, "artifacts")
    File.mkdir_p!(artifact_dir)

    on_exit(fn -> File.rm_rf(run_dir) end)

    File.write!(
      Path.join(artifact_dir, "agent-events.ndjson"),
      Jason.encode!(%{
        "schema" => "rondo-agent-events-v1",
        "timestamp" => "2026-06-29T22:00:00Z",
        "event" => "assistant_message",
        "session_id" => "session-42",
        "adapter" => "pi",
        "raw" => %{"message" => %{"content" => [%{"type" => "text", "text" => "hello"}]}}
      }) <> "\n"
    )

    socket = %Socket{
      assigns: %{
        __changed__: %{},
        selected_issue_data: %{
          run_id: "run-42",
          run_dir: run_dir,
          session_id: "session-42",
          turn_count: 1,
          event_log: [%{at: "2026-06-29T22:00:00Z", event: :assistant, message: "hello"}]
        },
        selected_event_index: nil,
        selected_event_view: :summary,
        selected_event_detail: nil
      }
    }

    assert {:noreply, updated_socket} = DashboardLive.handle_event("select_event", %{"index" => "0"}, socket)
    detail = updated_socket.assigns.selected_event_detail

    assert detail.index == 0
    assert detail.raw["event"] == "assistant_message"
    assert detail.session_id == "session-42"
    assert detail.run_id == "run-42"
    assert detail.raw_json =~ "assistant_message"
    assert updated_socket.assigns.selected_event_view == :summary
  end

  test "select_event ignores invalid event indices" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        selected_issue_data: %{event_log: [%{at: "2026-06-29T22:00:00Z", event: :assistant, message: "hello"}]},
        selected_event_index: 0,
        selected_event_view: :raw,
        selected_event_detail: %{summary: "existing"}
      }
    }

    assert {:noreply, updated_socket} = DashboardLive.handle_event("select_event", %{"index" => "nope"}, socket)
    assert updated_socket.assigns.selected_event_index == nil
    assert updated_socket.assigns.selected_event_view == :summary
    assert updated_socket.assigns.selected_event_detail == nil
  end

  test "select_event clears state for out-of-range indices" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        selected_issue_data: %{event_log: [%{at: "2026-06-29T22:00:00Z", event: :assistant, message: "hello"}]},
        selected_event_index: 0,
        selected_event_view: :raw,
        selected_event_detail: %{summary: "existing"}
      }
    }

    assert {:noreply, updated_socket} = DashboardLive.handle_event("select_event", %{"index" => "99"}, socket)
    assert updated_socket.assigns.selected_event_index == nil
    assert updated_socket.assigns.selected_event_view == :summary
    assert updated_socket.assigns.selected_event_detail == nil
  end

  test "filter_events clears selected detail when filters hide it" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        selected_issue_data: %{
          event_log: [
            %{at: "2026-06-29T22:00:00Z", event: :assistant, message: "Draft prompt"},
            %{at: "2026-06-29T22:00:05Z", event: :bash, message: "$ mix test"}
          ]
        },
        selected_event_index: 1,
        selected_event_view: :raw,
        selected_event_detail: %{summary: "existing"},
        event_query: "",
        event_category: :all
      }
    }

    assert {:noreply, updated_socket} =
             DashboardLive.handle_event("filter_events", %{"event_query" => "", "event_category" => "prompt"}, socket)

    assert updated_socket.assigns.selected_event_index == nil
    assert updated_socket.assigns.selected_event_view == :summary
    assert updated_socket.assigns.selected_event_detail == nil
    assert updated_socket.assigns.event_category == :prompt
  end

  test "projects the selected run lazily for live and archived selections" do
    payload = %{
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

    assert %{identifier: "MT-ARCHIVE", archived: true} =
             DashboardLive.selected_run_projection_for_test(%{
               issue_identifier: "MT-ARCHIVE",
               started_at: "2026-05-10T15:30:00Z",
               finished_at: "2026-05-10T15:31:00Z",
               exit_reason: "completed"
             })

    socket = %Socket{
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
        selected_event_view: :raw,
        selected_event_detail: %{summary: "stale"},
        event_query: "stale",
        event_category: :tool
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
    assert updated_socket.assigns.selected_run_projection.identifier == "MT-ARCHIVE"
    assert updated_socket.assigns.selected_run_projection.archived == true
    assert updated_socket.assigns.selected_event_index == nil
    assert updated_socket.assigns.selected_event_view == :summary
    assert updated_socket.assigns.selected_event_detail == nil
    assert updated_socket.assigns.event_query == ""
    assert updated_socket.assigns.event_category == :all
  end

  test "archive activity style handles zero-token runs without relying on exceptions" do
    assert DashboardLive.archive_activity_style_for_test(%{tokens: %{total_tokens: 0}}) == "width: 8%"
    assert DashboardLive.archive_activity_style_for_test(%{tokens: %{total_tokens: nil}}) == "width: 8%"
  end

  test "select_timeline_step loads checkpoint detail and toggles closed on re-click" do
    run_dir = Path.join(System.tmp_dir!(), "rondo-timeline-step-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(run_dir, "checkpoints"))
    on_exit(fn -> File.rm_rf(run_dir) end)

    File.write!(
      Path.join(run_dir, "checkpoints/0001-dispatch.json"),
      Jason.encode!(%{"kind" => "dispatch", "attempt" => 1, "note" => "checkpoint payload"})
    )

    projection = %{
      identifier: "RON-1",
      timeline: [
        %{
          kind: "dispatch",
          status: "completed",
          at: "2026-06-30T11:37:44Z",
          run_dir: run_dir,
          source: %{kind: "checkpoint", path: "checkpoints/0001-dispatch.json"},
          artifacts: [%{kind: "checkpoint", path: "checkpoints/0001-dispatch.json"}]
        }
      ]
    }

    socket = %Socket{
      assigns: %{
        __changed__: %{},
        selected_issue_data: %{event_log: []},
        selected_run_projection: projection,
        selected_event_index: nil,
        selected_event_view: :summary,
        selected_event_detail: nil
      }
    }

    {:noreply, opened} = DashboardLive.handle_event("select_timeline_step", %{"index" => "0"}, socket)
    detail = opened.assigns.selected_event_detail

    assert opened.assigns.selected_event_index == 0
    assert detail.category_label == "Checkpoint"
    assert detail.raw_json =~ "checkpoint payload"
    assert Enum.any?(detail.structured_fields, fn {label, _} -> label == "Kind" end)
    assert [%{label: "checkpoint", path: "checkpoints/0001-dispatch.json"}] = detail.artifact_links

    {:noreply, closed} = DashboardLive.handle_event("select_timeline_step", %{"index" => "0"}, opened)
    assert closed.assigns.selected_event_index == nil
    assert closed.assigns.selected_event_detail == nil
  end

  test "select_timeline_step routes event_log-sourced steps through the event inspector" do
    projection = %{
      identifier: "RON-1",
      timeline: [
        %{
          kind: "turn_completed",
          at: "2026-06-29T22:00:00Z",
          source: %{kind: "event_log", event_index: 0}
        }
      ]
    }

    socket = %Socket{
      assigns: %{
        __changed__: %{},
        selected_issue_data: %{
          session_id: "session-42",
          event_log: [%{at: "2026-06-29T22:00:00Z", event: :result, message: "turn done"}]
        },
        selected_run_projection: projection,
        selected_event_index: nil,
        selected_event_view: :summary,
        selected_event_detail: nil
      }
    }

    {:noreply, updated} = DashboardLive.handle_event("select_timeline_step", %{"index" => "0"}, socket)
    detail = updated.assigns.selected_event_detail

    assert updated.assigns.selected_event_index == 0
    assert detail.index == 0
    assert detail.session_id == "session-42"
    assert is_list(detail.structured_fields)
  end

  describe "event stream filter events" do
    defp event_stream_socket do
      projection = %{
        identifier: "RON-1",
        timeline: [
          %{kind: "dispatch_requested", phase: "dispatch", status: "completed", at: "2026-06-30T10:00:00Z", artifacts: []},
          %{kind: "completed", phase: "terminal", status: "completed", at: "2026-06-30T10:05:00Z", artifacts: []}
        ]
      }

      selected_issue_data = %{
        issue_identifier: "RON-1",
        session_id: "session-1",
        event_log: []
      }

      %Socket{
        assigns: %{
          __changed__: %{},
          selected_issue_data: selected_issue_data,
          selected_runs: nil,
          selected_run_index: 0,
          selected_run_projection: projection,
          event_stream_view: RondoWeb.DashboardEventStream.build(%{run_timelines: [projection]}, selected_issue_data, nil, 0, %{})
        }
      }
    end

    test "select_panel_tab ignores unexpected tab values" do
      socket = event_stream_socket()
      socket = %{socket | assigns: Map.put(socket.assigns, :panel_tab, "overview")}

      {:noreply, updated} = DashboardLive.handle_event("select_panel_tab", %{"tab" => "unexpected"}, socket)

      assert updated.assigns.panel_tab == "overview"
    end

    test "event_stream_facet narrows rows to the clicked facet" do
      socket = event_stream_socket()

      {:noreply, updated} = DashboardLive.handle_event("event_stream_facet", %{"facet" => "terminal"}, socket)
      view = updated.assigns.event_stream_view

      assert view.filters.facet == "terminal"
      assert Enum.map(view.rows, & &1.facet) == ["terminal"]
    end

    test "event_stream_sort reorders rows" do
      socket = event_stream_socket()

      {:noreply, updated} = DashboardLive.handle_event("event_stream_sort", %{"sort" => "time_desc"}, socket)
      view = updated.assigns.event_stream_view

      assert view.filters.sort == "time_desc"
      assert Enum.map(view.rows, & &1.kind) == ["completed", "dispatch_requested"]
    end

    test "event_stream_filters applies form params" do
      socket = event_stream_socket()

      {:noreply, updated} = DashboardLive.handle_event("event_stream_filters", %{"kind" => "completed"}, socket)
      view = updated.assigns.event_stream_view

      assert view.filters.kind == "completed"
      assert Enum.map(view.rows, & &1.kind) == ["completed"]
    end
  end
end
