defmodule Rondo.RunTimelineTest do
  use Rondo.TestSupport

  alias Rondo.{RunDecision, RunLedger, RunTimeline}

  @start ~U[2026-05-10 15:30:00Z]
  @dispatch ~U[2026-05-10 15:30:01Z]
  @turn1_started ~U[2026-05-10 15:30:02Z]
  @planning_completed ~U[2026-05-10 15:30:03Z]
  @turn1_completed ~U[2026-05-10 15:30:05Z]
  @turn2_started ~U[2026-05-10 15:30:10Z]
  @gate_completed ~U[2026-05-10 15:30:12Z]
  @turn2_completed ~U[2026-05-10 15:30:15Z]
  @finished ~U[2026-05-10 15:30:18Z]
  @pause_decision ~U[2026-05-10 15:30:20Z]
  @interrupt ~U[2026-05-10 15:30:21Z]

  test "projects a single-turn run with step-level accounted spend" do
    {ledger, issue} = create_ledger!("timeline-single-turn")

    ledger = write_checkpoint!(ledger, :dispatch, %{attempt: 1}, @dispatch)
    ledger = write_checkpoint!(ledger, :workspace_ready, %{summary: "workspace ready"}, @dispatch)

    ledger =
      write_checkpoint!(
        ledger,
        :turn_started,
        %{
          turn_number: 1,
          usage: %{input_tokens: 10, output_tokens: 4, total_tokens: 14},
          accounted_usage: %{input_tokens: 10, output_tokens: 4, total_tokens: 14}
        },
        @turn1_started
      )

    _ledger =
      write_checkpoint!(
        ledger,
        :turn_completed,
        %{
          turn_number: 1,
          usage: %{input_tokens: 4, output_tokens: 2, total_tokens: 6},
          accounted_usage: %{input_tokens: 4, output_tokens: 2, total_tokens: 6}
        },
        @turn1_completed
      )

    run = %{
      identifier: issue.identifier,
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      session_id: "session-single-turn",
      started_at: @start,
      finished_at: @finished,
      exit_reason: "completed",
      turn_count: 1,
      event_log: [%{at: @turn1_started, event: :bash, message: "$ mix test"}]
    }

    projection = RunTimeline.project_run(run)

    assert Enum.map(projection.timeline, & &1.kind) == [
             "dispatch",
             "workspace_ready",
             "turn_started",
             "tool_activity",
             "turn_completed",
             "completed"
           ]

    turn_started = Enum.find(projection.timeline, &(&1.kind == "turn_started"))
    assert turn_started.accounted_usage["total_tokens"] == 14
    assert turn_started.accounted_usage_delta["total_tokens"] == 14

    tool = Enum.find(projection.timeline, &(&1.kind == "tool_activity"))
    assert tool.summary == "$ mix test"
  end

  test "projects model routing decision checkpoints with phase and selected model" do
    {ledger, issue} = create_ledger!("timeline-model-routing")

    _ledger =
      write_checkpoint!(
        ledger,
        :model_routing_decision,
        %{
          status: "honored",
          requested_tier: "frontier",
          resolved: %{adapter: "pi", model: "openai-codex/gpt-5.5"},
          reason: "resolved planning tier frontier",
          context: %{stage: "initial_spawn", phase: "planning"}
        },
        @turn1_started
      )

    run = %{
      identifier: issue.identifier,
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      session_id: "session-routing",
      started_at: @start,
      finished_at: @finished,
      exit_reason: "completed",
      turn_count: 1,
      event_log: []
    }

    projection = RunTimeline.project_run(run)
    step = Enum.find(projection.timeline, &(&1.kind == "model_routing_decision"))

    assert step.phase == "planning"
    assert step.status == "honored"
    assert step.outcome == "openai-codex/gpt-5.5"
    assert step.summary =~ "frontier"
    assert step.summary =~ "resolved planning tier frontier"
  end

  test "projects multi-turn runs with turn and gate boundaries in order" do
    {ledger, issue} = create_ledger!("timeline-multi-turn")

    ledger = write_checkpoint!(ledger, :dispatch, %{attempt: 1}, @dispatch)
    ledger = write_checkpoint!(ledger, :turn_started, %{turn_number: 1}, @turn1_started)
    ledger = write_checkpoint!(ledger, :turn_completed, %{turn_number: 1}, @turn1_completed)
    ledger = write_checkpoint!(ledger, :turn_started, %{turn_number: 2}, @turn2_started)
    ledger = write_checkpoint!(ledger, :gates_completed, %{status: "pass"}, @gate_completed)
    _ledger = write_checkpoint!(ledger, :turn_completed, %{turn_number: 2}, @turn2_completed)

    run = %{
      identifier: issue.identifier,
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      session_id: "session-multi-turn",
      started_at: @start,
      finished_at: @finished,
      exit_reason: "completed",
      turn_count: 2,
      event_log: []
    }

    projection = RunTimeline.project_run(run)
    kinds = Enum.map(projection.timeline, & &1.kind)

    assert kinds == [
             "dispatch",
             "turn_started",
             "turn_completed",
             "turn_started",
             "gates_completed",
             "turn_completed",
             "completed"
           ]

    assert Enum.at(projection.timeline, 0).duration_ms == 1_000
    assert Enum.count(projection.timeline, &(&1.kind == "turn_started")) == 2
    assert Enum.count(projection.timeline, &(&1.kind == "turn_completed")) == 2
  end

  test "projects gate failure with retry decision" do
    {ledger, issue} = create_ledger!("timeline-gate-failure")

    ledger = write_checkpoint!(ledger, :dispatch, %{attempt: 1}, @dispatch)
    ledger = write_checkpoint!(ledger, :turn_started, %{turn_number: 1}, @turn1_started)

    ledger =
      write_checkpoint!(
        ledger,
        :gates_completed,
        %{status: "fail", results_path: "artifacts/gates/turn-0001/results.json"},
        @gate_completed
      )

    _ledger =
      write_checkpoint!(
        ledger,
        :run_decision,
        RunDecision.checkpoint_payload(
          :retry,
          "gate_failed",
          "retry because worker/gate failed",
          turn_number: 1,
          retry_attempt: 1
        ),
        @turn2_started
      )

    run = %{
      identifier: issue.identifier,
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      session_id: "session-gate-failure",
      started_at: @start,
      finished_at: @finished,
      exit_reason: "failed",
      turn_count: 1,
      event_log: []
    }

    projection = RunTimeline.project_run(run)

    assert Enum.any?(projection.timeline, &(&1.kind == "gates_completed" and &1.status == "fail"))
    assert Enum.any?(projection.timeline, &(&1.kind == "retry" and &1.status == "retry"))
    assert Enum.any?(projection.timeline, &(&1.kind == "failed"))
  end

  test "projects paused runs with explicit pause and interrupt steps" do
    {ledger, issue} = create_ledger!("timeline-paused")

    ledger = write_checkpoint!(ledger, :dispatch, %{attempt: 1}, @dispatch)
    ledger = write_checkpoint!(ledger, :turn_started, %{turn_number: 1}, @turn1_started)

    ledger =
      write_checkpoint!(
        ledger,
        :run_decision,
        RunDecision.checkpoint_payload(:pause, "repeated_gate_failure", "pause because repeated gate failure", turn_number: 1, retry_attempt: 2),
        @pause_decision
      )

    {:ok, ledger} = RunLedger.pause_run(ledger, %{reason: "repeated_gate_failure", question: "Continue?"}, timestamp: @interrupt)

    run = %{
      identifier: issue.identifier,
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      session_id: "session-paused",
      started_at: @start,
      paused_at: @interrupt,
      turn_count: 1,
      event_log: []
    }

    projection = RunTimeline.project_run(run)

    assert Enum.any?(projection.timeline, &(&1.kind == "pause" and &1.status == "pause"))
    assert Enum.any?(projection.timeline, &(&1.kind == "interrupt_created" and &1.status == "paused"))
    assert projection.status == "paused"
  end

  test "projects event-log-only runs with normalized step kinds" do
    run = %{
      "identifier" => "MT-EVENT-LOG",
      "session_id" => "session-event-log",
      "started_at" => "2026-05-10T15:30:00Z",
      "finished_at" => "2026-05-10T15:30:08Z",
      "exit_reason" => "completed",
      "turn_count" => 1,
      "event_log" => [
        %{"at" => "2026-05-10T15:30:01Z", "event" => "claude_starting", "message" => "workspace ready"},
        %{"at" => "2026-05-10T15:30:02Z", "event" => "session_started", "message" => "turn started", "tokens" => %{"input_tokens" => 1, "output_tokens" => 0, "total_tokens" => 1}},
        %{"at" => 123, "event" => "result", "message" => "turn completed"},
        %{"at" => "2026-05-10T15:30:04Z", "event" => "invocation_completed", "message" => "invocation completed"},
        %{"at" => "2026-05-10T15:30:05Z", "event" => "invocation_failed", "message" => "invocation failed"},
        %{"at" => "2026-05-10T15:30:06Z", "event" => "assistant", "message" => "tool summary", "tokens" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}},
        %{"at" => "2026-05-10T15:30:07Z", "event" => "unknown", "message" => "ignored"},
        :ignored
      ]
    }

    projection = RunTimeline.project_run(run)

    assert Enum.map(projection.timeline, & &1.kind) == [
             "turn_completed",
             "workspace_ready",
             "turn_started",
             "turn_completed",
             "turn_failed",
             "tool_activity",
             "completed"
           ]

    turn_started = Enum.find(projection.timeline, &(&1.kind == "turn_started"))
    assert turn_started.accounted_usage_delta["input_tokens"] == 1

    weird_result = Enum.find(projection.timeline, &(&1.kind == "turn_completed" and &1.at == "123"))
    assert weird_result

    tool = Enum.find(projection.timeline, &(&1.kind == "tool_activity"))
    assert tool.summary == "tool summary"
  end

  test "projects sparse paused runs with synthetic interrupt steps" do
    run = %{
      identifier: "MT-PAUSED-SYNTHETIC",
      session_id: "session-paused-synthetic",
      started_at: @start,
      paused_at: @interrupt,
      exit_reason: "handed_off",
      turn_count: 1,
      event_log: :bogus
    }

    projection = RunTimeline.project_run(run)

    assert Enum.map(projection.timeline, & &1.kind) == ["interrupt_created"]
    assert projection.timeline |> hd() |> Map.fetch!(:status) == "paused"
    assert projection.status == "paused"
  end

  test "projects terminal-only runs with missing finish timestamps" do
    run = %{
      identifier: "MT-MISSING-FINISH",
      session_id: "session-missing-finish",
      started_at: @start,
      finished_at: nil,
      exit_reason: "completed",
      turn_count: 0,
      event_log: []
    }

    projection = RunTimeline.project_run(run)

    assert [%{kind: "completed", duration_ms: nil}] = projection.timeline
    assert projection.status == "completed"
  end

  test "projects checkpoint variants and final report metadata" do
    {ledger, issue} = create_ledger!("timeline-checkpoints")

    ledger = write_checkpoint!(ledger, :dispatch, %{attempt: 1}, @dispatch)
    ledger = write_checkpoint!(ledger, :turn_started, %{turn_number: 1}, @turn1_started)
    ledger = write_checkpoint!(ledger, :planning_completed, %{summary: "planning completed"}, @planning_completed)
    ledger = write_checkpoint!(ledger, :turn_failed, %{turn_number: 1, summary: "turn failed"}, @turn1_completed)
    ledger = write_checkpoint!(ledger, :turn_cancelled, %{turn_number: 1, summary: "turn cancelled"}, @turn2_started)
    ledger = write_checkpoint!(ledger, :edit_batch, %{summary: "edit batch"}, @turn2_completed)
    ledger = write_checkpoint!(ledger, :gates_reused, %{status: "reused"}, @gate_completed)

    report = %{
      "schema" => "rondo.final_report/v0",
      "summary" => "Did the work",
      "changed_files" => ["lib/a.ex"],
      "gates_run" => [%{"name" => "elixir-ci", "status" => "pass"}],
      "failures" => [],
      "risks" => [],
      "next_state" => "ready_for_review"
    }

    final_report_text = "All done.\n```json\n#{Jason.encode!(report)}\n```\n"
    assert {:ok, ledger, :valid} = RunLedger.record_final_report(ledger, final_report_text)

    assert :ok = File.rm(Path.join(ledger.run_dir, "checkpoints/0004-turn_failed.json"))

    ledger = write_checkpoint!(ledger, :completed, %{reason: "completed"}, @finished)
    ledger = write_checkpoint!(ledger, :terminated, %{reason: "terminated"}, @finished)

    run = %{
      identifier: issue.identifier,
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      session_id: "session-checkpoints",
      started_at: @start,
      finished_at: "not-a-datetime",
      exit_reason: "completed",
      turn_count: 1,
      event_log: []
    }

    projection = RunTimeline.project_run(run)
    kinds = Enum.map(projection.timeline, & &1.kind)

    assert "turn_failed" in kinds
    assert "planning_completed" in kinds
    assert "turn_cancelled" in kinds
    assert "tool_activity" in kinds
    assert "gates_reused" in kinds
    assert "final_report_validated" in kinds
    assert "completed" in kinds
    assert "terminated" in kinds

    final_report = Enum.find(projection.timeline, &(&1.kind == "final_report_validated"))
    assert final_report.artifacts |> Enum.any?(&(&1.kind == "final_report" and &1.path == "artifacts/final-report.json"))
    assert final_report.summary == "final report valid"
    assert final_report.status == "valid"
  end

  test "projects checkpoints from manifest payloads when checkpoint paths are absent" do
    {ledger, issue} = create_ledger!("timeline-manifest-payloads")

    ledger = write_checkpoint!(ledger, :dispatch, %{attempt: 1}, @dispatch)
    ledger = write_checkpoint!(ledger, :turn_started, %{turn_number: 1}, @turn1_started)

    manifest =
      ledger.manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("checkpoints", [
        %{"kind" => "mystery", "timestamp" => "2026-05-10T15:30:01Z", "payload" => %{"summary" => "ignored"}},
        %{"kind" => "dispatch", "timestamp" => "2026-05-10T15:30:02Z", "payload" => %{"summary" => "dispatch from manifest"}}
      ])
      |> Map.put("timestamps", %{"updated_at" => "2026-05-10T15:30:03Z"})

    File.write!(ledger.manifest_path, Jason.encode!(manifest))

    run = %{
      identifier: issue.identifier,
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      session_id: "session-manifest-payloads",
      started_at: @start,
      finished_at: @finished,
      exit_reason: "completed",
      turn_count: 1,
      event_log: []
    }

    projection = RunTimeline.project_run(run)

    assert Enum.any?(projection.timeline, &(&1.kind == "dispatch" and &1.summary == "dispatch from manifest"))
    assert Enum.any?(projection.timeline, &(&1.kind == "completed"))
    refute Enum.any?(projection.timeline, &(&1.kind == "mystery"))
  end

  test "projects default continue decisions when checkpoint payload omits kind" do
    {ledger, issue} = create_ledger!("timeline-default-continue")

    ledger = write_checkpoint!(ledger, :run_decision, %{}, @turn1_started)

    run = %{
      identifier: issue.identifier,
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      session_id: "session-default-continue",
      started_at: @start,
      finished_at: @finished,
      exit_reason: "completed",
      turn_count: 1,
      event_log: []
    }

    projection = RunTimeline.project_run(run)

    assert Enum.any?(projection.timeline, &(&1.kind == "continue" and &1.status == "continue"))
    assert Enum.any?(projection.timeline, &(&1.kind == "continue" and &1.summary == "continue"))
  end

  test "project/3 normalizes collections and sorts missing timestamps last" do
    projection =
      RunTimeline.project(
        [%{identifier: "MT-ACTIVE", session_id: "session-active"}],
        [%{identifier: "MT-ARCHIVED", session_id: "session-archived", started_at: "2026-05-10T15:30:00Z"}]
      )

    assert Enum.map(projection, & &1.identifier) == ["MT-ACTIVE", "MT-ARCHIVED"]
  end

  test "projects decision summaries from reason codes" do
    {ledger, issue} = create_ledger!("timeline-decision-summary")

    ledger = write_checkpoint!(ledger, :run_decision, %{decision_kind: "retry", reason_code: "gate_failed"}, @turn1_started)

    run = %{
      identifier: issue.identifier,
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      session_id: "session-decision-summary",
      started_at: @start,
      finished_at: @finished,
      exit_reason: "completed",
      turn_count: 1,
      event_log: []
    }

    projection = RunTimeline.project_run(run)

    assert Enum.any?(projection.timeline, &(&1.kind == "retry" and &1.summary == "retry because gate_failed"))
  end

  test "projects archived runs from sparse entries via loader fallback" do
    {ledger, issue} = create_ledger!("timeline-archived")

    ledger = write_checkpoint!(ledger, :dispatch, %{attempt: 1}, @dispatch)
    ledger = write_checkpoint!(ledger, :turn_started, %{turn_number: 1}, @turn1_started)
    _ledger = write_checkpoint!(ledger, :turn_completed, %{turn_number: 1}, @turn1_completed)

    archived_seed = %{identifier: issue.identifier, started_at: @start}

    loader = fn _identifier, _filename ->
      {:ok,
       %{
         identifier: issue.identifier,
         run_id: ledger.run_id,
         run_dir: ledger.run_dir,
         session_id: "session-archived",
         started_at: @start,
         finished_at: @finished,
         exit_reason: "completed",
         turn_count: 1,
         event_log: []
       }}
    end

    projection = RunTimeline.project_archived_run(archived_seed, loader, [])

    assert projection.archived == true
    assert projection.run_id == ledger.run_id
    kinds = Enum.map(projection.timeline, & &1.kind)
    assert "dispatch" in kinds
    assert "turn_started" in kinds
    assert "turn_completed" in kinds
    assert "completed" in kinds
  end

  test "projects archived runs with fallback archive filenames for malformed timestamps" do
    loader = fn identifier, filename ->
      send(self(), {:archive_loader_called, identifier, filename})

      {:ok,
       %{
         identifier: identifier,
         run_id: "archived-run",
         run_dir: "/tmp/rondo-archived",
         session_id: "session-archived-fallback",
         started_at: @start,
         finished_at: @finished,
         exit_reason: "completed",
         turn_count: 0,
         event_log: []
       }}
    end

    projection =
      RunTimeline.project_archived_run(
        %{identifier: "MT-ARCHIVE-FALLBACK", started_at: "not-a-datetime"},
        loader,
        []
      )

    assert_receive {:archive_loader_called, "MT-ARCHIVE-FALLBACK", "not-a-datetime.json"}
    assert projection.archived == true
  end

  defp create_ledger!(workspace_root) do
    issue = %Issue{
      id: "issue-#{workspace_root}",
      identifier: "MT-#{String.upcase(String.replace(workspace_root, ~r/[^a-z0-9]+/i, "-"))}",
      title: "Timeline fixture #{workspace_root}",
      description: "Timeline fixture",
      state: "In Progress",
      url: "https://example.org/issues/#{workspace_root}"
    }

    root = Path.join(System.tmp_dir!(), "rondo-#{workspace_root}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: root, now: @start, random_suffix: "cafebabe")
    {ledger, issue}
  end

  defp write_checkpoint!(ledger, kind, payload, timestamp) do
    assert {:ok, ledger} = RunLedger.write_checkpoint(ledger, kind, payload, timestamp: timestamp)
    ledger
  end
end
