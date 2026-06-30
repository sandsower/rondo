defmodule RondoWeb.EventInspectorTest do
  use Rondo.TestSupport

  alias RondoWeb.EventInspector

  test "event entries preserve indices and filter by query and role" do
    issue_data = %{
      run_id: "run-1",
      run_dir: "/tmp/rondo/runs/run-1",
      session_id: "session-1",
      turn_count: 3,
      event_log: [
        %{at: "2026-06-29T22:00:00Z", event: :assistant, message: "Draft prompt for the operator"},
        %{at: "2026-06-29T22:00:05Z", event: :bash, message: "$ mix test"},
        %{at: "2026-06-29T22:00:10Z", event: :result, message: "completed"}
      ]
    }

    prompt_entries = EventInspector.event_entries(issue_data, %{query: "prompt", category: :prompt})
    assert [%{index: 0, category: :prompt, category_label: "Prompt"}] = prompt_entries

    tool_entries = EventInspector.event_entries(issue_data, %{query: "mix", category: :tool})
    assert [%{index: 1, category: :tool, category_label: "Tool"}] = tool_entries

    visible_entries = EventInspector.event_entries(issue_data, %{query: "", category: :all})
    assert Enum.map(visible_entries, & &1.index) == [0, 1, 2]
    assert Enum.map(visible_entries, & &1.event) == [:assistant, :bash, :result]
  end

  test "event entries ignore invalid string categories" do
    issue_data = %{
      event_log: [
        %{at: "2026-06-29T22:00:00Z", event: :assistant, message: "hello"},
        %{at: "2026-06-29T22:00:05Z", event: :bash, message: "mix test"}
      ]
    }

    assert Enum.map(EventInspector.event_entries(issue_data, %{category: "not-a-real-category"}), & &1.index) == [0, 1]
    assert Enum.map(EventInspector.event_entries(issue_data, %{query: "mix", category: "not-a-real-category"}), & &1.index) == [1]
  end

  test "select event detail loads the raw payload and metadata from the ndjson artifact" do
    run_dir = Path.join(System.tmp_dir!(), "rondo-event-inspector-#{System.unique_integer([:positive])}")
    artifact_dir = Path.join(run_dir, "artifacts")
    File.mkdir_p!(artifact_dir)

    on_exit(fn -> File.rm_rf(run_dir) end)

    lines = [
      %{
        "schema" => "rondo-agent-events-v1",
        "timestamp" => "2026-06-29T22:00:00Z",
        "event" => "assistant_message",
        "adapter" => "pi",
        "session_id" => "session-123",
        "raw" => %{"message" => %{"content" => [%{"type" => "text", "text" => "Draft prompt"}]}}
      },
      %{
        "schema" => "rondo-agent-events-v1",
        "timestamp" => "2026-06-29T22:00:05Z",
        "event" => "tool_completed",
        "adapter" => "pi",
        "session_id" => "session-123",
        "file_path" => "lib/rondo_web/live/dashboard_live.ex",
        "raw" => %{"message" => %{"content" => [%{"type" => "text", "text" => "ok"}]}}
      }
    ]

    File.write!(Path.join(artifact_dir, "agent-events.ndjson"), Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")

    issue_data = %{
      run_id: "run-123",
      run_dir: run_dir,
      session_id: "session-123",
      turn_count: 5,
      model_routing: %{resolved: %{adapter: "pi", model: "openrouter/deepseek/deepseek-chat"}},
      event_log: [
        %{at: "2026-06-29T22:00:00Z", event: :assistant, message: "Draft prompt"},
        %{at: "2026-06-29T22:00:05Z", event: :tool, message: "bash: ok"}
      ]
    }

    assert {:ok, detail} = EventInspector.select_event_detail(issue_data, 1)

    assert detail.index == 1
    assert detail.session_id == "session-123"
    assert detail.run_id == "run-123"
    assert detail.turn_count == 5
    assert detail.adapter == "pi"
    assert detail.provider == "pi"
    assert detail.model == "openrouter/deepseek/deepseek-chat"
    assert detail.source_path == Path.join([run_dir, "artifacts", "agent-events.ndjson"])
    assert Enum.any?(detail.artifact_links, &(&1.path == "lib/rondo_web/live/dashboard_live.ex"))
    assert detail.raw["event"] == "tool_completed"
    assert detail.raw_json =~ "tool_completed"
    assert detail.raw_json =~ "lib/rondo_web/live/dashboard_live.ex"
    assert detail.structured_fields |> Enum.any?(fn {label, value} -> label == "Adapter" and value == "pi" end)
    assert detail.structured_fields |> Enum.any?(fn {label, value} -> label == "Turn" and value == 5 end)
  end

  test "event entries cover roles, filters, and invalid inputs" do
    issue_data = %{
      session_id: [],
      run_id: "run-1",
      run_dir: "/tmp/rondo/runs/run-1",
      turn_count: 3,
      event_log: [
        %{at: "2026-06-29T22:00:00Z", event: :assistant, message: "Draft prompt"},
        %{at: "2026-06-29T22:00:05Z", event: :assistant_message, message: "Draft prompt again"},
        %{at: "2026-06-29T22:00:10Z", event: :bash, message: "$ mix test"},
        %{at: "2026-06-29T22:00:15Z", event: :result, message: "completed"},
        %{at: "2026-06-29T22:00:20Z", event: :warning, message: "gate failed"},
        %{at: "2026-06-29T22:00:25Z", event: :session_started, message: "boot"},
        %{at: "2026-06-29T22:00:30Z", event: :unknown, message: "misc"}
      ]
    }

    assert [
             %{index: 0, category: :prompt, category_label: "Prompt"},
             %{index: 1, category: :prompt, category_label: "Prompt"},
             %{index: 2, category: :tool, category_label: "Tool"},
             %{index: 3, category: :result, category_label: "Result"},
             %{index: 4, category: :gate, category_label: "Gate"},
             %{index: 5, category: :system, category_label: "System"},
             %{index: 6, category: :other, category_label: "Other"}
           ] = EventInspector.event_entries(issue_data)

    assert EventInspector.event_categories(issue_data) == [:prompt, :tool, :result, :gate, :system, :other]
    assert EventInspector.event_entries(issue_data, %{query: 123, category: :prompt}) == []
    assert EventInspector.event_entries(:not_a_map, %{query: 123, category: :prompt}) == []
    assert {:error, :event_not_found} = EventInspector.select_event_detail(issue_data, -1)
    assert {:error, :event_not_found} = EventInspector.select_event_detail(issue_data, 99)
    assert EventInspector.event_source_path(%{run_dir: "   "}) == nil
  end

  test "event entries classify string tool, gate, and final report events" do
    issue_data = %{
      event_log: [
        %{at: "2026-06-29T22:00:00Z", event: "turn_started", message: "Draft prompt"},
        %{at: "2026-06-29T22:00:05Z", event: "bash", message: "$ mix test"},
        %{at: "2026-06-29T22:00:10Z", event: "gates_completed", message: "gates pass"},
        %{at: "2026-06-29T22:00:15Z", event: "turn_completed", message: "turn complete"},
        %{at: "2026-06-29T22:00:20Z", event: "final_report_validated", message: "final report valid"}
      ]
    }

    assert [
             %{index: 0, category: :prompt},
             %{index: 1, category: :tool},
             %{index: 2, category: :gate},
             %{index: 3, category: :result},
             %{index: 4, category: :result}
           ] = EventInspector.event_entries(issue_data)

    assert EventInspector.event_categories(issue_data) == [:prompt, :tool, :gate, :result]
  end

  test "select event detail exposes prompt, tool, gate, and final report data" do
    run_dir = tmp_event_dir("schema-aware")
    artifact_dir = Path.join(run_dir, "artifacts")
    File.mkdir_p!(artifact_dir)

    on_exit(fn -> File.rm_rf(run_dir) end)

    File.write!(
      Path.join(artifact_dir, "final-report.json"),
      Jason.encode!(%{
        "schema" => "rondo.final_report/v0",
        "summary" => "Did the work",
        "changed_files" => ["lib/a.ex"],
        "gates_run" => [%{"name" => "elixir-ci", "status" => "pass"}],
        "failures" => [],
        "risks" => [],
        "next_state" => "ready_for_review"
      })
    )

    write_event_log!(run_dir, [
      %{
        "schema" => "rondo.events/v0",
        "timestamp" => "2026-06-29T22:10:00Z",
        "event" => "assistant_message",
        "adapter" => "pi",
        "session_id" => "session-123",
        "raw" => %{
          "role" => "assistant",
          "summary" => "Prompt contents [REDACTED]",
          "message" => %{"content" => [%{"type" => "text", "text" => "[REDACTED]"}]}
        }
      },
      %{
        "schema" => "rondo.events/v0",
        "timestamp" => "2026-06-29T22:10:05Z",
        "event" => "tool_started",
        "adapter" => "pi",
        "session_id" => "session-123",
        "raw" => %{
          "tool" => "bash",
          "status" => "completed",
          "command" => "mix test",
          "output" => "ok",
          "path" => "lib/rondo_web/live/dashboard_live.ex",
          "results_path" => "artifacts/gates/results.json",
          "state_path" => "artifacts/gates/state.json"
        }
      },
      %{
        "schema" => "rondo.events/v0",
        "timestamp" => "2026-06-29T22:10:10Z",
        "event" => "gates_completed",
        "adapter" => "pi",
        "session_id" => "session-123",
        "raw" => %{
          "status" => "fail",
          "results" => [
            %{"name" => "credo", "status" => "fail"},
            %{"name" => "dialyzer", "status" => "pass"}
          ],
          "results_path" => "artifacts/gates/results.json",
          "state_path" => "artifacts/gates/state.json"
        }
      },
      %{
        "schema" => "rondo.events/v0",
        "timestamp" => "2026-06-29T22:10:15Z",
        "event" => "final_report_validated",
        "adapter" => "pi",
        "session_id" => "session-123",
        "raw" => %{"status" => "valid", "summary" => "Did the work"}
      }
    ])

    issue_data = %{
      run_id: "run-123",
      run_dir: run_dir,
      session_id: "session-123",
      turn_count: 5,
      model_routing: %{resolved: %{adapter: "pi", model: "openrouter/deepseek/deepseek-chat"}},
      event_log: [
        %{at: "2026-06-29T22:10:00Z", event: :assistant, message: "Prompt contents"},
        %{at: "2026-06-29T22:10:05Z", event: :tool_started, message: "bash: mix test"},
        %{at: "2026-06-29T22:10:10Z", event: :gates_completed, message: "gates pass"},
        %{at: "2026-06-29T22:10:15Z", event: :final_report_validated, message: "final report valid"}
      ]
    }

    assert {:ok, prompt_detail} = EventInspector.select_event_detail(issue_data, 0)
    assert prompt_detail.summary =~ "[REDACTED]"
    assert prompt_detail.has_redacted_content?
    assert Enum.any?(prompt_detail.structured_fields, fn {label, value} -> label == "Prompt" and value =~ "[REDACTED]" end)

    assert {:ok, tool_detail} = EventInspector.select_event_detail(issue_data, 1)
    assert Enum.any?(tool_detail.artifact_links, &(&1.path == "lib/rondo_web/live/dashboard_live.ex"))
    assert Enum.any?(tool_detail.artifact_links, &(&1.path == "artifacts/gates/results.json"))
    assert Enum.any?(tool_detail.artifact_links, &(&1.path == "artifacts/gates/state.json"))
    assert Enum.any?(tool_detail.structured_fields, fn {label, value} -> label == "Command" and value =~ "mix test" end)

    assert {:ok, gate_detail} = EventInspector.select_event_detail(issue_data, 2)
    assert Enum.any?(gate_detail.structured_fields, fn {label, value} -> label == "Failed gates" and value =~ "credo: fail" end)
    assert Enum.any?(gate_detail.artifact_links, &(&1.path == "artifacts/gates/results.json"))

    assert {:ok, result_detail} = EventInspector.select_event_detail(issue_data, 3)
    assert Enum.any?(result_detail.structured_fields, fn {label, value} -> label == "Summary" and value == "Did the work" end)
    assert Enum.any?(result_detail.structured_fields, fn {label, value} -> label == "Changed files" and value =~ "lib/a.ex" end)
    assert Enum.any?(result_detail.structured_fields, fn {label, value} -> label == "Gates run" and value =~ "elixir-ci: pass" end)
    assert Enum.any?(result_detail.artifact_links, &(&1.path == Path.join([run_dir, "artifacts", "final-report.json"])))
  end

  test "select event detail falls back to the raw event at index when matching fails" do
    run_dir = tmp_event_dir("raw-string")
    File.mkdir_p!(Path.join(run_dir, "artifacts"))

    File.write!(
      Path.join([run_dir, "artifacts", "agent-events.ndjson"]),
      "{not json}\n" <> Jason.encode!("fallback raw") <> "\n"
    )

    issue_data = %{
      run_id: "run-raw-string",
      run_dir: run_dir,
      session_id: "session-raw-string",
      event_log: [
        %{at: "2026-06-29T22:01:00Z", event: :tool, message: "ignored"},
        %{at: "2026-06-29T22:01:01Z", event: :tool, message: "fallback raw"}
      ]
    }

    on_exit(fn -> File.rm_rf(run_dir) end)

    assert {:ok, detail} = EventInspector.select_event_detail(issue_data, 1)
    assert detail.raw == "fallback raw"
    assert detail.raw_json =~ "\"fallback raw\""
  end

  test "select event detail falls back to parsed rows and missing rows by index" do
    run_dir = tmp_event_dir("parsed-rows")
    File.mkdir_p!(Path.join(run_dir, "artifacts"))

    File.write!(
      Path.join([run_dir, "artifacts", "agent-events.ndjson"]),
      Jason.encode!(%{
        "timestamp" => "2026-06-29T22:01:10Z",
        "event" => "note",
        "adapter" => "pi",
        "session_id" => "session-parsed",
        "summary" => "raw only"
      }) <> "\n"
    )

    issue_data = %{
      run_id: "run-parsed",
      run_dir: run_dir,
      session_id: "session-parsed",
      event_log: [
        %{at: "2026-06-29T22:01:10Z", event: :assistant, message: "mismatch"},
        %{at: "2026-06-29T22:01:11Z", event: :assistant, message: "missing"}
      ]
    }

    on_exit(fn -> File.rm_rf(run_dir) end)

    assert {:ok, parsed_detail} = EventInspector.select_event_detail(issue_data, 0)
    assert parsed_detail.raw["event"] == "note"
    assert parsed_detail.raw_json =~ "raw only"

    assert {:ok, missing_detail} = EventInspector.select_event_detail(issue_data, 1)
    assert missing_detail.raw["summary"] == "missing"
  end

  test "select event detail treats an invalid indexed payload as missing and falls back" do
    run_dir = tmp_event_dir("invalid-indexed")
    File.mkdir_p!(Path.join(run_dir, "artifacts"))

    File.write!(Path.join([run_dir, "artifacts", "agent-events.ndjson"]), "{not json}\n")

    issue_data = %{
      run_id: "run-invalid-indexed",
      run_dir: run_dir,
      session_id: "session-invalid-indexed",
      event_log: [%{at: "2026-06-29T22:01:20Z", event: :assistant, message: "ignored"}]
    }

    on_exit(fn -> File.rm_rf(run_dir) end)

    assert {:ok, detail} = EventInspector.select_event_detail(issue_data, 0)
    assert detail.raw["summary"] == "ignored"
    assert detail.raw_available?
  end

  test "select event detail skips blank entry fields that would match unrelated raw rows" do
    run_dir = tmp_event_dir("blank-match")

    write_event_log!(run_dir, [
      %{
        "timestamp" => "2026-06-29T22:01:30Z",
        "event" => "assistant_message",
        "adapter" => "pi",
        "session_id" => "session-blank-match",
        "summary" => "unrelated raw"
      },
      %{
        "timestamp" => "2026-06-29T22:01:30Z",
        "event" => "tool_completed",
        "adapter" => "pi",
        "session_id" => "session-blank-match",
        "summary" => "selected raw"
      }
    ])

    issue_data = %{
      run_id: "run-blank-match",
      run_dir: run_dir,
      session_id: "session-blank-match",
      adapter: "pi",
      event_log: [
        %{at: nil, event: nil, message: "unrelated"},
        %{at: nil, event: nil, message: "selected raw"}
      ]
    }

    on_exit(fn -> File.rm_rf(run_dir) end)

    assert {:ok, detail} = EventInspector.select_event_detail(issue_data, 1)
    assert detail.raw["event"] == "tool_completed"
    assert detail.raw["summary"] == "selected raw"
  end

  test "select event detail resolves same-event matches and turn and model fallbacks" do
    run_dir = tmp_event_dir("same-event")

    write_event_log!(run_dir, [
      %{
        "timestamp" => "2026-06-29T22:02:00Z",
        "event" => "tool",
        "adapter" => "pi",
        "session_id" => "session-direct",
        "model" => "raw-model",
        "turn_id" => "turn-direct"
      },
      %{
        "timestamp" => "2026-06-29T22:02:05Z",
        "event" => "tool",
        "adapter" => "pi",
        "session_id" => "session-nested",
        "turn" => %{"id" => "turn-nested"}
      }
    ])

    on_exit(fn -> File.rm_rf(run_dir) end)

    direct_issue = %{
      run_id: "run-direct",
      run_dir: run_dir,
      session_id: "session-direct",
      model_routing: %{resolved: %{adapter: "pi", model: "resolved-model"}},
      event_log: [%{at: "2026-06-29T22:02:00Z", event: :tool, message: "tool"}]
    }

    assert {:ok, direct_detail} = EventInspector.select_event_detail(direct_issue, 0)
    assert direct_detail.turn_id == "turn-direct"
    assert direct_detail.model == "raw-model"
    assert direct_detail.provider == "pi"

    nested_issue = %{
      run_id: "run-nested",
      run_dir: run_dir,
      session_id: "session-nested",
      model_fallback: %{next_candidate: %{model: "fallback-model"}},
      event_log: [%{at: "2026-06-29T22:02:05Z", event: :tool_completed, message: "tool"}]
    }

    assert {:ok, nested_detail} = EventInspector.select_event_detail(nested_issue, 0)
    assert nested_detail.turn_id == "turn-nested"
    assert nested_detail.model == "fallback-model"
  end

  test "select event detail keeps message summary fallbacks, turn params, and redaction flags" do
    run_dir = tmp_event_dir("message-summary")

    write_event_log!(run_dir, [
      %{
        "timestamp" => "2026-06-29T22:03:00Z",
        "event" => "note",
        "adapter" => "pi",
        "session_id" => "session-message",
        "summary" => "Prompt contents [REDACTED]",
        "message" => %{
          "content" => [%{"text" => "Prompt contents"}, %{text: "prompt"}, 1],
          "text" => "Prompt contents text",
          "turn" => %{"id" => "turn-message"}
        },
        "raw" => "tail"
      },
      %{
        "timestamp" => "2026-06-29T22:03:05Z",
        "event" => "note",
        "adapter" => "pi",
        "session_id" => "session-params",
        "summary" => "Loose",
        "redaction" => "[REDACTED]",
        "params" => %{"turn" => %{"id" => "turn-params"}}
      }
    ])

    on_exit(fn -> File.rm_rf(run_dir) end)

    message_issue = %{
      run_id: "run-message",
      run_dir: run_dir,
      session_id: "session-message",
      turn_count: 7,
      model_routing: %{resolved: %{adapter: "pi", model: "resolved-model"}},
      event_log: [%{at: "2026-06-29T22:03:00Z", event: :assistant, message: "Prompt contents"}]
    }

    assert {:ok, message_detail} = EventInspector.select_event_detail(message_issue, 0)
    assert message_detail.turn_id == "turn-message"
    assert message_detail.has_redacted_content?
    assert message_detail.raw_json =~ "Prompt contents text"
    assert message_detail.raw_json =~ "tail"
    assert message_detail.structured_fields |> Enum.any?(fn {label, value} -> label == "Turn" and value == "turn-message" end)

    params_issue = %{
      run_id: "run-params",
      run_dir: run_dir,
      session_id: "session-params",
      turn_count: nil,
      model_fallback: %{next_candidate: %{model: "fallback-model"}},
      event_log: [%{at: "2026-06-29T22:03:05Z", event: :assistant, message: "Loose summary"}]
    }

    assert {:ok, params_detail} = EventInspector.select_event_detail(params_issue, 0)
    assert params_detail.turn_id == "turn-params"
    assert params_detail.turn_count == nil
    assert params_detail.model == "fallback-model"
    assert params_detail.has_redacted_content?
    assert params_detail.raw_json =~ "Loose"
    assert params_detail.raw_json =~ "[REDACTED]"
  end

  test "select event detail falls back to a generated raw payload when the artifact is absent" do
    run_dir = tmp_event_dir("missing-artifact")

    issue_data = %{
      run_id: "run-missing",
      run_dir: Path.join(run_dir, "does-not-exist"),
      session_id: "session-missing",
      event_log: [%{at: "2026-06-29T22:04:00Z", event: :assistant, message: self()}]
    }

    on_exit(fn -> File.rm_rf(run_dir) end)

    assert {:ok, detail} = EventInspector.select_event_detail(issue_data, 0)
    assert detail.raw["summary"] == self()
    assert detail.raw_json =~ "#PID"
    assert detail.raw_available?
  end

  test "select event detail redacts secret-shaped text in generated raw payloads" do
    run_dir = tmp_event_dir("redacted-fallback")

    issue_data = %{
      run_id: "run-redacted",
      run_dir: Path.join(run_dir, "does-not-exist"),
      session_id: "session-redacted",
      event_log: [
        %{at: "2026-06-29T22:04:30Z", event: :assistant, message: "Bearer sk-1234567890abcdef"}
      ]
    }

    on_exit(fn -> File.rm_rf(run_dir) end)

    assert {:ok, detail} = EventInspector.select_event_detail(issue_data, 0)
    assert detail.summary =~ "[REDACTED]"
    assert detail.raw_json =~ "[REDACTED]"
    refute detail.raw_json =~ "sk-1234567890abcdef"
    assert detail.has_redacted_content?
  end

  defp tmp_event_dir(prefix) do
    Path.join(System.tmp_dir!(), "rondo-event-inspector-#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp write_event_log!(run_dir, rows) do
    artifact_dir = Path.join(run_dir, "artifacts")
    File.mkdir_p!(artifact_dir)
    File.write!(Path.join(artifact_dir, "agent-events.ndjson"), Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
  end
end
