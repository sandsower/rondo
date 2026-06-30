defmodule Rondo.PresenterTest do
  use Rondo.TestSupport

  alias Rondo.RunLedger

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

  test "state and issue payloads surface readable last results" do
    report = %{
      "schema" => "rondo.final_report/v0",
      "summary" => "Did the work",
      "changed_files" => ["lib/rondo_web/result_summary.ex"],
      "gates_run" => [%{"name" => "format", "status" => "pass"}],
      "failures" => [],
      "risks" => [],
      "next_state" => "ready_for_review"
    }

    snapshot = %{
      running: [
        %{
          issue_id: "issue-result",
          identifier: "MT-RESULT",
          state: "In Progress",
          session_id: "session-result",
          turn_count: 2,
          last_claude_event: :result,
          last_claude_message: %{event: :result, message: Jason.encode!(report)},
          last_claude_timestamp: ~U[2026-05-27 12:00:00Z],
          started_at: ~U[2026-05-27 11:59:00Z],
          latest_gate: nil,
          claude_input_tokens: 4,
          claude_output_tokens: 5,
          claude_total_tokens: 9,
          event_log: []
        }
      ],
      retrying: [],
      archived: [
        %{
          issue_id: "issue-archived-result",
          identifier: "MT-RESULT-ARCHIVE",
          session_id: "session-archive-result",
          state: "Done",
          started_at: ~U[2026-05-27 10:00:00Z],
          finished_at: ~U[2026-05-27 10:10:00Z],
          exit_reason: "completed",
          turn_count: 2,
          final_report: report,
          tokens: %{input_tokens: 10, output_tokens: 20, total_tokens: 30},
          event_log: []
        }
      ],
      claude_totals: %{input_tokens: 4, output_tokens: 5, total_tokens: 9, seconds_running: 120}
    }

    server_name = Module.concat(__MODULE__, :ResultSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)
    [running] = payload.running
    assert running.last_message == "ready_for_review · Did the work"
    assert running.last_result_payload == Jason.encode!(report)

    [archived_group] = payload.archived
    assert archived_group.latest_result_payload == report

    [archived_run] = archived_group.runs
    assert archived_run.final_report == report
    assert archived_run.last_result_payload == report

    assert {:ok, issue_payload} = RondoWeb.Presenter.issue_payload("MT-RESULT", server_name, 1_000)
    assert issue_payload.running.last_message == "ready_for_review · Did the work"
    assert issue_payload.running.last_result_payload == Jason.encode!(report)
  end

  test "archived payload normalizes finished outcomes for rows, charts, and detail drawers" do
    snapshot = %{
      running: [],
      retrying: [],
      archived: [
        archived_run("MT-SUCCESS", "completed", "In Progress", ~U[2026-05-27 11:10:00Z], 10),
        archived_run("MT-REVIEW", "terminated", Rondo.Config.release_loop_review_state(), ~U[2026-05-27 11:20:00Z], 20),
        archived_run("MT-DONE", "terminated", Rondo.Config.release_loop_done_state(), ~U[2026-05-27 11:30:00Z], 30),
        archived_run("MT-FAILED", "failed", "In Progress", ~U[2026-05-27 11:40:00Z], 40),
        archived_run("MT-PAUSED", "paused", "Blocked", ~U[2026-05-27 11:50:00Z], 50),
        archived_run("MT-CANCELED", "terminated", "Canceled", ~U[2026-05-27 11:55:00Z], 55),
        archived_run("MT-TERM", "terminated", "In Progress", ~U[2026-05-27 12:00:00Z], 60)
      ],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    server_name = Module.concat(__MODULE__, :OutcomeSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)
    outcomes = payload.archived |> Enum.map(&{&1.issue_identifier, &1.latest_outcome}) |> Map.new()
    rows = payload.archived_table |> Enum.map(&{&1.issue_identifier, &1}) |> Map.new()

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
             detail: "issue → #{Rondo.Config.release_loop_review_state()}"
           }

    assert outcomes["MT-DONE"] == %{
             kind: "merged_done",
             label: "merged/done",
             class: "state-badge state-badge-active",
             detail: "issue → #{Rondo.Config.release_loop_done_state()}"
           }

    assert outcomes["MT-FAILED"].kind == "failed"
    assert outcomes["MT-PAUSED"].kind == "blocked_paused"
    assert outcomes["MT-CANCELED"].kind == "canceled"
    assert outcomes["MT-TERM"].kind == "terminated"

    assert rows["MT-REVIEW"].status == "review handoff"
    assert rows["MT-REVIEW"].outcome_display == outcomes["MT-REVIEW"]
    assert rows["MT-DONE"].status == "merged/done"

    assert RondoWeb.Presenter.run_outcomes(payload.archived) == %{
             labels: ["MT-TERM", "MT-CANCELED", "MT-PAUSED", "MT-FAILED", "MT-DONE", "MT-REVIEW", "MT-SUCCESS"],
             values: [60, 55, 50, 40, 30, 20, 10],
             colors: ["terminated", "canceled", "blocked_paused", "failed", "merged_done", "review_handoff", "success"]
           }
  end

  test "retry payloads expose release-loop lifecycle metadata" do
    snapshot = %{
      running: [],
      retrying: [
        %{
          issue_id: "issue-release-loop",
          identifier: "MT-RELEASE-LOOP",
          attempt: 3,
          due_in_ms: 9_000,
          error: "release loop waiting for PR checks",
          release_loop: %{
            phase: :wait,
            action: :wait,
            blocked_reason: :checks_pending,
            wait_interval_seconds: 9,
            recovery_kind: :verification_failure,
            closeout_state: "review",
            feedback_count: 2,
            feedback_comment_ids: ["c1", "c2"],
            mergeable: "UNKNOWN",
            merge_state_status: "DIRTY",
            pr: %{
              number: 15,
              url: "https://github.com/sandsower/rondo/pull/15",
              title: "Release loop metadata",
              head_ref_name: "feature/review-loop",
              base_ref_name: "main",
              is_draft: false
            },
            checks: %{state: :pending, conclusion: nil}
          }
        }
      ],
      archived: [],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    server_name = Module.concat(__MODULE__, :ReleaseLoopRetrySnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)
    [retry] = payload.retrying
    assert is_binary(retry.due_at)
    assert retry.release_loop.phase == :wait
    assert retry.release_loop.action == :wait
    assert retry.release_loop.blocked_reason == :checks_pending
    assert retry.release_loop.pr.number == 15
    assert retry.release_loop.pr.url == "https://github.com/sandsower/rondo/pull/15"

    assert {:ok, issue_payload} = RondoWeb.Presenter.issue_payload("MT-RELEASE-LOOP", server_name, 1_000)
    assert is_binary(issue_payload.retry.due_at)
    assert issue_payload.retry.release_loop.phase == :wait
    assert issue_payload.retry.release_loop.action == :wait
    assert issue_payload.retry.release_loop.blocked_reason == :checks_pending
    assert issue_payload.retry.release_loop.recovery_kind == :verification_failure
    assert issue_payload.retry.release_loop.pr.number == 15
  end

  test "state payload exposes tracker, PR, branch, and final report links" do
    workflow_path = Workflow.workflow_file_path()
    original_workflow = File.read!(workflow_path)
    write_workflow_file!(workflow_path, tracker_repo: "sandsower/rondo")
    workspace_root = tmp_dir("presenter-links")

    on_exit(fn ->
      File.write!(workflow_path, original_workflow)
      WorkflowStore.force_reload()
      File.rm_rf(workspace_root)
    end)

    linear_issue = %Issue{
      id: "issue-links-linear",
      identifier: "MT-LINKS-LINEAR",
      title: "Links on live runs",
      description: "Links on live runs",
      state: "In Progress",
      branch_name: "feature/live-links",
      url: "https://linear.app/teotl/issue/RON-93/links-on-live-runs"
    }

    assert {:ok, linear_ledger} =
             RunLedger.create_run(linear_issue,
               workspace_root: workspace_root,
               now: ~U[2026-05-10 15:30:00Z],
               random_suffix: "feedface"
             )

    manifest = Jason.decode!(File.read!(linear_ledger.manifest_path))

    manifest =
      put_in(
        manifest,
        ["agent"],
        Map.merge(manifest["agent"] || %{}, %{
          "pr" => %{
            "number" => 42,
            "url" => "https://github.com/sandsower/rondo/pull/42",
            "title" => "Add dashboard links",
            "head_ref_name" => "feature/live-links",
            "base_ref_name" => "main"
          }
        })
      )
      |> put_in(["final_report"], %{"path" => "artifacts/final-report.json"})

    File.write!(linear_ledger.manifest_path, Jason.encode!(manifest))
    File.write!(Path.join([linear_ledger.run_dir, "artifacts", "final-report.json"]), "{}")

    linear_ledger = %{linear_ledger | manifest: manifest}

    github_issue = %Issue{
      id: "issue-links-github",
      identifier: "GH-321",
      title: "GitHub source link",
      description: "GitHub source link",
      state: "Closed",
      url: "https://github.com/sandsower/rondo/issues/321"
    }

    assert {:ok, github_ledger} =
             RunLedger.create_run(github_issue,
               workspace_root: workspace_root,
               now: ~U[2026-05-10 15:35:00Z],
               random_suffix: "cafebabe"
             )

    snapshot = %{
      running: [
        %{
          issue_id: linear_issue.id,
          identifier: linear_issue.identifier,
          issue: linear_issue,
          state: linear_issue.state,
          session_id: "session-links-linear",
          run_id: linear_ledger.run_id,
          run_dir: linear_ledger.run_dir,
          started_at: ~U[2026-05-10 15:30:00Z],
          last_claude_event: :turn_started,
          last_claude_message: %{event: :turn_started},
          last_claude_timestamp: ~U[2026-05-10 15:30:02Z],
          latest_gate: nil,
          model_routing: nil,
          model_fallback: nil,
          claude_input_tokens: 0,
          claude_output_tokens: 0,
          claude_total_tokens: 0,
          turn_count: 1,
          ledger: linear_ledger,
          event_log: []
        }
      ],
      retrying: [],
      paused: [],
      archived: [
        %{
          issue_id: github_issue.id,
          identifier: github_issue.identifier,
          session_id: "session-links-github",
          state: github_issue.state,
          run_id: github_ledger.run_id,
          run_dir: github_ledger.run_dir,
          started_at: ~U[2026-05-10 15:35:00Z],
          finished_at: ~U[2026-05-10 15:45:00Z],
          exit_reason: "completed",
          turn_count: 2,
          latest_gate: nil,
          tokens: %{input_tokens: 1, output_tokens: 2, total_tokens: 3},
          model_routing: nil,
          adapter: "claude_code"
        }
      ],
      claude_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 60}
    }

    server_name = Module.concat(__MODULE__, :LinkSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)

    [running] = payload.running
    assert Enum.any?(running.links.tracker.available, &(&1.kind == :linear_issue))
    assert Enum.any?(running.links.review.available, &(&1.kind == :pull_request))
    assert Enum.any?(running.links.review.available, &(&1.kind == :branch))
    assert Enum.any?(running.links.review.available, &(&1.kind == :final_report))

    assert {:ok, issue_payload} = RondoWeb.Presenter.issue_payload("MT-LINKS-LINEAR", server_name, 1_000)
    assert Enum.any?(issue_payload.running.links.review.available, &(&1.kind == :pull_request))

    [archived_group] = payload.archived
    assert Enum.any?(archived_group.links.tracker.available, &(&1.kind == :github_issue))
    assert Enum.any?(archived_group.links.review.unavailable, &String.contains?(Map.get(&1, :reason, ""), "no branch"))

    [archived_run] = archived_group.runs
    assert Enum.any?(archived_run.links.tracker.available, &(&1.kind == :github_issue))
    assert Enum.any?(archived_run.links.review.unavailable, &String.contains?(Map.get(&1, :reason, ""), "no branch"))
  end

  test "state payload includes projected run timelines" do
    workspace_root = tmp_dir("presenter-run-timelines")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    issue = %Issue{
      id: "issue-presenter-timeline",
      identifier: "MT-PRESENTER-TL",
      title: "Presenter timeline",
      description: "Presenter timeline",
      state: "In Progress",
      url: "https://example.org/issues/MT-PRESENTER-TL"
    }

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: ~U[2026-05-10 15:30:00Z],
               random_suffix: "feedface"
             )

    assert {:ok, ledger} =
             RunLedger.write_checkpoint(ledger, :dispatch, %{attempt: 1}, timestamp: ~U[2026-05-10 15:30:01Z])

    assert {:ok, _ledger} =
             RunLedger.write_checkpoint(ledger, :turn_started, %{turn_number: 1}, timestamp: ~U[2026-05-10 15:30:02Z])

    snapshot = %{
      running: [
        %{
          issue_id: issue.id,
          identifier: issue.identifier,
          state: "In Progress",
          run_id: ledger.run_id,
          run_dir: ledger.run_dir,
          session_id: "session-presenter-timeline",
          started_at: ~U[2026-05-10 15:30:00Z],
          last_claude_event: :turn_started,
          last_claude_message: %{event: :turn_started},
          last_claude_timestamp: ~U[2026-05-10 15:30:02Z],
          latest_gate: nil,
          model_routing: nil,
          model_fallback: nil,
          claude_input_tokens: 0,
          claude_output_tokens: 0,
          claude_total_tokens: 0,
          turn_count: 1,
          event_log: []
        }
      ],
      retrying: [],
      paused: [],
      archived: [],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    server_name = Module.concat(__MODULE__, :TimelineSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)
    assert [%{identifier: "MT-PRESENTER-TL", timeline: timeline}] = payload.run_timelines
    kinds = Enum.map(timeline, & &1.kind)
    assert "dispatch" in kinds
    assert "turn_started" in kinds
  end

  test "state payload exposes provider, model, cost, and token metadata for logs" do
    snapshot = %{
      running: [
        %{
          issue_id: "issue-log",
          identifier: "MT-LOG",
          state: "In Progress",
          session_id: "session-log",
          started_at: ~U[2026-05-27 11:59:00Z],
          last_claude_timestamp: ~U[2026-05-27 12:00:00Z],
          last_claude_event: :assistant,
          last_claude_message: %{message: "Turn 1 complete"},
          model_routing: %{resolved: %{adapter: "pi", model: "openrouter/deepseek/deepseek-chat"}},
          adapter: "pi",
          claude_input_tokens: 10,
          claude_output_tokens: 5,
          claude_total_tokens: 15,
          event_log: [
            %{
              at: ~U[2026-05-27 11:59:30Z],
              event: :assistant,
              message: "Hello",
              tokens: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, cost: 1.25}
            },
            %{
              at: ~U[2026-05-27 11:59:45Z],
              event: :tool,
              message: "Read file",
              tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, cost: 0.25}
            }
          ]
        }
      ],
      retrying: [],
      paused: [],
      archived: [
        %{
          issue_id: "issue-archived-log",
          identifier: "MT-ARCHIVED-LOG",
          session_id: "session-archived-log",
          state: "Done",
          started_at: ~U[2026-05-27 10:00:00Z],
          finished_at: ~U[2026-05-27 10:04:00Z],
          exit_reason: "completed",
          turn_count: 2,
          latest_gate: nil,
          tokens: %{input_tokens: 2, output_tokens: 4, total_tokens: 6},
          model_routing: %{
            resolved: %{adapter: "claude_code", model: "openrouter/anthropic/claude-3.7-sonnet"}
          },
          adapter: "claude_code",
          event_log: [
            %{
              at: ~U[2026-05-27 10:01:00Z],
              event: :assistant,
              message: "Archived turn",
              tokens: %{input_tokens: 1, output_tokens: 1, total_tokens: 2, cost: 0.5}
            }
          ]
        }
      ],
      claude_totals: %{input_tokens: 10, output_tokens: 5, total_tokens: 15, seconds_running: 60}
    }

    server_name = Module.concat(__MODULE__, :LogSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)
    [running] = payload.running
    [archived_group] = payload.archived

    assert running.provider == "openrouter"
    assert running.model == "openrouter/deepseek/deepseek-chat"
    assert running.cost == 1.5
    assert Enum.any?(running.event_log, &match?(%{tokens: %{total_tokens: 3, cost: 1.25}}, &1))

    assert archived_group.latest_result == "completed"
    assert [archived_run] = archived_group.runs
    assert archived_run.provider == "openrouter"
    assert archived_run.model == "openrouter/anthropic/claude-3.7-sonnet"
    assert archived_run.cost == 0.5
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

  test "format_event_log_public preserves token deltas and model change metadata" do
    log = [
      %{
        at: ~U[2026-06-29 10:05:00Z],
        event: :warning,
        message: "model changed: openrouter/openrouter/moonshotai/kimi-k2.7-code",
        tokens: %{input_tokens: 4, output_tokens: 5, total_tokens: 11, cache_read_tokens: 2}
      },
      %{
        at: ~U[2026-06-29 10:00:00Z],
        event: :assistant,
        message: "Turn 1 complete",
        tokens: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
      }
    ]

    assert [turn, model_change] = RondoWeb.Presenter.format_event_log_public(log)
    assert turn.message == "Turn 1 complete"
    assert turn.tokens == %{input_tokens: 1, output_tokens: 2, total_tokens: 3, cache_read_tokens: 0, cache_write_tokens: 0, cached_tokens: 0, cost: nil}
    assert model_change.model_change == %{provider: "openrouter", model: "openrouter/moonshotai/kimi-k2.7-code"}
    assert model_change.tokens == %{input_tokens: 4, output_tokens: 5, total_tokens: 11, cache_read_tokens: 2, cache_write_tokens: 0, cached_tokens: 2, cost: nil}
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

  test "state payload exposes flat archived run table metadata" do
    snapshot = %{
      running: [],
      retrying: [],
      paused: [],
      archived: [
        %{
          issue_id: "issue-archived-1",
          identifier: "MT-ARCH-1",
          issue_title: "Fix archive visibility",
          issue_url: "https://linear.app/example/MT-ARCH-1",
          project: "rondo-intake",
          repo: "sandsower/rondo",
          session_id: "session-arch-1",
          state: "Done",
          started_at: ~U[2026-06-28 10:00:00Z],
          finished_at: ~U[2026-06-28 10:12:30Z],
          exit_reason: "completed",
          turn_count: 3,
          latest_gate: %{status: :pass},
          model_routing: %{resolved: %{model: "openrouter/anthropic/claude-sonnet-4"}},
          adapter: "pi",
          tokens: %{input_tokens: 100, output_tokens: 25, total_tokens: 125},
          cost: 0.015
        },
        %{
          issue_id: "issue-archived-2",
          identifier: "MT-ARCH-2",
          state: "In Progress",
          started_at: ~U[2026-06-29 11:00:00Z],
          finished_at: ~U[2026-06-29 11:01:00Z],
          exit_reason: "exited: gate failed",
          turn_count: 1,
          latest_gate: %{"status" => "fail"},
          tokens: %{total_tokens: 75},
          cost: 0.0,
          event_log: [%{tokens: %{cost: 0.42}}],
          adapter: "codex"
        }
      ],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    server_name = Module.concat(__MODULE__, :ArchivedTableSnapshotServer)
    {:ok, pid} = GenServer.start_link(SnapshotServer, snapshot, name: server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = RondoWeb.Presenter.state_payload(server_name, 1_000)

    assert [failed, completed] = payload.archived_table
    assert failed.issue_identifier == "MT-ARCH-2"
    assert failed.status == "failed"
    assert failed.last_meaningful_result == "gates fail"
    assert failed.model == "codex"
    assert failed.cost == 0.0
    assert completed.issue_title == "Fix archive visibility"
    assert completed.status == "merged/done"
    assert completed.outcome_display.kind == "merged_done"
    assert completed.cost == 0.015
    assert completed.provider == "openrouter"
    assert completed.duration_ms == 750_000
    assert completed.linear_url == "https://linear.app/example/MT-ARCH-1"
  end

  test "archived runs table filters, sorts, and paginates" do
    rows = [
      %{
        issue_identifier: "MT-1",
        issue_title: "Searchable logs",
        status: "completed",
        outcome: "completed",
        project: "alpha",
        model: "sonnet",
        provider: "openrouter",
        finished_at: "2026-06-28T10:00:00Z",
        started_at: "2026-06-28T09:00:00Z",
        duration_ms: 3_600_000,
        tokens: %{total_tokens: 100},
        last_meaningful_result: "completed"
      },
      %{
        issue_identifier: "MT-2",
        issue_title: "Important failure",
        status: "failed",
        outcome: "exited: boom",
        project: "alpha",
        model: "codex",
        provider: "codex",
        finished_at: "2026-06-29T10:00:00Z",
        started_at: "2026-06-29T09:59:00Z",
        duration_ms: 60_000,
        tokens: %{total_tokens: 25},
        last_meaningful_result: "gates fail"
      },
      %{
        issue_identifier: "MT-3",
        issue_title: "Other",
        status: "completed",
        outcome: "completed",
        project: "beta",
        model: "sonnet",
        provider: "openrouter",
        finished_at: "2026-06-27T10:00:00Z",
        started_at: "2026-06-27T09:00:00Z",
        duration_ms: 3_600_000,
        tokens: %{total_tokens: 500},
        last_meaningful_result: "completed"
      }
    ]

    view = RondoWeb.ArchivedRuns.view(rows, %{search: "failure", status: "failed", sort_by: "ended", sort_dir: "desc"})
    assert view.total == 1
    assert [%{issue_identifier: "MT-2"}] = view.rows
    assert [%{issue_identifier: "MT-2"}] = view.recent_failures

    view = RondoWeb.ArchivedRuns.view(rows, %{model: "sonnet", sort_by: "tokens", sort_dir: "desc", page_size: 1})
    assert view.total == 2
    assert view.page_count == 2
    assert [%{issue_identifier: "MT-3"}] = view.rows
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

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive, :monotonic])}")
    File.rm_rf!(path)
    path
  end
end
