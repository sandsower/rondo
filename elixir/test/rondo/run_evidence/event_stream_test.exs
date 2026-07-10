defmodule Rondo.RunEvidence.EventStreamTest do
  use Rondo.TestSupport

  alias Rondo.RunEvidence.EventStream

  test "exposes the schema id and run-dir-relative path as one source of truth" do
    assert EventStream.schema() == "rondo.events/v0"
    assert EventStream.relative_path() == "artifacts/agent-events.ndjson"
    assert EventStream.path("/runs/abc") == "/runs/abc/artifacts/agent-events.ndjson"
    assert EventStream.path("/runs/abc/artifacts/agent-events.ndjson") == "/runs/abc/artifacts/agent-events.ndjson"
    assert EventStream.path(nil) == nil
  end

  test "normalize_event builds the rondo.events/v0 record with a stable key set" do
    record =
      EventStream.normalize_event(
        %{
          event: :invocation_completed,
          adapter: "claude_code",
          run_ref: %{"provider_ref" => "session-9"},
          session_id: "session-9",
          usage: %{"input_tokens" => 1}
        },
        timestamp: "2026-05-10T15:30:12Z"
      )

    assert record["schema"] == "rondo.events/v0"
    assert record["timestamp"] == "2026-05-10T15:30:12Z"
    assert record["event"] == "invocation_completed"
    assert record["adapter"] == "claude_code"
    assert record["session_id"] == "session-9"
    assert record["raw"] == %{}

    assert Enum.sort(Map.keys(record)) == ["adapter", "event", "raw", "run_ref", "schema", "session_id", "timestamp", "usage"]
  end

  test "normalize_event stringifies missing/atom event kinds and threads the injected sanitizers" do
    upcase = fn
      value when is_binary(value) -> String.upcase(value)
      value -> value
    end

    record =
      EventStream.normalize_event(
        %{"event" => nil, "adapter" => "beislid", "raw" => %{"note" => "keep"}, "accounted_usage" => %{"total_tokens" => 7}},
        timestamp: "t0",
        sanitize: upcase,
        sanitize_raw: fn raw -> Map.put(raw, "sanitized", true) end
      )

    assert record["event"] == "unknown"
    assert record["adapter"] == "BEISLID"
    assert record["raw"] == %{"note" => "keep", "sanitized" => true}
    # accounted_usage is only present when the source event carries it, and is sanitized.
    assert record["accounted_usage"] == %{"total_tokens" => 7}
  end

  test "append then read round-trips normalized records through the ndjson log" do
    run_dir = tmp_dir("event-stream-roundtrip")

    for event <- ["session_started", "result"] do
      assert :ok = EventStream.append(run_dir, EventStream.normalize_event(%{"event" => event}, timestamp: "t"))
    end

    events = EventStream.read(run_dir)
    assert Enum.map(events, & &1["event"]) == ["session_started", "result"]
    assert Enum.all?(events, &(&1["schema"] == "rondo.events/v0"))
  end

  test "read tolerates a missing event log" do
    run_dir = tmp_dir("event-stream-missing")
    assert EventStream.read(run_dir) == []
    assert EventStream.read(nil) == []
  end

  test "read skips malformed and non-map lines without raising" do
    run_dir = tmp_dir("event-stream-malformed")
    path = EventStream.path(run_dir)
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    {"schema":"rondo.events/v0","event":"session_started"}
    not json at all
    {"partial":
    "a bare json string"
    123
    {"schema":"rondo.events/v0","event":"result"}
    """)

    events = EventStream.read(run_dir)
    assert Enum.map(events, & &1["event"]) == ["session_started", "result"]
  end

  test "repair_torn_tail preserves complete records and makes the next append readable" do
    run_dir = tmp_dir("event-stream-torn-tail")
    path = EventStream.path(run_dir)
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, "{\"schema\":\"rondo.events/v0\",\"event\":\"complete\"}\n{\"partial\":")

    assert :ok = EventStream.repair_torn_tail(run_dir)
    assert File.read!(path) == "{\"schema\":\"rondo.events/v0\",\"event\":\"complete\"}\n"

    assert :ok =
             EventStream.append(
               run_dir,
               EventStream.normalize_event(%{"event" => "after_repair"}, timestamp: "t")
             )

    assert Enum.map(EventStream.read(run_dir), & &1["event"]) == ["complete", "after_repair"]
  end

  test "repair_torn_tail preserves valid final records that lack only a newline" do
    for {name, contents, expected} <- [
          {
            "single",
            ~s({"schema":"rondo.events/v0","event":"single"}),
            ["single", "after_repair"]
          },
          {
            "following",
            ~s({"schema":"rondo.events/v0","event":"first"}\n{"schema":"rondo.events/v0","event":"second"}),
            ["first", "second", "after_repair"]
          }
        ] do
      run_dir = tmp_dir("event-stream-valid-tail-#{name}")
      path = EventStream.path(run_dir)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)

      assert :ok = EventStream.repair_torn_tail(run_dir)
      assert String.ends_with?(File.read!(path), "\n")

      assert :ok =
               EventStream.append(
                 run_dir,
                 EventStream.normalize_event(%{"event" => "after_repair"}, timestamp: "t")
               )

      assert Enum.map(EventStream.read(run_dir), & &1["event"]) == expected
    end
  end

  test "cumulative_usage_deltas diffs repeated cumulative snapshots and never goes negative" do
    events = [
      %{"usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}},
      # repeated identical cumulative snapshot -> zero delta
      %{"usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}},
      # accounted_usage takes precedence and advances the cumulative counter
      %{"accounted_usage" => %{"input_tokens" => 25, "output_tokens" => 9, "total_tokens" => 34}},
      # no usage on this event -> carries forward, zero delta
      %{"event" => "gates_completed"}
    ]

    assert EventStream.usage_snapshots(events) == [
             %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15},
             %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15},
             %{"input_tokens" => 25, "output_tokens" => 9, "total_tokens" => 34},
             %{}
           ]

    assert EventStream.cumulative_usage_deltas(events) == [
             %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15},
             %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
             %{"input_tokens" => 15, "output_tokens" => 4, "total_tokens" => 19},
             %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}
           ]
  end

  test "surfaces artifact-linked events using the shared RON-128 evidence vocabulary" do
    events = [
      %{"event" => "session_started"},
      %{"event" => "gates_completed", "artifacts" => [%{"kind" => "gate_results", "path" => "artifacts/gates/results.json"}, %{"kind" => "bad"}]},
      %{"event" => "result", "raw" => %{"artifacts" => [%{kind: "final_report", path: "artifacts/final-report.json"}]}}
    ]

    assert EventStream.artifact_refs(Enum.at(events, 0)) == []

    assert EventStream.artifact_refs(Enum.at(events, 1)) == [
             %{"kind" => "gate_results", "path" => "artifacts/gates/results.json"}
           ]

    assert EventStream.artifact_refs(Enum.at(events, 2)) == [%{kind: "final_report", path: "artifacts/final-report.json"}]

    linked = EventStream.artifact_linked_events(events)
    assert Enum.map(linked, & &1["event"]) == ["gates_completed", "result"]
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
