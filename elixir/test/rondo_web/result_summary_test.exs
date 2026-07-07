defmodule RondoWeb.ResultSummaryTest do
  use ExUnit.Case, async: true

  alias RondoWeb.ResultSummary

  test "describes final reports from atom-key maps with structured fields first" do
    report = %{
      schema: "rondo.final_report/v0",
      summary: "Did the work",
      changed_files: ["lib/rondo_web/result_summary.ex"],
      gates_run: [%{name: "format", status: "pass"}],
      failures: [],
      risks: [],
      next_state: "ready_for_review"
    }

    summary = ResultSummary.describe(report)

    assert summary.kind == :final_report
    assert summary.preview == "ready_for_review · Did the work"

    assert summary.fields == [
             %{label: "Status", value: "ready_for_review"},
             %{label: "Files changed", value: "lib/rondo_web/result_summary.ex"},
             %{label: "Tests / gates", value: "format: pass"},
             %{label: "Next action", value: "ready_for_review"}
           ]

    assert summary.pretty =~ "\"schema\": \"rondo.final_report/v0\""
    assert summary.copy_text =~ "\"summary\":\"Did the work\""
  end

  test "describes final reports embedded in fenced json text" do
    summary =
      ResultSummary.describe("""
      operator note
      ```json
      {"schema":"rondo.final_report/v0","summary":"Did the work","changed_files":["lib/rondo_web/result_summary.ex"],"gates_run":[],"failures":[],"risks":[],"next_state":"ready_for_review"}
      ```
      tail note
      """)

    assert summary.kind == :final_report
    assert summary.preview == "ready_for_review · Did the work"
    assert summary.copy_text =~ "\"changed_files\":[\"lib/rondo_web/result_summary.ex\"]"
    refute summary.copy_text =~ "```json"
  end

  test "unwraps wrapped json payloads and summarizes unknown json" do
    summary = ResultSummary.describe(%{payload: Jason.encode!(%{"status" => "queued", "foo" => "bar"})})

    assert summary.kind == :json
    assert summary.preview == "JSON object · queued"

    assert summary.fields == [
             %{label: "Status", value: "queued"},
             %{label: "Foo", value: "bar"}
           ]

    assert summary.pretty =~ "\"foo\": \"bar\""
    assert summary.copy_text =~ "\"foo\":\"bar\""
  end

  test "describes json arrays with a readable fallback" do
    summary = ResultSummary.describe([1, 2, 3])

    assert summary.kind == :json
    assert summary.preview == "JSON array (3 items)"
    assert summary.fields == [%{label: "Items", value: "3"}]
    assert summary.pretty == "[\n  1,\n  2,\n  3\n]"
  end

  test "falls back to safe plain text for invalid json" do
    summary = ResultSummary.describe("{not json")

    assert summary.kind == :text
    assert summary.preview == "{not json"
    assert summary.fields == []
    assert summary.pretty == nil
    assert summary.copy_text == "{not json"
  end

  test "covers wrapped results, blank text, and non-json terms" do
    report = %{"status" => "queued", "foo" => "bar"}

    assert ResultSummary.describe("").preview == "n/a"
    assert ResultSummary.describe(:plain).kind == :text
    assert ResultSummary.describe(123).preview == "123"

    long_text = String.duplicate("a", 141)
    long_summary = ResultSummary.describe(long_text)
    assert long_summary.kind == :text
    assert long_summary.preview == String.duplicate("a", 139) <> "…"

    assert ResultSummary.describe(%{result: report}).kind == :json
    assert ResultSummary.describe(%{"result" => report}).kind == :json
    assert ResultSummary.describe(%{message: report}).kind == :json
    assert ResultSummary.describe(%{"message" => report}).kind == :json
    assert ResultSummary.describe(%{"payload" => report}).kind == :json
  end

  test "covers generic json formatting branches" do
    pid = self()

    summary = ResultSummary.describe(%{"foo" => []})
    assert summary.kind == :json
    assert summary.preview == "JSON object · []"
    assert summary.fields == [%{label: "Foo", value: "[]"}]

    summary = ResultSummary.describe(%{"foo" => ["one", "two"]})
    assert summary.kind == :json
    assert summary.fields == [%{label: "Foo", value: "one, two"}]

    summary = ResultSummary.describe(%{"status" => true})
    assert summary.preview == "JSON object · true"

    summary = ResultSummary.describe(%{"status" => 1})
    assert summary.preview == "JSON object · 1"

    summary = ResultSummary.describe(%{"foo" => nil})
    assert summary.kind == :json
    assert summary.fields == []

    summary = ResultSummary.describe(%{"foo" => [""]})
    assert summary.kind == :json
    assert summary.fields == [%{label: "Foo", value: "[\"\"]"}]

    summary = ResultSummary.describe(%{"atom" => :ok, "bool" => true, "empty_map" => %{}, "num" => 2, "pid" => pid})

    assert summary.fields == [
             %{label: "Atom", value: "ok"},
             %{label: "Bool", value: "true"},
             %{label: "Empty Map", value: "{}"},
             %{label: "Num", value: "2"},
             %{label: "Pid", value: inspect(pid)}
           ]

    assert summary.pretty =~ inspect(pid)
    assert summary.copy_text =~ inspect(pid)
  end

  test "normalizes date and time structs inside json payloads" do
    started_at = ~U[2026-07-01 21:13:38.654696Z]
    local_started_at = ~N[2026-07-01 21:13:38]
    started_on = ~D[2026-07-01]
    started_time = ~T[21:13:38]
    uri = %URI{scheme: "https", host: "example.test", path: "/run"}

    summary =
      ResultSummary.describe(%{
        status: "failed",
        metadata: %{
          started_at: started_at,
          local_started_at: local_started_at,
          started_on: started_on,
          started_time: started_time,
          uri: uri
        }
      })

    assert summary.kind == :json
    assert summary.preview == "JSON object · failed"
    assert %{label: "Metadata", value: metadata} = Enum.find(summary.fields, &(&1.label == "Metadata"))
    assert metadata =~ "2026-07-01T21:13:38.654696Z"
    assert metadata =~ "2026-07-01T21:13:38"
    assert metadata =~ "2026-07-01"
    assert metadata =~ "21:13:38"
    assert metadata =~ "example.test"
    assert summary.pretty =~ "2026-07-01T21:13:38.654696Z"
    assert summary.copy_text =~ "2026-07-01T21:13:38.654696Z"
  end

  test "describes final report diagnostic summaries" do
    summary =
      ResultSummary.describe(%{
        status: "invalid",
        reported_next_state: "In Progress",
        errors: ["summary must be a non-empty string, got: nil"],
        excerpt: "{\"schema\": \"rondo.final_report/v0\", \"next_state\": \"In Progress\"}",
        continuation_count: 1,
        fingerprint: "{\"schema\": \"rondo.final_report/v0\", \"next_state\": \"in progress\"}"
      })

    assert summary.kind == :json
    assert summary.preview == "JSON object · invalid"

    assert summary.fields == [
             %{label: "Status", value: "invalid"},
             %{label: "Reported Next State", value: "In Progress"},
             %{label: "Errors", value: "summary must be a non-empty string, got: nil"},
             %{label: "Excerpt", value: "{\"schema\": \"rondo.final_report/v0\", \"next_state\": \"In Progress\"}"},
             %{label: "Continuation Count", value: "1"}
           ]

    assert summary.pretty =~ "continuation_count"
    assert summary.copy_text =~ "reported_next_state"
  end

  test "prefers nested final report summaries when wrapped by invalid-report diagnostics" do
    summary =
      ResultSummary.describe(%{
        reason: "final_report_invalid",
        classification: "blocked_state_unparsed",
        final_report: %{
          status: "missing",
          reported_next_state: "blocked",
          errors: ["final report missing or not parseable as rondo.final_report/v0 JSON"],
          excerpt: "Blocked: still waiting on external auth. next_state: blocked",
          continuation_count: 0,
          fingerprint: "blocked: still waiting on external auth. next_state: blocked"
        },
        question: "The last assistant message reported a blocked state, but it was not valid rondo.final_report/v0 JSON."
      })

    assert summary.kind == :json
    assert summary.preview == "JSON object · missing"

    assert summary.fields == [
             %{label: "Status", value: "missing"},
             %{label: "Reported Next State", value: "blocked"},
             %{label: "Errors", value: "final report missing or not parseable as rondo.final_report/v0 JSON"},
             %{label: "Excerpt", value: "Blocked: still waiting on external auth. next_state: blocked"},
             %{label: "Continuation Count", value: "0"}
           ]

    assert summary.pretty =~ "reported_next_state"
    assert summary.copy_text =~ "\"reason\":\"final_report_invalid\""

    string_key_summary =
      ResultSummary.describe(%{
        "reason" => "final_report_invalid",
        "final_report" => %{
          "status" => "missing",
          "reported_next_state" => "blocked",
          "errors" => ["missing"],
          "excerpt" => "no final report",
          "continuation_count" => 0
        }
      })

    assert string_key_summary.kind == :json
    assert string_key_summary.preview == "JSON object · missing"
  end

  test "unwraps final report diagnostics from json text candidates" do
    summary =
      ResultSummary.describe(
        Jason.encode!(%{
          reason: "final_report_invalid",
          final_report: %{
            status: "invalid",
            reported_next_state: "In Progress",
            errors: ["summary must be a non-empty string, got: nil"],
            excerpt: "{\"schema\": \"rondo.final_report/v0\", \"next_state\": \"In Progress\"}",
            continuation_count: 1
          }
        })
      )

    assert summary.kind == :json
    assert summary.preview == "JSON object · invalid"

    assert summary.fields == [
             %{label: "Status", value: "invalid"},
             %{label: "Reported Next State", value: "In Progress"},
             %{label: "Errors", value: "summary must be a non-empty string, got: nil"},
             %{label: "Excerpt", value: "{\"schema\": \"rondo.final_report/v0\", \"next_state\": \"In Progress\"}"},
             %{label: "Continuation Count", value: "1"}
           ]

    assert summary.copy_text =~ "\"reason\":\"final_report_invalid\""
  end

  test "covers final report optional fields and collection edge cases" do
    summary =
      ResultSummary.describe(%{
        schema: "rondo.final_report/v0",
        summary: "Only summary",
        changed_files: [],
        gates_run: [],
        failures: ["blocked"],
        risks: [],
        links: [
          %{"title" => "PR", "url" => "https://example.org"},
          %{"name" => "Issue"},
          %{"url" => "https://example.org"}
        ],
        next_state: "ready_for_review"
      })

    assert summary.kind == :final_report
    assert summary.preview == "ready_for_review · Only summary"

    assert summary.fields == [
             %{label: "Status", value: "ready_for_review"},
             %{label: "Blocker", value: "blocked"},
             %{label: "PR / issue links", value: "PR (https://example.org), Issue, https://example.org"},
             %{label: "Next action", value: "ready_for_review"}
           ]

    summary =
      ResultSummary.describe(%{
        schema: "rondo.final_report/v0",
        summary: "Empty collections",
        changed_files: [""],
        gates_run: [],
        failures: [],
        risks: [],
        next_state: "done"
      })

    assert summary.preview == "done · Empty collections"

    assert summary.fields == [
             %{label: "Status", value: "done"},
             %{label: "Next action", value: "done"}
           ]

    summary =
      ResultSummary.describe(%{
        schema: "rondo.final_report/v0",
        summary: "Gatey",
        changed_files: ["lib/a.ex"],
        gates_run: [%{"name" => "lint"}, %{"status" => "pass"}, %{}],
        failures: [],
        risks: [],
        next_state: "done"
      })

    assert summary.fields |> Enum.find(&(&1.label == "Tests / gates")) ==
             %{label: "Tests / gates", value: "lint, pass, {}"}

    summary =
      ResultSummary.describe(%{
        schema: "rondo.final_report/v0",
        summary: "Gate raw",
        changed_files: ["lib/a.ex"],
        gates_run: [%{"name" => "raw"}],
        failures: [],
        risks: [],
        next_state: "done"
      })

    assert summary.fields |> Enum.find(&(&1.label == "Tests / gates")) ==
             %{label: "Tests / gates", value: "raw"}

    summary =
      ResultSummary.describe(%{
        schema: "rondo.final_report/v0",
        summary: "Link edge",
        changed_files: ["lib/a.ex"],
        gates_run: [%{"name" => "lint"}],
        links: [%{}, %{"title" => []}, %{"title" => %{}}],
        failures: [],
        risks: [],
        next_state: "done"
      })

    assert summary.fields |> Enum.find(&(&1.label == "PR / issue links")) ==
             %{label: "PR / issue links", value: "{}, {\"title\":[]}, {}"}

    summary =
      ResultSummary.describe(%{
        schema: "rondo.final_report/v0",
        summary: "Link raw",
        changed_files: ["lib/a.ex"],
        gates_run: [%{"name" => "lint"}],
        links: ["raw"],
        failures: [],
        risks: [],
        next_state: "done"
      })

    assert summary.fields |> Enum.find(&(&1.label == "PR / issue links")) ==
             %{label: "PR / issue links", value: "raw"}

    summary =
      ResultSummary.describe(%{
        schema: "rondo.final_report/v0",
        summary: "Blank links",
        changed_files: ["lib/a.ex"],
        gates_run: [%{"name" => "lint"}],
        links: [""],
        failures: [],
        risks: [],
        next_state: "done"
      })

    refute Enum.any?(summary.fields, &(&1.label == "PR / issue links"))

    summary =
      ResultSummary.describe(%{
        schema: "rondo.final_report/v0",
        summary: "Link scalar",
        changed_files: ["lib/a.ex"],
        gates_run: [%{"name" => "lint"}],
        links: "https://example.org",
        failures: [],
        risks: [],
        next_state: "done"
      })

    assert summary.fields |> Enum.find(&(&1.label == "PR / issue links")) ==
             %{label: "PR / issue links", value: "https://example.org"}
  end

  test "covers final report preview and schema fallback branches" do
    summary =
      ResultSummary.describe(%{
        schema: "not-final",
        foo: "bar"
      })

    assert summary.kind == :json
    assert summary.preview == "JSON object · bar"

    assert ResultSummary.preview_report(%{"summary" => "Summary only"}) == "Summary only"
    assert ResultSummary.preview_report(%{"status" => "queued"}) == "queued"
  end
end
