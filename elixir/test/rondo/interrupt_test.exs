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
             "retry_attempt" => 1
           }

    assert interrupt["gate"]["status"] == "fail"
    assert interrupt["gate"]["results_path"] == "artifacts/gates/turn-0002/results.json"
    assert [%{"name" => "unit", "status" => "fail", "environment_failure" => false}] = interrupt["gate"]["results"]
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
