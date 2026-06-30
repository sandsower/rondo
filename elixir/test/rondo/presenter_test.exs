defmodule Rondo.PresenterTest do
  use Rondo.TestSupport

  defmodule SnapshotServer do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  test "state and issue API payloads expose latest gate status" do
    latest_gate = %{
      status: :fail,
      results_path: "artifacts/gates/results.json",
      failed: [%{name: "unit", status: :fail, exit_status: 2}]
    }

    snapshot = %{
      running: [
        %{
          issue_id: "issue-gate",
          identifier: "MT-GATE",
          state: "In Progress",
          session_id: "session-gate",
          turn_count: 1,
          last_claude_event: :gates_completed,
          last_claude_message: %{event: :gates_completed},
          last_claude_timestamp: ~U[2026-05-27 12:00:00Z],
          started_at: ~U[2026-05-27 11:59:00Z],
          latest_gate: latest_gate,
          claude_input_tokens: 1,
          claude_output_tokens: 2,
          claude_total_tokens: 3,
          event_log: []
        }
      ],
      retrying: [],
      archived: [
        %{
          issue_id: "issue-archived-gate",
          identifier: "MT-ARCHIVE-GATE",
          session_id: "session-archive",
          state: "In Progress",
          started_at: ~U[2026-05-27 11:00:00Z],
          finished_at: ~U[2026-05-27 11:10:00Z],
          exit_reason: "exited: gate failed",
          turn_count: 1,
          latest_gate: latest_gate,
          tokens: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
        }
      ],
      claude_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 60}
    }

    server_name = Module.concat(__MODULE__, :GateSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)
    assert payload.running |> hd() |> Map.fetch!(:latest_gate) |> Map.fetch!(:status) == :fail
    assert payload.archived |> hd() |> Map.fetch!(:runs) |> hd() |> Map.fetch!(:latest_gate) |> Map.fetch!(:status) == :fail

    assert {:ok, issue_payload} = RondoWeb.Presenter.issue_payload("MT-GATE", server_name, 1_000)
    assert issue_payload.running.latest_gate.status == :fail
  end

  test "archived payload normalizes finished outcomes for rows, charts, and detail drawers" do
    snapshot = %{
      running: [],
      retrying: [],
      archived: [
        archived_run("MT-SUCCESS", "completed", "In Progress", ~U[2026-05-27 11:10:00Z], 10),
        archived_run("MT-REVIEW", "terminated", "Human Review", ~U[2026-05-27 11:20:00Z], 20),
        archived_run("MT-DONE", "terminated", "Done", ~U[2026-05-27 11:30:00Z], 30),
        archived_run("MT-FAILED", "failed", "In Progress", ~U[2026-05-27 11:40:00Z], 40),
        archived_run("MT-PAUSED", "paused", "Blocked", ~U[2026-05-27 11:50:00Z], 50),
        archived_run("MT-TERM", "terminated", "In Progress", ~U[2026-05-27 12:00:00Z], 60)
      ],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    server_name = Module.concat(__MODULE__, :OutcomeSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)
    outcomes = payload.archived |> Enum.map(&{&1.issue_identifier, &1.latest_outcome}) |> Map.new()

    assert outcomes["MT-SUCCESS"] == %{
             kind: "success",
             label: "success",
             class: "state-badge state-badge-active",
             detail: nil
           }

    assert outcomes["MT-REVIEW"] == %{
             kind: "review_handoff",
             label: "review handoff",
             class: "state-badge state-badge-handoff",
             detail: "issue → Human Review"
           }

    assert outcomes["MT-DONE"] == %{
             kind: "merged_done",
             label: "merged/done",
             class: "state-badge state-badge-active",
             detail: "issue → Done"
           }

    assert outcomes["MT-FAILED"].kind == "failed"
    assert outcomes["MT-PAUSED"].kind == "blocked_paused"
    assert outcomes["MT-TERM"].kind == "terminated"

    assert RondoWeb.Presenter.run_outcomes(payload.archived) == %{
             labels: ["MT-TERM", "MT-PAUSED", "MT-FAILED", "MT-DONE", "MT-REVIEW", "MT-SUCCESS"],
             values: [60, 50, 40, 30, 20, 10],
             colors: ["terminated", "blocked_paused", "failed", "merged_done", "review_handoff", "success"]
           }
  end

  test "state and issue API payloads expose paused interrupts" do
    snapshot = %{
      running: [],
      retrying: [],
      paused: [
        %{
          issue_id: "issue-paused",
          identifier: "MT-PAUSED",
          state: "In Progress",
          session_id: "session-paused",
          run_id: "MT-PAUSED-20260528T100000Z-deadbeef",
          run_dir: "/tmp/rondo/.rondo_runs/MT-PAUSED/run",
          workspace: "/tmp/rondo/MT-PAUSED",
          paused_at: "2026-05-28T10:00:00Z",
          retry_attempt: 1,
          tracker_visibility: "unknown",
          latest_gate: %{status: :fail, results_path: "artifacts/gates/results.json", failed: [%{name: "unit", status: :fail, exit_status: 2}]},
          interrupt: %{
            "reason" => "repeated_gate_failure",
            "question" => "Configured gates failed repeatedly. How should Rondo proceed?",
            "options" => [%{"id" => "resume"}],
            "resume" => %{"run_id" => "MT-PAUSED-20260528T100000Z-deadbeef"}
          }
        }
      ],
      archived: [],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    server_name = Module.concat(__MODULE__, :PausedSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)
    assert payload.counts.paused == 1
    assert payload.counts.needs_guidance == 1
    assert [guidance] = payload.needs_guidance
    assert guidance.issue_identifier == "MT-PAUSED"
    assert guidance.interrupt.reason == "repeated_gate_failure"
    assert guidance.tokens.total_tokens == 0
    assert [paused] = payload.paused
    assert paused.issue_identifier == "MT-PAUSED"
    assert paused.interrupt.reason == "repeated_gate_failure"
    assert paused.latest_gate.status == :fail

    assert {:ok, issue_payload} = RondoWeb.Presenter.issue_payload("MT-PAUSED", server_name, 1_000)
    assert issue_payload.status == "paused"
    assert issue_payload.paused.interrupt.reason == "repeated_gate_failure"
  end

  test "state API exposes tracker-state mismatches for reloaded paused claims" do
    snapshot = %{
      running: [],
      retrying: [],
      paused: [
        %{
          issue_id: "issue-paused-mismatch",
          identifier: "MT-PAUSED-MISMATCH",
          state: "In Progress",
          paused_state: "In Progress",
          tracker_state: "Todo",
          session_id: "session-paused-mismatch",
          run_id: "run-paused-mismatch",
          run_dir: "/tmp/rondo/.rondo_runs/MT-PAUSED-MISMATCH/run",
          workspace: "/tmp/rondo/MT-PAUSED-MISMATCH",
          paused_at: "2026-05-28T10:00:00Z",
          retry_attempt: 1,
          blocks_dispatch: true,
          blocked_dispatch_reason: "paused_claim",
          tracker_visibility: "known",
          interrupt: %{
            "reason" => "repeated_gate_failure",
            "suggested_responses" => [%{"id" => "resume"}],
            "resume" => %{"run_id" => "run-paused-mismatch"}
          },
          event_log: []
        }
      ],
      archived: [],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    server_name = Module.concat(__MODULE__, :PausedMismatchSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)
    assert payload.counts.paused == 1
    assert payload.counts.needs_guidance == 1

    [paused] = payload.paused
    assert paused.state == "In Progress"
    assert paused.paused_state == "In Progress"
    assert paused.tracker_state == "Todo"
    assert paused.tracker_state_mismatch == true

    [guidance] = payload.needs_guidance
    assert guidance.issue_identifier == "MT-PAUSED-MISMATCH"
    assert guidance.tracker_state == "Todo"
    assert guidance.paused_state == "In Progress"
    assert guidance.tracker_state_mismatch == true

    assert {:ok, issue_payload} = RondoWeb.Presenter.issue_payload("MT-PAUSED-MISMATCH", server_name, 1_000)
    assert issue_payload.status == "paused"
    assert issue_payload.paused.state == "In Progress"
    assert issue_payload.paused.paused_state == "In Progress"
    assert issue_payload.paused.tracker_state == "Todo"
    assert issue_payload.paused.tracker_state_mismatch == true
  end

  test "state API exposes action-policy guidance as first-class needs guidance entries" do
    interrupt = %{
      "reason" => "action_policy_guidance_required",
      "guidance_severity" => "warning",
      "question" => "Rondo needs operator guidance before continuing.",
      "blocked_side_effect" => %{"action" => "tracker.issue.transition", "label" => "Tracker update"},
      "policy" => %{"decision" => "ask", "reason" => "tracker write"},
      "suggested_responses" => [%{"id" => "approve_once", "quick" => true}],
      "upcoming_transitions" => %{"approve_once" => "Rondo will execute the tracker transition once."},
      "resume" => %{"side_effect_id" => "tracker-transition:issue-58"}
    }

    snapshot = %{
      running: [],
      retrying: [],
      paused: [
        %{
          issue_id: "issue-guidance",
          identifier: "MT-GUIDANCE",
          state: "Todo",
          session_id: "session-guidance",
          run_id: "run-guidance",
          run_dir: "/tmp/rondo/.rondo_runs/MT-GUIDANCE/run",
          workspace: "/tmp/rondo/MT-GUIDANCE",
          paused_at: "2026-05-28T10:00:00Z",
          retry_attempt: 1,
          interrupt: interrupt,
          event_log: [
            %{at: ~U[2026-05-28 09:59:00Z], event: :assistant, message: "Turn 1 complete"}
          ]
        }
      ],
      archived: [],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    server_name = Module.concat(__MODULE__, :NeedsGuidanceSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)
    assert payload.counts.needs_guidance == 1
    assert [guidance] = payload.needs_guidance
    assert guidance.issue_identifier == "MT-GUIDANCE"
    assert guidance.guidance_severity == "warning"
    assert guidance.blocked_side_effect.label == "Tracker update"
    assert [%{id: "approve_once", quick: true}] = guidance.suggested_responses
    assert [%{message: "Turn 1 complete"}] = guidance.event_log

    assert {:ok, issue_payload} = RondoWeb.Presenter.issue_payload("MT-GUIDANCE", server_name, 1_000)
    assert issue_payload.paused.interrupt.guidance_severity == "warning"
    assert issue_payload.paused.interrupt.blocked_side_effect.label == "Tracker update"
  end

  test "state API tolerates disk-reconstructed paused entries with missing or string keys" do
    snapshot = %{
      running: [],
      retrying: [],
      paused: [
        %{
          "issue_id" => "issue-paused",
          "identifier" => "MT-PAUSED",
          "state" => "In Progress",
          "session_id" => "session-paused",
          interrupt: %{"reason" => "repeated_gate_failure"}
        },
        %{
          issue_id: "issue-nil-interrupt",
          identifier: "MT-NIL-INTERRUPT",
          state: "In Progress",
          interrupt: nil
        },
        %{
          run_id: "missing-required-fields",
          interrupt: %{"reason" => "repeated_gate_failure"}
        }
      ],
      archived: [],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    server_name = Module.concat(__MODULE__, :PausedPartialSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)
    assert [string_keyed, nil_interrupt, missing_fields] = payload.paused
    assert string_keyed.issue_id == "issue-paused"
    assert string_keyed.issue_identifier == "MT-PAUSED"
    assert string_keyed.state == "In Progress"
    assert string_keyed.session_id == "session-paused"
    assert nil_interrupt.issue_id == "issue-nil-interrupt"
    assert nil_interrupt.issue_identifier == "MT-NIL-INTERRUPT"
    assert payload.counts.needs_guidance == 2
    assert missing_fields.issue_id == nil
    assert missing_fields.issue_identifier == nil
    assert missing_fields.state == nil
    assert missing_fields.session_id == nil
  end

  test "gate payload tolerates malformed failed values" do
    snapshot = %{
      running: [
        %{
          issue_id: "issue-gate",
          identifier: "MT-GATE",
          state: "In Progress",
          session_id: nil,
          turn_count: 1,
          last_claude_event: :gates_completed,
          last_claude_message: %{event: :gates_completed},
          last_claude_timestamp: nil,
          started_at: nil,
          latest_gate: %{status: :fail, results_path: "artifacts/gates/results.json", failed: nil},
          claude_input_tokens: 0,
          claude_output_tokens: 0,
          claude_total_tokens: 0,
          event_log: []
        },
        %{
          issue_id: "issue-gate-2",
          identifier: "MT-GATE-2",
          state: "In Progress",
          session_id: nil,
          turn_count: 1,
          last_claude_event: :gates_completed,
          last_claude_message: %{event: :gates_completed},
          last_claude_timestamp: nil,
          started_at: nil,
          latest_gate: %{"status" => "fail", "results_path" => "artifacts/gates/results.json", "failed" => "unit"},
          claude_input_tokens: 0,
          claude_output_tokens: 0,
          claude_total_tokens: 0,
          event_log: []
        }
      ],
      retrying: [],
      archived: [],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    server_name = Module.concat(__MODULE__, :MalformedGateSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)

    assert Enum.map(payload.running, & &1.latest_gate.failed) == [[], []]
  end

  test "run comparison labels omit timestamp suffix when started_at is invalid" do
    runs = [
      %{started_at: "invalid", tokens: %{input_tokens: 1, output_tokens: 2}},
      %{tokens: %{input_tokens: 3, output_tokens: 4}},
      %{started_at: "2026-05-10T11:14:57Z", tokens: %{input_tokens: 5, output_tokens: 6}}
    ]

    assert RondoWeb.Presenter.run_token_comparison(runs).labels == ["Run 1", "Run 2", "Run 3 (11:14)"]
    assert RondoWeb.Presenter.run_duration_comparison(runs).labels == ["Run 1", "Run 2", "Run 3 (11:14)"]
  end

  defp archived_run(identifier, exit_reason, state, finished_at, total_tokens) do
    %{
      issue_id: "issue-#{identifier}",
      identifier: identifier,
      session_id: "session-#{identifier}",
      state: state,
      started_at: DateTime.add(finished_at, -600, :second),
      finished_at: finished_at,
      exit_reason: exit_reason,
      turn_count: 1,
      tokens: %{input_tokens: total_tokens, output_tokens: total_tokens, total_tokens: total_tokens},
      latest_gate: %{status: :pass, failed: []}
    }
  end
end
