defmodule Rondo.RunDecisionTest do
  use Rondo.TestSupport

  alias Rondo.Linear.Issue
  alias Rondo.RunDecision

  @timestamp ~U[2026-06-29 12:34:56Z]

  test "checkpoint_payload and synthetic_update preserve explicit run decision metadata" do
    struct_issue = %Issue{
      id: "issue-1",
      identifier: "MT-100",
      title: "Structured issue",
      state: "In Progress",
      url: "https://example.org/issues/MT-100"
    }

    map_issue = %{
      id: "issue-2",
      identifier: "MT-200",
      title: "Map issue",
      state: "Todo",
      url: "https://example.org/issues/MT-200"
    }

    payload =
      RunDecision.checkpoint_payload(
        :continue,
        "final_report_active_or_incomplete",
        "continue because final report says active/incomplete",
        issue: struct_issue,
        input_signals: %{"final_report_status" => "valid"},
        evidence: %{"final_report" => %{"path" => "artifacts/final-report.json"}},
        turn_number: 2,
        retry_attempt: 1,
        run_id: "run-1",
        run_dir: "/tmp/run-1",
        session_id: "session-1",
        run_ref: %{provider_ref: "thread-1"},
        timestamp: @timestamp
      )

    assert payload == %{
             "decision_kind" => "continue",
             "reason_code" => "final_report_active_or_incomplete",
             "summary" => "continue because final report says active/incomplete",
             "input_signals" => %{"final_report_status" => "valid"},
             "evidence" => %{"final_report" => %{"path" => "artifacts/final-report.json"}},
             "turn_number" => 2,
             "retry_attempt" => 1,
             "run_id" => "run-1",
             "run_dir" => "/tmp/run-1",
             "session_id" => "session-1",
             "run_ref" => %{provider_ref: "thread-1"},
             "issue" => %{
               "id" => "issue-1",
               "identifier" => "MT-100",
               "title" => "Structured issue",
               "state" => "In Progress",
               "url" => "https://example.org/issues/MT-100"
             },
             "timestamp" => "2026-06-29T12:34:56Z"
           }

    map_payload =
      RunDecision.checkpoint_payload(
        :stop,
        "tracker_state_terminal",
        "stop because tracker-state no longer authorizes continuation",
        issue: map_issue,
        timestamp: "2026-06-29T12:35:56Z"
      )

    assert map_payload["issue"] == %{
             "id" => "issue-2",
             "identifier" => "MT-200",
             "title" => "Map issue",
             "state" => "Todo",
             "url" => "https://example.org/issues/MT-200"
           }

    assert map_payload["timestamp"] == "2026-06-29T12:35:56Z"

    fallback_payload =
      RunDecision.checkpoint_payload(
        :pause,
        "tracker_less_no_continuation_authority",
        "stop because tracker-less run has no continuation authority",
        issue: :trackerless
      )

    assert fallback_payload["issue"] == %{}
    assert fallback_payload["timestamp"] =~ "T"

    update =
      RunDecision.synthetic_update(
        :retry,
        "gate_failed",
        "retry because worker/gate failed",
        issue: struct_issue,
        input_signals: %{"failure_reason" => "{:exit, :gate_failed}"},
        evidence: %{"latest_gate" => %{"status" => "fail"}},
        turn_number: 3,
        retry_attempt: 2,
        run_id: "run-2",
        run_dir: "/tmp/run-2",
        session_id: "session-2",
        run_ref: %{provider_ref: "thread-2"},
        timestamp: @timestamp
      )

    assert update.event == :run_decision
    assert update.method == "run_decision"
    assert update.decision_kind == "retry"
    assert update.reason_code == "gate_failed"
    assert update.payload == "retry because worker/gate failed"
    assert update.message == "retry because worker/gate failed"

    assert update.raw == %{
             "decision_kind" => "retry",
             "reason_code" => "gate_failed",
             "summary" => "retry because worker/gate failed",
             "input_signals" => %{"failure_reason" => "{:exit, :gate_failed}"},
             "evidence" => %{"latest_gate" => %{"status" => "fail"}},
             "turn_number" => 3,
             "retry_attempt" => 2,
             "run_id" => "run-2",
             "run_dir" => "/tmp/run-2",
             "session_id" => "session-2",
             "run_ref" => %{provider_ref: "thread-2"},
             "issue" => %{
               "id" => "issue-1",
               "identifier" => "MT-100",
               "title" => "Structured issue",
               "state" => "In Progress",
               "url" => "https://example.org/issues/MT-100"
             },
             "timestamp" => "2026-06-29T12:34:56Z"
           }
  end

  test "checkpoint_payload and synthetic_update support default arguments and non-map issues" do
    payload =
      RunDecision.checkpoint_payload(
        :stop,
        "tracker_less_no_continuation_authority",
        "stop because tracker-less run has no continuation authority"
      )

    assert payload["issue"] == %{}
    assert payload["input_signals"] == %{}
    assert is_binary(payload["timestamp"])

    update =
      RunDecision.synthetic_update(
        :terminate,
        "orchestrator_shutdown",
        "terminate because orchestrator shutdown or operator abort"
      )

    assert update.decision_kind == "terminate"
    assert update.raw["issue"] == %{}
    assert is_binary(update.timestamp)

    map_payload =
      RunDecision.checkpoint_payload(
        :fail,
        "final_report_missing",
        "fail because final report missing or invalid when required",
        issue: %{id: "issue-3", identifier: "MT-300"},
        timestamp: "2026-06-29T12:36:56Z"
      )

    assert map_payload["issue"] == %{
             "id" => "issue-3",
             "identifier" => "MT-300"
           }

    assert map_payload["timestamp"] == "2026-06-29T12:36:56Z"
  end
end
