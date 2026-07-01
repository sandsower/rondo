defmodule RondoWeb.DashboardEventStreamTest do
  use Rondo.TestSupport

  alias RondoWeb.{DashboardEventStream, DashboardLive}

  @start_one ~U[2026-06-29 09:00:00Z]
  @start_two ~U[2026-06-29 10:00:00Z]
  @start_three ~U[2026-06-29 11:00:00Z]
  @gate_time ~U[2026-06-29 10:00:30Z]
  @terminal_time ~U[2026-06-29 10:01:00Z]
  @tool_time ~U[2026-06-29 10:02:00Z]

  test "public helpers normalize filter state and selection params" do
    assert DashboardEventStream.default_filters() == %{
             query: "",
             scope: "",
             facet: "all",
             kind: "all",
             status: "all",
             provider: "all",
             model: "all",
             run_state: "all",
             result: "all",
             from: "",
             to: "",
             sort: "time_asc"
           }

    assert DashboardEventStream.normalize_filters(nil) == DashboardEventStream.default_filters()

    assert DashboardEventStream.normalize_filters(%{
             "query" => "  Gate  ",
             "from" => " 2026-06-29T10:00:00Z ",
             "to" => " 2026-06-29T11:00:00Z ",
             model: " openrouter/z-ai/glm-5.2 ",
             sort: "summary_desc",
             kind: 123
           }) == %{
             query: "Gate",
             scope: "",
             facet: "all",
             kind: "123",
             status: "all",
             provider: "all",
             model: "openrouter/z-ai/glm-5.2",
             run_state: "all",
             result: "all",
             from: "2026-06-29T10:00:00Z",
             to: "2026-06-29T11:00:00Z",
             sort: "summary_desc"
           }

    assert DashboardEventStream.selection_params(%{"issue" => "", "run" => ""}) == %{}
    assert DashboardEventStream.selection_params(%{issue: "MT-100", run: 2}) == %{"issue" => "MT-100", "run" => 2}
    assert DashboardEventStream.selection_params(%{}) == %{}
    assert DashboardEventStream.selection_params("nope") == %{}
    assert DashboardEventStream.facet_choices("nope") == []
    assert DashboardEventStream.facet_choices(%{custom: 2}) == [{:custom, "Custom", 2}]

    assert DashboardEventStream.build(nil, nil, nil, 0, %{}) == %{
             rows: [],
             total_count: 0,
             filtered_count: 0,
             filters: DashboardEventStream.default_filters(),
             facets: %{},
             options: %{},
             selected_run: nil
           }

    assert DashboardEventStream.build(%{}, nil, nil, 0, %{}) == %{
             rows: [],
             total_count: 0,
             filtered_count: 0,
             filters: DashboardEventStream.default_filters(),
             facets: %{},
             options: %{providers: [], models: [], statuses: [], results: [], kinds: [], run_states: []},
             selected_run: nil
           }
  end

  test "build falls back to event-log rows when no timeline is available" do
    payload = %{run_timelines: []}

    selected_issue_data = %{
      issue_identifier: "MT-LOG",
      issue_id: "issue-log",
      project: "rondo/logs",
      event_log: [
        %{at: nil, event: :assistant, message: "Read results.json"},
        %{at: "", event: :bash, message: "$ mix test"},
        %{at: 123, event: "custom", message: "123"},
        %{at: @start_one, event: "gates_completed", message: "gate event"},
        %{at: @start_two, event: "continue", message: "continue event"},
        %{at: @start_three, event: "failed", message: "failed event"}
      ],
      adapter: "claude_code"
    }

    view =
      DashboardEventStream.build(payload, selected_issue_data, nil, 0, %{
        query: "mix test",
        scope: "MT-LOG",
        sort: "time_asc"
      })

    assert view.total_count == 6
    assert view.filtered_count == 1
    assert [%{kind: "bash", summary: "$ mix test", provider: "claude_code"}] = view.rows
    assert view.options.providers == ["claude_code"]
  end

  test "build resolves live selection and sorts filtered rows across every mode" do
    payload = %{run_timelines: live_runs()}

    selected_issue_data = %{
      issue_identifier: "MT-100",
      issue_id: "issue-100",
      session_id: "session-100-b",
      started_at: @start_two,
      state: "In Progress",
      adapter: "pi",
      project: "rondo/dashboard",
      model_routing: %{adapter: "openrouter", resolved: %{model: "openrouter/z-ai/glm-5.2"}}
    }

    base_filters = %{
      provider: "openrouter",
      run_state: "In Progress",
      result: "pass",
      from: "2026-06-29T10:00:00Z",
      to: "2026-06-29T10:05:00Z"
    }

    assert [%{kind: "gates_completed", status: "pass", result_status: "pass", provider: "openrouter", model: "openrouter/z-ai/glm-5.2"}] =
             DashboardEventStream.build(payload, selected_issue_data, nil, 0, Map.put(base_filters, :sort, "summary_desc")).rows

    assert DashboardEventStream.build(payload, %{selected_issue_data | session_id: "missing"}, nil, 0, base_filters).selected_run.session_id == "session-100-a"

    Enum.each(
      ["time_desc", "kind_asc", "kind_desc", "status_asc", "status_desc", "summary_asc", "summary_desc", "bogus"],
      fn sort ->
        view = DashboardEventStream.build(payload, selected_issue_data, nil, 0, Map.put(base_filters, :sort, sort))
        assert view.selected_run.session_id == "session-100-b"
        assert view.filtered_count == 1
      end
    )

    date_only_view = DashboardEventStream.build(payload, selected_issue_data, nil, 0, %{from: "2026-06-29T10:00:00Z", to: "2026-06-29T10:05:00Z"})
    assert date_only_view.selected_run.session_id == "session-100-b"
    assert Enum.all?(date_only_view.rows, &(&1.at >= "2026-06-29T10:00:00Z" and &1.at <= "2026-06-29T10:05:00Z"))
  end

  test "build selects archived runs from the supplied list and falls back when the selection misses" do
    payload = %{run_timelines: archived_runs()}

    matching_selected_runs = [
      %{session_id: "session-200-a", started_at: @start_one},
      %{session_id: "session-200-b", started_at: @start_two}
    ]

    view = DashboardEventStream.build(payload, nil, matching_selected_runs, 0, %{})
    assert view.selected_run.session_id == "session-200-a"

    fallback_view = DashboardEventStream.build(payload, nil, [%{session_id: "missing", started_at: @start_three}], 0, %{})
    assert fallback_view.selected_run.session_id == "session-200-a"

    out_of_range_view = DashboardEventStream.build(payload, nil, matching_selected_runs, 99, %{})
    assert out_of_range_view.selected_run.session_id == "session-200-a"

    provider_view =
      DashboardEventStream.build(
        payload,
        nil,
        [
          %{session_id: "session-200-c", started_at: @start_three}
        ],
        0,
        %{}
      )

    assert provider_view.selected_run.session_id == "session-200-c"
    assert [%{kind: "tool_activity", provider: "openrouter", model: "openrouter/o3"}] = provider_view.rows

    string_key_payload = %{
      run_timelines: [
        %{
          "identifier" => "MT-201",
          "issue_id" => "issue-201",
          "session_id" => "session-201",
          "started_at" => @start_two,
          "status" => "completed",
          "adapter" => "legacy",
          "model" => "legacy-model",
          "project" => "rondo/legacy",
          "timeline" => [
            %{
              "at" => @terminal_time,
              "kind" => "failed",
              "phase" => "terminal",
              "status" => "failed",
              "outcome" => "failed",
              "summary" => "failed hard",
              "source" => %{"kind" => "final_report"}
            }
          ]
        }
      ]
    }

    string_key_view = DashboardEventStream.build(string_key_payload, nil, [%{session_id: "session-201", started_at: @start_two}], 0, %{})
    assert string_key_view.selected_run["session_id"] == "session-201"

    string_key_live_view =
      DashboardEventStream.build(
        %{
          run_timelines: [
            %{"identifier" => "MT-202", "session_id" => "finished", "started_at" => @start_one, "finished_at" => @start_two, "timeline" => []},
            %{"identifier" => "MT-202", "session_id" => "in-progress", "started_at" => @start_two, "timeline" => []}
          ]
        },
        %{"issue_identifier" => "MT-202", "session_id" => "missing"},
        nil,
        0,
        %{}
      )

    assert string_key_live_view.selected_run["session_id"] == "in-progress"

    finished_only_view =
      DashboardEventStream.build(
        %{
          run_timelines: [
            %{"identifier" => "MT-203", "session_id" => "finished-a", "started_at" => @start_one, "finished_at" => @start_two, "timeline" => []},
            %{"identifier" => "MT-203", "session_id" => "finished-b", "started_at" => @start_two, "finished_at" => @start_three, "timeline" => []}
          ]
        },
        %{"issue_identifier" => "MT-203", "session_id" => "missing"},
        nil,
        0,
        %{}
      )

    assert finished_only_view.selected_run["session_id"] == "finished-a"

    empty_timeline_view = DashboardEventStream.build(%{run_timelines: [%{"identifier" => "MT-202", "session_id" => "session-202", "timeline" => []}]}, nil, nil, 0, %{})
    assert empty_timeline_view.selected_run["session_id"] == "session-202"
    assert empty_timeline_view.rows == []
  end

  test "build handles rich rows across search facets, sources, artifacts, and fallbacks" do
    payload = %{run_timelines: rich_runs()}

    selected_issue_data = %{
      issue_identifier: "MT-300",
      issue_id: "issue-300",
      session_id: "session-300-a",
      started_at: @start_two,
      state: "In Progress",
      adapter: "pi",
      project: "rondo/dashboard",
      model_routing: %{resolved: %{adapter: "pi", model: "openrouter/z-ai/glm-5.2"}}
    }

    view =
      DashboardEventStream.build(payload, selected_issue_data, nil, 0, %{
        result: "pass",
        sort: "time_asc"
      })

    assert view.selected_run.session_id == "session-300-a"
    assert view.total_count == 9
    assert view.filtered_count == 1
    assert [%{kind: "gates_completed", artifacts: artifacts, kind_class: "event-kind-pill event-kind-gate", status_class: "state-badge state-badge-active"}] = view.rows
    assert artifacts == ["gate_results: artifacts/gates/results.json", "artifacts/gates/summary.json", "artifact.txt", "%{foo: \"bar\"}"]
    assert view.facets == %{"decision" => 1, "event" => 3, "gates" => 1, "interrupt" => 1, "terminal" => 1, "tool" => 2}
    assert view.options.kinds == ["continue", "event", "failed", "gates_completed", "pause", "tool_activity", "write"]
    assert view.options.results == ["failed", "pass", "paused", "retrying"]

    minimal_result_view =
      DashboardEventStream.build(
        %{
          run_timelines: [
            %{
              identifier: "MT-301",
              issue_id: "issue-301",
              session_id: "session-301",
              started_at: @start_one,
              status: "running",
              project: "rondo/minimal",
              timeline: [
                %{
                  at: @gate_time,
                  kind: "gates_completed",
                  phase: "gates",
                  status: "pass",
                  outcome: "pass",
                  summary: "gate passed",
                  source: %{checkpoint_kind: "gate_snapshot"}
                }
              ]
            }
          ]
        },
        %{
          issue_identifier: "MT-301",
          issue_id: "issue-301",
          session_id: "session-301",
          started_at: @start_one,
          state: "In Progress",
          project: "rondo/minimal",
          adapter: "pi"
        },
        nil,
        0,
        %{result: "pass"}
      )

    assert length(minimal_result_view.rows) == 1
  end

  test "build searches kind, summary, issue, provider, model, action, and artifact names" do
    payload = %{run_timelines: rich_runs()}

    selected_issue_data = %{
      issue_identifier: "MT-300",
      issue_id: "issue-300",
      session_id: "session-300-a",
      started_at: @start_two,
      state: "In Progress",
      adapter: "pi",
      project: "rondo/dashboard",
      model_routing: %{resolved: %{adapter: "pi", model: "openrouter/z-ai/glm-5.2"}}
    }

    for {query, expected_count, predicate} <- [
          {"gates_completed", 1, fn row -> row.kind == "gates_completed" end},
          {"gates passed", 1, fn row -> row.summary == "gates passed" end},
          {"MT-300", 9, fn row -> row.issue_identifier == "MT-300" end},
          {"pi", 9, fn row -> row.provider == "pi" end},
          {"glm-5.2", 9, fn row -> row.model == "openrouter/z-ai/glm-5.2" end},
          {"gate_snapshot", 1, fn row -> row.action == "gate_snapshot" end},
          {"results.json", 1, fn row -> Enum.any?(row.artifacts, &String.contains?(&1, "results.json")) end},
          {"artifact.txt", 1, fn row -> Enum.any?(row.artifacts, &String.contains?(&1, "artifact.txt")) end}
        ] do
      view =
        DashboardEventStream.build(payload, selected_issue_data, nil, 0, %{
          query: query,
          sort: "time_asc"
        })

      assert view.filtered_count == expected_count
      assert Enum.any?(view.rows, predicate)
    end
  end

  test "build filters by exact model and exposes model options" do
    payload = %{run_timelines: rich_runs()}

    selected_issue_data = %{
      issue_identifier: "MT-300",
      issue_id: "issue-300",
      session_id: "session-300-a",
      started_at: @start_two,
      state: "In Progress",
      adapter: "pi",
      project: "rondo/dashboard",
      model_routing: %{resolved: %{adapter: "pi", model: "openrouter/z-ai/glm-5.2"}}
    }

    view =
      DashboardEventStream.build(payload, selected_issue_data, nil, 0, %{
        model: "openrouter/z-ai/glm-5.2",
        sort: "time_asc"
      })

    assert view.filtered_count == 9
    assert Enum.all?(view.rows, &(&1.model == "openrouter/z-ai/glm-5.2"))
    assert view.options.models == ["openrouter/z-ai/glm-5.2"]

    empty_view =
      DashboardEventStream.build(payload, selected_issue_data, nil, 0, %{
        model: "wrong-model",
        sort: "time_asc"
      })

    assert empty_view.filtered_count == 0
    assert empty_view.rows == []
  end

  test "facet choices keep known facets ordered and include workspace" do
    payload = %{run_timelines: facet_rich_runs()}

    selected_issue_data = %{
      issue_identifier: "MT-FACET",
      issue_id: "issue-facet",
      session_id: "session-facet",
      started_at: @start_one,
      state: "running",
      adapter: "pi",
      project: "rondo/facets",
      model_routing: %{resolved: %{adapter: "pi", model: "pi-model"}}
    }

    view = DashboardEventStream.build(payload, selected_issue_data, nil, 0, %{})

    assert Enum.map(DashboardEventStream.facet_choices(view.facets), &elem(&1, 0)) ==
             ["turn", "workspace", "tool", "gates", "decision", "interrupt", "terminal"]

    assert DashboardEventStream.facet_choices(view.facets)
           |> Enum.find(fn {facet, _, _} -> facet == "workspace" end)
           |> then(fn {_facet, _label, count} -> count == 1 end)
  end

  test "build prefers the live run when both live and archived runs exist" do
    payload = %{run_timelines: mixed_issue_runs()}

    selected_issue_data = %{
      issue_identifier: "MT-MIXED",
      issue_id: "issue-mixed",
      session_id: "session-live",
      started_at: @start_two,
      state: "In Progress",
      adapter: "pi",
      project: "rondo/mixed",
      model_routing: %{resolved: %{adapter: "pi", model: "live-model"}}
    }

    view = DashboardEventStream.build(payload, selected_issue_data, nil, 0, %{sort: "time_asc"})

    assert view.selected_run.session_id == "session-live"
    assert [%{summary: "live event"}] = view.rows
  end

  test "build honors explicit archived selection when archived runs are supplied" do
    payload = %{run_timelines: mixed_issue_runs()}

    selected_issue_data = %{
      issue_identifier: "MT-MIXED",
      issue_id: "issue-mixed",
      session_id: "session-live",
      started_at: @start_two,
      state: "In Progress",
      adapter: "pi",
      project: "rondo/mixed",
      model_routing: %{resolved: %{adapter: "pi", model: "live-model"}}
    }

    archived_selection = [%{session_id: "session-archived", started_at: @start_one}]

    view = DashboardEventStream.build(payload, selected_issue_data, archived_selection, 0, %{sort: "time_asc"})

    assert view.selected_run.session_id == "session-archived"
    assert [%{summary: "archived event"}] = view.rows
  end

  test "dashboard query params keep only whitelisted values" do
    assert DashboardLive.dashboard_query_params(%{
             "issue" => "MT-500",
             "run" => 2,
             "query" => "gate",
             "facet" => "tool",
             "model" => "glm-5.2",
             "from" => "2026-06-29T10:00:00Z",
             "to" => "",
             "_target" => "query",
             "_csrf_token" => "token",
             "junk" => "drop me"
           }) == %{
             "issue" => "MT-500",
             "run" => "2",
             "query" => "gate",
             "facet" => "tool",
             "model" => "glm-5.2",
             "from" => "2026-06-29T10:00:00Z",
             "to" => ""
           }
  end

  defp facet_rich_runs do
    [
      %{
        identifier: "MT-FACET",
        issue_id: "issue-facet",
        session_id: "session-facet",
        started_at: @start_one,
        status: "running",
        adapter: "pi",
        project: "rondo/facets",
        model_routing: %{resolved: %{adapter: "pi", model: "pi-model"}},
        timeline: [
          %{
            at: @start_one,
            kind: "turn_started",
            phase: "turn",
            status: "started",
            outcome: "started",
            summary: "turn started",
            source: %{checkpoint_kind: "turn_started"},
            artifacts: []
          },
          %{
            at: @gate_time,
            kind: "workspace_ready",
            phase: "workspace",
            status: "ready",
            outcome: "ready",
            summary: "workspace ready",
            source: %{checkpoint_kind: "workspace_ready"},
            artifacts: []
          },
          %{
            at: @terminal_time,
            kind: "gates_completed",
            phase: "gates",
            status: "pass",
            outcome: "pass",
            summary: "gates passed",
            source: %{checkpoint_kind: "gate_snapshot"},
            artifacts: []
          },
          %{
            at: DateTime.add(@terminal_time, 30, :second),
            kind: "continue",
            phase: "decision",
            status: "retrying",
            outcome: "retry",
            summary: "continue retry",
            source: %{checkpoint_kind: "resume"},
            artifacts: []
          },
          %{
            at: DateTime.add(@terminal_time, 60, :second),
            kind: "pause",
            phase: "interrupt",
            status: "paused",
            outcome: "paused",
            summary: "interrupt pause",
            source: %{"kind" => "manual_interrupt"},
            artifacts: []
          },
          %{
            at: DateTime.add(@terminal_time, 90, :second),
            kind: "failed",
            phase: "terminal",
            status: "failed",
            outcome: "failed",
            summary: "failed hard",
            source: %{kind: "final_report"},
            artifacts: []
          },
          %{
            at: @tool_time,
            kind: "tool_activity",
            phase: "tool",
            status: "completed",
            outcome: "tool",
            summary: "tool call",
            source: %{kind: "cli"},
            artifacts: []
          }
        ]
      }
    ]
  end

  defp mixed_issue_runs do
    [
      %{
        identifier: "MT-MIXED",
        issue_id: "issue-mixed",
        session_id: "session-live",
        started_at: @start_two,
        status: "running",
        adapter: "pi",
        project: "rondo/mixed",
        model_routing: %{resolved: %{adapter: "pi", model: "live-model"}},
        timeline: [
          %{at: @gate_time, kind: "event", phase: "event", status: "event", outcome: "event", summary: "live event", source: %{}, artifacts: []}
        ]
      },
      %{
        identifier: "MT-MIXED",
        issue_id: "issue-mixed",
        session_id: "session-archived",
        started_at: @start_one,
        status: "completed",
        adapter: "pi",
        project: "rondo/mixed",
        model_routing: %{resolved: %{adapter: "pi", model: "archived-model"}},
        timeline: [
          %{at: @gate_time, kind: "event", phase: "event", status: "event", outcome: "event", summary: "archived event", source: %{}, artifacts: []}
        ]
      }
    ]
  end

  defp archived_runs do
    [
      %{
        identifier: "MT-200",
        issue_id: "issue-200",
        session_id: "session-200-a",
        started_at: @start_one,
        status: "completed",
        model_routing: %{provider: "anthropic", fallback: %{model: "fallback-model"}},
        project: "rondo/provider-a",
        timeline: [
          %{at: @gate_time, kind: "continue", phase: "decision", status: "retrying", outcome: "retry", summary: "continue retry", source: %{"checkpoint_kind" => "resume"}}
        ]
      },
      %{
        identifier: "MT-200",
        issue_id: "issue-200",
        session_id: "session-200-b",
        started_at: @start_two,
        status: "completed",
        model: "top-level-model",
        project: "rondo/provider-b",
        timeline: [
          %{at: @terminal_time, kind: "failed", phase: "terminal", status: "failed", outcome: "failed", summary: "failed hard", source: %{kind: "final_report"}}
        ]
      },
      %{
        identifier: "MT-200",
        issue_id: "issue-200",
        session_id: "session-200-c",
        started_at: @start_three,
        status: "running",
        model_routing: %{adapter: "openrouter", resolved: %{model: "openrouter/o3"}},
        project: "rondo/provider-c",
        timeline: [
          %{at: @tool_time, kind: "tool_activity", phase: "tool", status: "completed", outcome: "tool", summary: "tool call", source: %{kind: "cli"}}
        ]
      }
    ]
  end

  defp rich_runs do
    [
      %{
        identifier: "MT-300",
        issue_id: "issue-300",
        session_id: "session-300-a",
        started_at: @start_two,
        status: "running",
        adapter: "pi",
        project: "rondo/dashboard",
        model_routing: %{resolved: %{adapter: "pi", model: "openrouter/z-ai/glm-5.2"}},
        timeline: [
          nil,
          %{at: nil, kind: "event", phase: "event", status: "event", outcome: "event", summary: "default event", source: %{}, artifacts: []},
          %{at: "2026-06-29T10:00:15Z", kind: "event", phase: "event", status: "event", outcome: "event", summary: "artifact nil", source: %{}, artifacts: nil},
          %{
            at: "",
            kind: "pause",
            phase: "interrupt",
            status: "paused",
            outcome: "paused",
            summary: "interrupt pause",
            source: %{"kind" => "manual_interrupt"},
            artifacts: [%{kind: "checkpoint", path: "checkpoints/0001.json"}]
          },
          %{
            at: "2026-06-29T10:00:30",
            kind: "gates_completed",
            phase: "gates",
            status: "pass",
            outcome: "pass",
            summary: "gates passed",
            source: %{checkpoint_kind: "gate_snapshot"},
            artifacts: [%{kind: "gate_results", path: "artifacts/gates/results.json"}, %{path: "artifacts/gates/summary.json"}, "artifact.txt", %{foo: "bar"}]
          },
          %{at: 123, kind: "write", phase: "workspace", status: "ready", outcome: "tool", summary: "workspace write", source: %{}, artifacts: []},
          %{at: "not-a-date", kind: "continue", phase: "decision", status: "retrying", outcome: "retry", summary: "continue retry", source: %{"checkpoint_kind" => "resume"}, artifacts: []},
          %{
            at: @terminal_time,
            kind: "failed",
            phase: "terminal",
            status: "failed",
            outcome: "failed",
            summary: "failed hard",
            source: %{kind: "final_report"},
            artifacts: []
          },
          %{
            at: @tool_time,
            kind: "tool_activity",
            phase: "tool",
            status: "completed",
            outcome: "tool",
            summary: "tool call",
            source: %{kind: "cli"},
            artifacts: true
          }
        ]
      }
    ]
  end

  defp live_runs do
    [
      %{
        identifier: "MT-100",
        issue_id: "issue-100",
        session_id: "session-100-a",
        started_at: nil,
        status: "completed",
        project: "rondo/dashboard",
        timeline: [
          nil,
          %{at: nil, kind: "event", phase: "event", status: "event", outcome: "event", summary: "default event", source: %{}, artifacts: []},
          %{
            at: "",
            kind: "pause",
            phase: "interrupt",
            status: "paused",
            outcome: "paused",
            summary: "interrupt pause",
            source: %{"kind" => "manual_interrupt"},
            artifacts: [%{kind: "checkpoint", path: "checkpoints/0001.json"}]
          },
          %{
            at: "2026-06-29T10:00:30Z",
            kind: "gates_completed",
            phase: "gates",
            status: "pass",
            outcome: "pass",
            summary: "gates passed",
            source: %{checkpoint_kind: "gate_snapshot"},
            artifacts: [
              %{kind: "gate_results", path: "artifacts/gates/results.json"},
              %{path: "artifacts/gates/summary.json"},
              "artifact.txt",
              %{foo: "bar"}
            ]
          },
          %{at: 123, kind: "write", phase: "workspace", status: "ready", outcome: "tool", summary: "workspace write", source: %{}, artifacts: []},
          %{at: "not-a-date", kind: "continue", phase: "decision", status: "retrying", outcome: "retry", summary: "continue retry", source: %{"checkpoint_kind" => "resume"}, artifacts: []},
          %{
            at: @terminal_time,
            kind: "failed",
            phase: "terminal",
            status: "failed",
            outcome: "failed",
            summary: "failed hard",
            source: %{kind: "final_report"},
            artifacts: []
          },
          %{
            at: @tool_time,
            kind: "tool_activity",
            phase: "tool",
            status: "completed",
            outcome: "tool",
            summary: "tool call",
            source: %{kind: "cli"},
            artifacts: []
          }
        ]
      },
      %{
        identifier: "MT-100",
        issue_id: "issue-100",
        session_id: "session-100-b",
        started_at: @start_two,
        status: "running",
        project: "rondo/dashboard",
        timeline: [
          %{
            at: @gate_time,
            kind: "gates_completed",
            phase: "gates",
            status: "pass",
            outcome: "pass",
            summary: "gates passed",
            source: %{checkpoint_kind: "gate_snapshot"},
            artifacts: [%{kind: "gate_results", path: "artifacts/gates/results.json"}]
          },
          %{
            at: @terminal_time,
            kind: "failed",
            phase: "terminal",
            status: "failed",
            outcome: "failed",
            summary: "failed hard",
            source: %{kind: "final_report"},
            artifacts: []
          },
          %{
            at: @tool_time,
            kind: "tool_activity",
            phase: "tool",
            status: "completed",
            outcome: "tool",
            summary: "tool call",
            source: %{kind: "cli"},
            artifacts: []
          }
        ]
      }
    ]
  end
end
