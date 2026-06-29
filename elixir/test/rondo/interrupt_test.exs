defmodule Rondo.InterruptTest do
  use Rondo.TestSupport

  alias Rondo.Interrupt

  @now ~U[2026-05-28 10:11:12Z]

  test "builds a repeated gate failure interrupt with resume seeds" do
    issue = %Issue{
      id: "issue-22",
      identifier: "GH-22",
      title: "Human interrupts",
      state: "In Progress",
      url: "https://example.org/issues/22"
    }

    gate_summary = %{
      status: :fail,
      results_path: "artifacts/gates/turn-0002/results.json",
      results: [
        %{
          name: "unit",
          status: :fail,
          exit_status: 2,
          stdout_path: "artifacts/gates/turn-0002/0001-unit-stdout.log",
          stderr_path: "artifacts/gates/turn-0002/0001-unit-stderr.log",
          retryable: false,
          environment_failure: false
        }
      ]
    }

    interrupt =
      Interrupt.repeated_gate_failure(%{
        issue: issue,
        gate: gate_summary,
        run_id: "GH-22-20260528T101112Z-deadbeef",
        run_dir: "/tmp/rondo/.rondo_runs/GH-22/GH-22-20260528T101112Z-deadbeef",
        workspace: "/tmp/rondo/GH-22",
        session_id: "session-123",
        run_ref: %{provider_ref: "provider-abc"},
        retry_attempt: 1,
        model_routing_context: %{skill: "review-response", phase: "fix", stage: :turn},
        timestamp: @now
      })

    assert interrupt["reason"] == "repeated_gate_failure"
    assert interrupt["state"] == "paused"
    assert interrupt["created_at"] == "2026-05-28T10:11:12Z"
    assert interrupt["question"] =~ "Configured gates failed repeatedly"
    assert Enum.map(interrupt["options"], & &1["id"]) == ["resume", "abort", "defer"]
    assert interrupt["recommendation"] =~ "Review the gate artifacts"

    assert interrupt["issue"] == %{
             "id" => "issue-22",
             "identifier" => "GH-22",
             "title" => "Human interrupts",
             "state" => "In Progress",
             "url" => "https://example.org/issues/22"
           }

    assert interrupt["resume"] == %{
             "run_id" => "GH-22-20260528T101112Z-deadbeef",
             "run_dir" => "/tmp/rondo/.rondo_runs/GH-22/GH-22-20260528T101112Z-deadbeef",
             "workspace" => "/tmp/rondo/GH-22",
             "session_id" => "session-123",
             "run_ref" => %{"provider_ref" => "provider-abc"},
             "retry_attempt" => 1,
             "model_routing_context" => %{"skill" => "review-response", "phase" => "fix", "stage" => "turn"}
           }

    assert interrupt["gate"]["status"] == "fail"
    assert interrupt["gate"]["results_path"] == "artifacts/gates/turn-0002/results.json"
    assert [%{"name" => "unit", "status" => "fail", "environment_failure" => false}] = interrupt["gate"]["results"]
  end

  test "builds an action policy guidance interrupt for blocked side effects" do
    interrupt =
      Interrupt.action_policy_guidance_required(%{
        timestamp: @now,
        guidance_severity: "warning",
        blocked_side_effect: %{
          action: "tracker.issue.transition",
          label: "Tracker update",
          operation: "Change issue GH-58 from Todo to In Progress",
          classes: ["tracker-write"],
          required: true,
          resume_safe: true,
          skip_behavior: "block"
        },
        policy: %{
          "decision" => "ask",
          "reason" => "classes=tracker-write",
          "log_level" => "warning",
          "requires_human" => true,
          "matched_rules" => [%{"class" => "tracker-write", "decision" => "ask"}]
        },
        suggested_responses: [
          %{
            id: "approve_once",
            label: "Approve once",
            guidance: "approve_once",
            deterministic: true,
            quick: true
          }
        ],
        upcoming_transitions: %{
          approve_once: "Rondo will execute the tracker transition once, record the approval, and continue."
        },
        resume: %{run_id: "run-1", side_effect_id: "tracker-transition:GH-58"}
      })

    assert interrupt["reason"] == "action_policy_guidance_required"
    assert interrupt["state"] == "paused"
    assert interrupt["guidance_severity"] == "warning"
    assert interrupt["created_at"] == "2026-05-28T10:11:12Z"
    assert interrupt["question"] =~ "operator guidance"

    assert interrupt["blocked_side_effect"] == %{
             "action" => "tracker.issue.transition",
             "label" => "Tracker update",
             "operation" => "Change issue GH-58 from Todo to In Progress",
             "classes" => ["tracker-write"],
             "required" => true,
             "resume_safe" => true,
             "skip_behavior" => "block"
           }

    assert interrupt["policy"] == %{
             "decision" => "ask",
             "reason" => "classes=tracker-write",
             "log_level" => "warning",
             "requires_human" => true,
             "matched_rules" => [%{"class" => "tracker-write", "decision" => "ask"}]
           }

    assert [approve_once] = interrupt["suggested_responses"]
    assert approve_once["id"] == "approve_once"
    assert approve_once["guidance"] == "approve_once"
    assert approve_once["quick"] == true
    assert approve_once["deterministic"] == true

    assert interrupt["upcoming_transitions"] == %{
             "approve_once" => "Rondo will execute the tracker transition once, record the approval, and continue."
           }

    assert interrupt["resume"] == %{"run_id" => "run-1", "side_effect_id" => "tracker-transition:GH-58"}
  end

  test "builds an escalation paused interrupt with default reason and normalized resume seeds" do
    interrupt =
      Interrupt.escalation_paused(%{
        timestamp: @now,
        issue: %{
          id: "issue-99",
          identifier: "GH-99",
          title: "Paused escalation",
          state: "In Progress",
          url: "https://example.org/issues/99"
        },
        attempt_chain: [
          %{
            run_id: "run-1",
            tier: "light",
            reason: :initial,
            status: :failed,
            token_spend: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
          }
        ],
        run_id: "run-2",
        run_dir: "/tmp/rondo/.rondo_runs/GH-99/run-2",
        workspace: "/tmp/rondo/GH-99",
        session_id: "session-456",
        run_ref: %{provider_ref: "provider-abc"},
        retry_attempt: 2
      })

    assert interrupt["reason"] == "escalation_paused"
    assert interrupt["classification"] == "no_recovery_path"
    assert interrupt["question"] =~ "Escalation policy exhausted (no_recovery_path)"

    assert interrupt["issue"] == %{
             "id" => "issue-99",
             "identifier" => "GH-99",
             "title" => "Paused escalation",
             "state" => "In Progress",
             "url" => "https://example.org/issues/99"
           }

    assert [attempt] = interrupt["attempt_chain"]
    assert attempt["run_id"] == "run-1"
    assert attempt["reason"] == "initial"
    assert attempt["status"] == "failed"
    assert attempt["token_spend"] == %{"input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3}

    assert interrupt["resume"] == %{
             "run_id" => "run-2",
             "run_dir" => "/tmp/rondo/.rondo_runs/GH-99/run-2",
             "workspace" => "/tmp/rondo/GH-99",
             "session_id" => "session-456",
             "run_ref" => %{"provider_ref" => "provider-abc"},
             "retry_attempt" => 2
           }
  end

  test "guidance interrupts tolerate missing policy maps" do
    interrupt =
      Interrupt.action_policy_guidance_required(%{
        policy: "missing",
        blocked_side_effect: %{action: "workspace.hook.after_run"},
        suggested_responses: [],
        upcoming_transitions: %{}
      })

    assert interrupt["policy"] == %{}
  end

  test "builds terminal and generic final report interrupts" do
    terminal_interrupt =
      Interrupt.final_report_invalid(%{
        classification: "terminal_state_unparsed",
        final_report_status: "missing",
        continuation_count: 2,
        reported_next_state: "done",
        fingerprint: "abc123",
        excerpt: "blocked"
      })

    assert terminal_interrupt["classification"] == "terminal_state_unparsed"
    assert terminal_interrupt["question"] =~ "terminal state"

    generic_interrupt = Interrupt.final_report_invalid(%{classification: "something_else"})

    assert generic_interrupt["question"] == "The last assistant message was not valid rondo.final_report/v0 JSON."
  end

  test "normalizes map inputs and optional values" do
    interrupt =
      Interrupt.repeated_gate_failure(%{
        "issue" => %{"id" => "issue-map", "identifier" => "MAP-1", "title" => "Map issue", "state" => "Todo"},
        "gate" => %{"status" => :timeout, "checked_at" => @now},
        "run_ref" => %{{:tuple, :key} => {:tuple, 1}},
        "timestamp" => "2026-05-28T10:11:12Z"
      })

    assert interrupt["created_at"] == "2026-05-28T10:11:12Z"
    assert interrupt["issue"] == %{"id" => "issue-map", "identifier" => "MAP-1", "title" => "Map issue", "state" => "Todo"}
    assert interrupt["gate"]["status"] == "timeout"
    assert interrupt["gate"]["checked_at"] == "2026-05-28T10:11:12Z"
    assert interrupt["resume"]["run_ref"] == %{"{:tuple, :key}" => "{:tuple, 1}"}

    no_issue_interrupt = Interrupt.repeated_gate_failure(%{"issue" => "missing"})
    assert no_issue_interrupt["issue"] == %{}
  end
end
