defmodule Rondo.OrchestratorStatusTest do
  use Rondo.TestSupport

  test "snapshot returns :timeout when snapshot server is unresponsive" do
    server_name = Module.concat(__MODULE__, :UnresponsiveSnapshotServer)
    parent = self()

    pid =
      spawn(fn ->
        Process.register(self(), server_name)
        send(parent, :snapshot_server_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :snapshot_server_ready, 1_000
    assert Orchestrator.snapshot(server_name, 10) == :timeout

    send(pid, :stop)
  end

  test "public server helpers accept pid servers" do
    orchestrator_name = Module.concat(__MODULE__, :PidServerHelperOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    assert %{running: []} = Orchestrator.snapshot(pid, 1_000)
    assert %{queued: true} = Orchestrator.request_refresh(pid)
    assert {:error, :guidance_interrupt_not_found} = Orchestrator.submit_guidance(pid, "missing", "approve_once")
  end

  test "guidance can address paused claims by issue identifier" do
    workspace_root = tmp_dir("orchestrator-guidance-abort")

    issue = %Issue{
      id: "issue-guidance-identifier",
      identifier: "MT-GUIDE-ID",
      title: "Identifier guidance",
      description: "Abort by identifier",
      state: "Todo",
      url: "https://example.org/issues/MT-GUIDE-ID"
    }

    assert {:ok, ledger} = Rondo.RunLedger.create_run(issue, workspace_root: workspace_root, random_suffix: "guidance-abort")

    orchestrator_name = Module.concat(__MODULE__, :IdentifierGuidanceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    paused_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      state: issue.state,
      session_id: nil,
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      workspace: nil,
      paused_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      retry_attempt: 0,
      latest_gate: nil,
      interrupt: %{"reason" => "action_policy_guidance_required"},
      tracker_visibility: "known",
      ledger: ledger
    }

    :sys.replace_state(pid, fn state ->
      %{state | paused_interrupts: %{issue.id => paused_entry}, claimed: MapSet.new([issue.id])}
    end)

    assert {:ok, %{status: :aborted, issue_id: "issue-guidance-identifier"}} =
             Orchestrator.submit_guidance(orchestrator_name, "MT-GUIDE-ID", "abort_run")

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.paused == []
    refute MapSet.member?(:sys.get_state(pid).claimed, issue.id)

    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
    run_decision_checkpoint = Enum.find(manifest["checkpoints"], &(&1["kind"] == "run_decision"))
    assert run_decision_checkpoint

    run_decision =
      Path.join(manifest["run_dir"], run_decision_checkpoint["path"])
      |> File.read!()
      |> Jason.decode!()

    assert run_decision["payload"]["decision_kind"] == "terminate"
    assert run_decision["payload"]["reason_code"] == "operator_abort"
  end

  test "refresh releases stale action-policy paused claims when policy now allows" do
    workspace_root = tmp_dir("orchestrator-stale-paused-policy-allow")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: fake_claude_script(workspace_root, "stale-paused-session", 1),
      action_policy_command: fake_action_policy_script(workspace_root, "allow")
    )

    issue = %Issue{
      id: "issue-stale-paused-policy",
      identifier: "MT-STALE-PAUSED",
      title: "Stale paused policy",
      description: "Should redispatch after policy allows",
      state: "Todo",
      url: "https://example.org/issues/MT-STALE-PAUSED"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])
    Application.put_env(:rondo, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :StalePausedPolicyOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_recipient)
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    paused_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      state: issue.state,
      session_id: nil,
      run_id: "run-stale-paused-policy",
      run_dir: nil,
      workspace: Path.join(workspace_root, issue.identifier),
      paused_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      retry_attempt: 0,
      latest_gate: nil,
      interrupt: %{
        "reason" => "action_policy_guidance_required",
        "blocked_side_effect" => %{
          "action" => "workspace.lifecycle.create",
          "classes" => ["workspace-write"],
          "operation" => "Create workspace for MT-STALE-PAUSED"
        },
        "policy" => %{"decision" => "ask"}
      },
      tracker_visibility: "known",
      ledger: nil
    }

    state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _state ->
      %{
        state
        | max_concurrent_agents: 1,
          poll_interval_ms: 60_000,
          paused_interrupts: %{issue.id => paused_entry},
          claimed: MapSet.new([issue.id])
      }
    end)

    send(pid, {:tick, state.tick_token})

    assert_receive {:memory_tracker_state_update, "issue-stale-paused-policy", "In Progress"}, 10_000

    running_entry =
      wait_until(fn ->
        case GenServer.call(pid, :snapshot).running do
          [entry | _] -> entry
          _ -> nil
        end
      end)

    assert running_entry.issue_id == issue.id
    assert GenServer.call(pid, :snapshot).paused == []
  end

  test "refresh marks malformed action-policy paused claims stale" do
    workspace_root = tmp_dir("orchestrator-malformed-paused-policy")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: fake_claude_script(workspace_root, "malformed-paused-session", 0),
      action_policy_command: fake_action_policy_script(workspace_root, "allow")
    )

    issue = %Issue{
      id: "issue-malformed-paused-policy",
      identifier: "MT-MALFORMED-PAUSED",
      title: "Malformed paused policy",
      description: "Should mark malformed policy pause stale",
      state: "Todo",
      url: "https://example.org/issues/MT-MALFORMED-PAUSED"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :MalformedPausedPolicyOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    paused_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      state: issue.state,
      session_id: nil,
      run_id: "run-malformed-paused-policy",
      run_dir: nil,
      workspace: Path.join(workspace_root, issue.identifier),
      paused_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      retry_attempt: 0,
      latest_gate: nil,
      interrupt: %{"reason" => "action_policy_guidance_required"},
      tracker_visibility: "known",
      ledger: nil
    }

    state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _state ->
      %{
        state
        | max_concurrent_agents: 1,
          poll_interval_ms: 60_000,
          paused_interrupts: %{issue.id => paused_entry},
          claimed: MapSet.new([issue.id])
      }
    end)

    send(pid, {:tick, state.tick_token})

    paused_entry =
      wait_until(fn ->
        case GenServer.call(pid, :snapshot).paused do
          [%{issue_id: "issue-malformed-paused-policy", stale_reason: stale_reason} = entry]
          when is_binary(stale_reason) ->
            entry

          _ ->
            nil
        end
      end)

    assert paused_entry.stale_reason =~ "invalid_paused_side_effect"
    assert paused_entry.tracker_visibility == "known"
    assert paused_entry.blocks_dispatch == true
  end

  test "refresh clears stale reason after successful paused policy revalidation" do
    workspace_root = tmp_dir("orchestrator-paused-policy-clear-stale")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: fake_claude_script(workspace_root, "clear-stale-session", 0),
      action_policy_command: fake_action_policy_script(workspace_root, "ask")
    )

    issue = %Issue{
      id: "issue-clear-paused-stale",
      identifier: "MT-CLEAR-STALE",
      title: "Clear stale paused policy",
      description: "Should clear stale marker after revalidation",
      state: "Todo",
      url: "https://example.org/issues/MT-CLEAR-STALE"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :ClearPausedStaleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    paused_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      state: issue.state,
      session_id: nil,
      run_id: "run-clear-paused-stale",
      run_dir: nil,
      workspace: Path.join(workspace_root, issue.identifier),
      paused_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      retry_attempt: 0,
      latest_gate: nil,
      interrupt: %{
        "reason" => "action_policy_guidance_required",
        "blocked_side_effect" => %{
          "action" => "workspace.lifecycle.create",
          "classes" => ["workspace-write"],
          "operation" => "Create workspace for MT-CLEAR-STALE"
        },
        "policy" => %{"decision" => "ask"}
      },
      tracker_visibility: "missing",
      stale_reason: "issue_not_visible",
      ledger: nil
    }

    state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _state ->
      %{
        state
        | max_concurrent_agents: 1,
          poll_interval_ms: 60_000,
          paused_interrupts: %{issue.id => paused_entry},
          claimed: MapSet.new([issue.id])
      }
    end)

    send(pid, {:tick, state.tick_token})

    paused_entry =
      wait_until(fn ->
        case GenServer.call(pid, :snapshot).paused do
          [%{issue_id: "issue-clear-paused-stale", stale_reason: nil, revalidated_at: revalidated_at} = entry]
          when is_binary(revalidated_at) ->
            entry

          _ ->
            nil
        end
      end)

    assert paused_entry.stale_reason == nil
    assert paused_entry.tracker_visibility == "known"
    assert get_in(paused_entry.interrupt, ["policy", "decision"]) == "ask"
  end

  test "guidance and refresh helpers return unavailable when calls exit" do
    parent = self()
    refresh_server = Module.concat(__MODULE__, :CrashingRefreshServer)

    refresh_pid =
      spawn(fn ->
        Process.register(self(), refresh_server)
        send(parent, :refresh_server_ready)

        receive do
          {:"$gen_call", _from, :request_refresh} -> exit(:boom)
        end
      end)

    assert_receive :refresh_server_ready, 1_000
    assert Orchestrator.request_refresh(refresh_server) == :unavailable
    refute Process.alive?(refresh_pid)

    guidance_server = Module.concat(__MODULE__, :CrashingGuidanceServer)

    guidance_pid =
      spawn(fn ->
        Process.register(self(), guidance_server)
        send(parent, :guidance_server_ready)

        receive do
          {:"$gen_call", _from, {:submit_guidance, "issue", "approve_once"}} -> exit(:boom)
        end
      end)

    assert_receive :guidance_server_ready, 1_000
    assert Orchestrator.submit_guidance(guidance_server, "issue", "approve_once") == :unavailable
    refute Process.alive?(guidance_pid)
  end

  test "orchestrator snapshot reflects last claude update and session id" do
    issue_id = "issue-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-188",
      title: "Snapshot test",
      description: "Capture claude state",
      state: "In Progress",
      url: "https://example.org/issues/MT-188"
    }

    orchestrator_name = Module.concat(__MODULE__, :SnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      started_at: started_at
    }

    state_with_issue =
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))

    :sys.replace_state(pid, fn _ -> state_with_issue end)

    now = DateTime.utc_now()

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-live-turn-live",
         timestamp: now
       }}
    )

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{method: "some-event"},
         timestamp: now
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.issue_id == issue_id
    assert snapshot_entry.session_id == "thread-live-turn-live"
    assert snapshot_entry.turn_count == 1
    assert snapshot_entry.last_claude_timestamp == now

    assert snapshot_entry.last_claude_message == %{
             event: :notification,
             message: %{method: "some-event"},
             timestamp: now
           }
  end

  test "orchestrator accounts repeated pi cumulative snapshots once and records raw/accounted usage" do
    issue_id = "issue-pi-repeated-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PI-REPEAT",
      title: "Pi repeated usage",
      description: "Do not double count repeated cumulative Pi usage",
      state: "In Progress",
      url: "https://example.org/issues/MT-PI-REPEAT"
    }

    workspace_root = tmp_dir("orchestrator-pi-repeated-ledger")
    assert {:ok, ledger} = Rondo.RunLedger.create_run(issue, workspace_root: workspace_root)

    orchestrator_name = Module.concat(__MODULE__, :PiRepeatedUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: "pi-session-repeat",
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      ledger: ledger,
      run_ref: nil,
      turn_count: 0,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at,
      event_log: []
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    usage = %{input_tokens: 80, output_tokens: 20, total_tokens: 100, cost: 0.25}

    for event <- [:assistant_message, :invocation_completed] do
      send(
        pid,
        {:claude_worker_update, issue_id,
         %{
           event: event,
           adapter: "pi",
           session_id: "pi-session-repeat",
           usage: usage,
           timestamp: DateTime.utc_now()
         }}
      )
    end

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.claude_input_tokens == 80
    assert snapshot_entry.claude_output_tokens == 20
    assert snapshot_entry.claude_total_tokens == 100

    events_path = Path.join(ledger.run_dir, "artifacts/agent-events.ndjson")

    [first, second] =
      events_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert first["usage"] == %{"cost" => 0.25, "input_tokens" => 80, "output_tokens" => 20, "total_tokens" => 100}
    assert first["accounted_usage"] == %{"cost" => 0.25, "input_tokens" => 80, "output_tokens" => 20, "total_tokens" => 100}
    assert second["usage"] == first["usage"]
    assert second["accounted_usage"] == %{"cost" => 0.0, "input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}
  end

  test "orchestrator preserves the fallback baseline when pi usage upgrades to session_id" do
    issue_id = "issue-pi-accounting-upgrade"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PI-UPGRADE",
      title: "Pi fallback-to-stable accounting upgrade",
      description: "Preserve cumulative Pi baseline when session metadata arrives late",
      state: "In Progress",
      url: "https://example.org/issues/MT-PI-UPGRADE"
    }

    workspace_root = tmp_dir("orchestrator-pi-fallback-upgrade-ledger")
    assert {:ok, ledger} = Rondo.RunLedger.create_run(issue, workspace_root: workspace_root)

    orchestrator_name = Module.concat(__MODULE__, :PiFallbackToStableOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      ledger: ledger,
      run_ref: nil,
      turn_count: 0,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at,
      event_log: []
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    usage = %{input_tokens: 80, output_tokens: 20, total_tokens: 100, cost: 0.25}
    upgraded_usage = %{input_tokens: 120, output_tokens: 30, total_tokens: 150, cost: 0.35}

    for {event, update} <- [
          {:assistant_message, %{adapter: "pi", usage: usage}},
          {:assistant_message, %{adapter: "pi", session_id: "pi-session-upgrade", usage: usage}},
          {:invocation_completed, %{adapter: "pi", session_id: "pi-session-upgrade", usage: upgraded_usage}}
        ] do
      send(pid, {:claude_worker_update, issue_id, Map.merge(update, %{event: event, timestamp: DateTime.utc_now()})})
    end

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.claude_input_tokens == 120
    assert snapshot_entry.claude_output_tokens == 30
    assert snapshot_entry.claude_total_tokens == 150

    events_path = Path.join(ledger.run_dir, "artifacts/agent-events.ndjson")

    [first, second, third] =
      events_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert first["accounted_usage"] == %{"cost" => 0.25, "input_tokens" => 80, "output_tokens" => 20, "total_tokens" => 100}
    assert second["usage"] == first["usage"]
    assert second["accounted_usage"] == %{"cost" => 0.0, "input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}
    assert third["accounted_usage"]["input_tokens"] == 40
    assert third["accounted_usage"]["output_tokens"] == 10
    assert third["accounted_usage"]["total_tokens"] == 50
    assert_in_delta third["accounted_usage"]["cost"], 0.1, 1.0e-12
  end

  test "orchestrator accounts cumulative pi growth by positive deltas" do
    issue_id = "issue-pi-cumulative-growth"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PI-GROW",
      title: "Pi cumulative growth",
      description: "Account cumulative Pi usage growth without summing snapshots",
      state: "In Progress",
      url: "https://example.org/issues/MT-PI-GROW"
    }

    orchestrator_name = Module.concat(__MODULE__, :PiCumulativeGrowthOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: "pi-session-growth",
      turn_count: 0,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at,
      event_log: []
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    for {event, usage} <- [
          {:assistant_message, %{input_tokens: 100, output_tokens: 50, total_tokens: 150}},
          {:assistant_message, %{input_tokens: 125, output_tokens: 70, total_tokens: 195}},
          {:invocation_completed, %{input_tokens: 125, output_tokens: 70, total_tokens: 195}}
        ] do
      send(
        pid,
        {:claude_worker_update, issue_id,
         %{
           event: event,
           adapter: "pi",
           session_id: "pi-session-growth",
           usage: usage,
           timestamp: DateTime.utc_now()
         }}
      )
    end

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.claude_input_tokens == 125
    assert snapshot_entry.claude_output_tokens == 70
    assert snapshot_entry.claude_total_tokens == 195

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)
    assert completed_state.claude_totals.input_tokens == 125
    assert completed_state.claude_totals.output_tokens == 70
    assert completed_state.claude_totals.total_tokens == 195
  end

  test "orchestrator snapshot tracks claude session totals and session id" do
    issue_id = "issue-usage-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-201",
      title: "Usage snapshot test",
      description: "Collect usage stats",
      state: "In Progress",
      url: "https://example.org/issues/MT-201"
    }

    orchestrator_name = Module.concat(__MODULE__, :UsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-usage-turn-usage",
         timestamp: now
       }}
    )

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "tokenUsage" => %{
               "total" => %{"inputTokens" => 12, "outputTokens" => 4, "totalTokens" => 16}
             }
           }
         },
         usage: %{input_tokens: 12, output_tokens: 4, total_tokens: 16},
         timestamp: now
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.session_id == "thread-usage-turn-usage"
    assert snapshot_entry.claude_input_tokens == 12
    assert snapshot_entry.claude_output_tokens == 4
    assert snapshot_entry.claude_total_tokens == 16
    assert snapshot_entry.turn_count == 1
    assert is_integer(snapshot_entry.runtime_seconds)

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.claude_totals.input_tokens == 12
    assert completed_state.claude_totals.output_tokens == 4
    assert completed_state.claude_totals.total_tokens == 16
    assert is_integer(completed_state.claude_totals.seconds_running)
  end

  test "orchestrator snapshot tracks turn completed usage when present" do
    issue_id = "issue-turn-completed-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-202",
      title: "Turn completed usage test",
      description: "Track final turn usage",
      state: "In Progress",
      url: "https://example.org/issues/MT-202"
    }

    orchestrator_name = Module.concat(__MODULE__, :TurnCompletedUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :turn_completed,
         payload: %{
           method: "turn/completed",
           usage: %{"input_tokens" => "12", "output_tokens" => 4, "total_tokens" => 16}
         },
         usage: %{input_tokens: 12, output_tokens: 4, total_tokens: 16},
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.claude_input_tokens == 12
    assert snapshot_entry.claude_output_tokens == 4
    assert snapshot_entry.claude_total_tokens == 16

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)
    assert completed_state.claude_totals.input_tokens == 12
    assert completed_state.claude_totals.output_tokens == 4
    assert completed_state.claude_totals.total_tokens == 16
  end

  test "orchestrator snapshot tracks claude token-count cumulative usage payloads" do
    issue_id = "issue-token-count-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-220",
      title: "Token count snapshot test",
      description: "Validate token-count style payloads",
      state: "In Progress",
      url: "https://example.org/issues/MT-220"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenCountOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "claude/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "input_tokens" => "2",
                   "output_tokens" => 2,
                   "total_tokens" => 4
                 }
               }
             }
           }
         },
         usage: %{input_tokens: 2, output_tokens: 2, total_tokens: 4},
         timestamp: now
       }}
    )

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "claude/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "prompt_tokens" => 10,
                   "completion_tokens" => 5,
                   "total_tokens" => 15
                 }
               }
             }
           }
         },
         usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    # Per-message usage is additive: 2+10=12, 2+5=7, 4+15=19
    assert snapshot_entry.claude_input_tokens == 12
    assert snapshot_entry.claude_output_tokens == 7
    assert snapshot_entry.claude_total_tokens == 19

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.claude_totals.input_tokens == 12
    assert completed_state.claude_totals.output_tokens == 7
    assert completed_state.claude_totals.total_tokens == 19
  end

  test "orchestrator snapshot tracks claude rate-limit payloads" do
    issue_id = "issue-rate-limit-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-221",
      title: "Rate limit snapshot test",
      description: "Capture claude rate limit state",
      state: "In Progress",
      url: "https://example.org/issues/MT-221"
    }

    orchestrator_name = Module.concat(__MODULE__, :RateLimitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    rate_limits = %{
      "limit_id" => "claude",
      "primary" => %{"remaining" => 90, "limit" => 100},
      "secondary" => nil,
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => nil}
    }

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "claude/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "rate_limits" => rate_limits
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.rate_limits == rate_limits
  end

  test "orchestrator token accounting prefers total_token_usage over last_token_usage in token_count payloads" do
    issue_id = "issue-token-precedence"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-222",
      title: "Token precedence",
      description: "Prefer per-event deltas",
      state: "In Progress",
      url: "https://example.org/issues/MT-222"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenPrecedenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "claude/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 2,
                     "output_tokens" => 1,
                     "total_tokens" => 3
                   },
                   "total_token_usage" => %{
                     "input_tokens" => 200,
                     "output_tokens" => 100,
                     "total_tokens" => 300
                   }
                 }
               }
             }
           }
         },
         usage: %{input_tokens: 200, output_tokens: 100, total_tokens: 300},
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.claude_input_tokens == 200
    assert snapshot_entry.claude_output_tokens == 100
    assert snapshot_entry.claude_total_tokens == 300
  end

  test "orchestrator token accounting accumulates monotonic thread token usage totals" do
    issue_id = "issue-thread-token-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-223",
      title: "Thread token usage",
      description: "Accumulate absolute thread totals",
      state: "In Progress",
      url: "https://example.org/issues/MT-223"
    }

    orchestrator_name = Module.concat(__MODULE__, :ThreadTokenUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    for usage <- [
          %{input_tokens: 8, output_tokens: 3, total_tokens: 11},
          %{input_tokens: 10, output_tokens: 4, total_tokens: 14}
        ] do
      send(
        pid,
        {:claude_worker_update, issue_id,
         %{
           event: :notification,
           payload: %{
             "method" => "thread/tokenUsage/updated",
             "params" => %{"tokenUsage" => %{"total" => usage}}
           },
           usage: usage,
           timestamp: DateTime.utc_now()
         }}
      )
    end

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    # Per-message usage is additive: 8+10=18, 3+4=7, 11+14=25
    assert snapshot_entry.claude_input_tokens == 18
    assert snapshot_entry.claude_output_tokens == 7
    assert snapshot_entry.claude_total_tokens == 25
  end

  test "orchestrator token accounting ignores last_token_usage without cumulative totals" do
    issue_id = "issue-last-token-ignored"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-224",
      title: "Last token ignored",
      description: "Ignore delta-only token reports",
      state: "In Progress",
      url: "https://example.org/issues/MT-224"
    }

    orchestrator_name = Module.concat(__MODULE__, :LastTokenIgnoredOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "claude/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 8,
                     "output_tokens" => 3,
                     "total_tokens" => 11
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.claude_input_tokens == 0
    assert snapshot_entry.claude_output_tokens == 0
    assert snapshot_entry.claude_total_tokens == 0
  end

  test "orchestrator snapshot includes retry backoff entries" do
    orchestrator_name = Module.concat(__MODULE__, :RetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    retry_entry = %{
      attempt: 2,
      timer_ref: nil,
      due_at_ms: System.monotonic_time(:millisecond) + 5_000,
      identifier: "MT-500",
      error: "agent exited: :boom"
    }

    initial_state = :sys.get_state(pid)
    new_state = %{initial_state | retry_attempts: %{"mt-500" => retry_entry}}
    :sys.replace_state(pid, fn _ -> new_state end)

    snapshot = GenServer.call(pid, :snapshot)
    assert is_list(snapshot.retrying)

    assert [
             %{
               issue_id: "mt-500",
               attempt: 2,
               due_in_ms: due_in_ms,
               identifier: "MT-500",
               error: "agent exited: :boom"
             }
           ] = snapshot.retrying

    assert due_in_ms > 0
  end

  test "orchestrator snapshot includes poll countdown and checking status" do
    orchestrator_name = Module.concat(__MODULE__, :PollingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    now_ms = System.monotonic_time(:millisecond)

    _idle_snapshot =
      wait_until(fn ->
        case Orchestrator.snapshot(pid, 100) do
          %{polling: %{checking?: false}} = snapshot -> snapshot
          _other -> false
        end
      end)

    state = :sys.get_state(pid)

    # Project the snapshot fields from a copied state to keep this test deterministic
    # under full-suite load while still exercising the public snapshot shape above.
    snapshot =
      state
      |> Map.put(:poll_interval_ms, 30_000)
      |> Map.put(:next_poll_due_at_ms, now_ms + 4_000)
      |> Map.put(:poll_check_in_progress, false)
      |> polling_snapshot_for_test()

    assert %{
             checking?: false,
             poll_interval_ms: 30_000,
             next_poll_in_ms: due_in_ms
           } = snapshot

    assert is_integer(due_in_ms)
    assert due_in_ms >= 0
    assert due_in_ms <= 4_000

    snapshot =
      state
      |> Map.put(:poll_check_in_progress, true)
      |> Map.put(:next_poll_due_at_ms, nil)
      |> polling_snapshot_for_test()

    assert %{checking?: true, next_poll_in_ms: nil} = snapshot
  end

  test "orchestrator triggers an immediate poll cycle shortly after startup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 5_000
    )

    orchestrator_name = Module.concat(__MODULE__, :ImmediateStartupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert %{polling: %{checking?: true}} =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: true}} ->
                   true

                 _ ->
                   false
               end,
               2_000
             )

    assert %{
             polling: %{
               checking?: false,
               next_poll_in_ms: next_poll_in_ms,
               poll_interval_ms: 5_000
             }
           } =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}}
                 when is_integer(due_in_ms) and due_in_ms <= 5_000 ->
                   true

                 _ ->
                   false
               end,
               2_000
             )

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
  end

  test "orchestrator poll cycle resets next refresh countdown after a check" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    orchestrator_name = Module.concat(__MODULE__, :PollCycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 50,
          poll_check_in_progress: true,
          next_poll_due_at_ms: nil
      }
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(pid, fn
        %{polling: %{checking?: false, poll_interval_ms: 50, next_poll_in_ms: next_poll_in_ms}}
        when is_integer(next_poll_in_ms) and next_poll_in_ms <= 50 ->
          true

        _ ->
          false
      end)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 50,
               next_poll_in_ms: next_poll_in_ms
             }
           } = snapshot

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
    assert next_poll_in_ms <= 50
  end

  test "orchestrator restarts stalled workers with retry backoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      claude_stall_timeout_ms: 1_000
    )

    issue_id = "issue-stall"
    orchestrator_name = Module.concat(__MODULE__, :StallOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    {:ok, worker_pid} =
      Task.Supervisor.start_child(Rondo.TaskSupervisor, fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-STALL",
      issue: %Issue{id: issue_id, identifier: "MT-STALL", state: "In Progress"},
      session_id: "thread-stall-turn-stall",
      last_claude_message: nil,
      last_claude_timestamp: stale_activity_at,
      last_claude_event: :notification,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    before_tick_ms = System.monotonic_time(:millisecond)
    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-STALL",
             error: "stalled for " <> _
           } = state.retry_attempts[issue_id]

    assert is_integer(due_at_ms)
    scheduled_delay_ms = due_at_ms - before_tick_ms
    assert scheduled_delay_ms >= 9_000
    assert scheduled_delay_ms <= 10_500
  end

  test "status dashboard renders offline marker to terminal" do
    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = StatusDashboard.render_offline_status()
      end)

    assert rendered =~ "app_status=offline"
    refute rendered =~ "Timestamp:"
  end

  test "status dashboard renders linear project link in header" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered =~ "https://linear.app/project/project/issues"
    refute rendered =~ "Dashboard:"
  end

  test "status dashboard renders dashboard url on its own line when server port is configured" do
    previous_port_override = Application.get_env(:rondo, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:rondo, :server_port_override)
      else
        Application.put_env(:rondo, :server_port_override, previous_port_override)
      end
    end)

    Application.put_env(:rondo, :server_port_override, 4000)

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered =~ "│ Project:"
    assert rendered =~ "https://linear.app/project/project/issues"
    assert rendered =~ "│ Dashboard:"
    assert rendered =~ "http://127.0.0.1:4000/"
  end

  test "status dashboard prefers the bound server port and normalizes wildcard hosts" do
    assert StatusDashboard.dashboard_url_for_test("0.0.0.0", 0, 43_123) ==
             "http://127.0.0.1:43123/"

    assert StatusDashboard.dashboard_url_for_test("::1", 4000, nil) ==
             "http://[::1]:4000/"
  end

  test "status dashboard renders next refresh countdown and checking marker" do
    waiting_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: false, next_poll_in_ms: 2_000, poll_interval_ms: 30_000}
       }}

    waiting_rendered = StatusDashboard.format_snapshot_content_for_test(waiting_snapshot, 0.0)
    assert waiting_rendered =~ "Next refresh:"
    assert waiting_rendered =~ "2s"

    checking_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: true, next_poll_in_ms: nil, poll_interval_ms: 30_000}
       }}

    checking_rendered = StatusDashboard.format_snapshot_content_for_test(checking_snapshot, 0.0)
    assert checking_rendered =~ "checking now…"
  end

  test "status dashboard adds a spacer line before backoff queue when no agents are active" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/No active agents\r?\n│\s*\r?\n├─ Backoff queue/
  end

  test "status dashboard adds a spacer line before backoff queue when agents are active" do
    snapshot_data =
      {:ok,
       %{
         running: [
           %{
             identifier: "MT-777",
             state: "running",
             session_id: "thread-1234567890",
             claude_session_id: "4242",
             claude_total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_claude_event: "turn_completed",
             last_claude_message: %{
               event: :notification,
               message: %{
                 "method" => "turn/completed",
                 "params" => %{"turn" => %{"status" => "completed"}}
               }
             }
           }
         ],
         retrying: [],
         claude_totals: %{
           input_tokens: 90,
           output_tokens: 12,
           total_tokens: 102,
           seconds_running: 75
         },
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/MT-777.*\r?\n│\s*\r?\n├─ Backoff queue/s
  end

  test "status dashboard renders an unstyled closing corner when the retry queue is empty" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered |> String.split("\n") |> List.last() == "╰─"
  end

  test "status dashboard coalesces rapid updates to one render per interval" do
    dashboard_name = Module.concat(__MODULE__, :RenderDashboard)
    parent = self()
    orchestrator_pid = Process.whereis(Rondo.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(Rondo.Orchestrator)) do
        case Supervisor.restart_child(Rondo.Supervisor, Rondo.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(Rondo.Supervisor, Rondo.Orchestrator)
    end

    {:ok, pid} =
      StatusDashboard.start_link(
        name: dashboard_name,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 16,
        render_fun: fn content ->
          send(parent, {:render, System.monotonic_time(:millisecond), content})
        end
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    StatusDashboard.notify_update(dashboard_name)
    assert_receive {:render, first_render_ms, _content}, 1_000

    :sys.replace_state(pid, fn state ->
      %{state | last_snapshot_fingerprint: :force_next_change, last_rendered_content: nil}
    end)

    StatusDashboard.notify_update(dashboard_name)
    StatusDashboard.notify_update(dashboard_name)

    assert_receive {:render, second_render_ms, _content}, 1_000
    assert second_render_ms > first_render_ms
    refute_receive {:render, _third_render_ms, _content}, 60
  end

  test "status dashboard computes rolling 5-second token throughput" do
    assert StatusDashboard.rolling_tps([], 10_000, 0) == 0.0

    assert StatusDashboard.rolling_tps([{9_000, 20}], 10_000, 40) == 20.0

    # sample older than 5s is dropped from the window
    assert StatusDashboard.rolling_tps([{4_900, 10}], 10_000, 90) == 0.0

    tps =
      StatusDashboard.rolling_tps(
        [{9_500, 10}, {9_000, 40}, {8_000, 80}],
        10_000,
        95
      )

    assert tps == 7.5
  end

  test "status dashboard throttles tps updates to once per second" do
    {first_second, first_tps} =
      StatusDashboard.throttled_tps(nil, nil, 10_000, [{9_000, 20}], 40)

    {same_second, same_tps} =
      StatusDashboard.throttled_tps(first_second, first_tps, 10_500, [{9_000, 20}], 200)

    assert same_second == first_second
    assert same_tps == first_tps

    {next_second, next_tps} =
      StatusDashboard.throttled_tps(same_second, same_tps, 11_000, [{10_500, 200}], 260)

    assert next_second == 11
    refute next_tps == same_tps
  end

  test "status dashboard formats timestamps at second precision" do
    dt = ~U[2026-02-15 21:36:38.987654Z]
    assert StatusDashboard.format_timestamp_for_test(dt) == "2026-02-15 21:36:38Z"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for steady throughput" do
    now_ms = 600_000
    current_tokens = 6_000

    samples =
      for timestamp <- 575_000..0//-25_000 do
        {timestamp, div(timestamp, 100)}
      end

    assert StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens) ==
             "████████████████████████"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for ramping throughput" do
    now_ms = 600_000

    rates_per_bucket =
      1..24
      |> Enum.map(&(&1 * 2))

    {current_tokens, samples} = graph_samples_from_rates(rates_per_bucket)

    assert StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens) ==
             "▁▂▂▂▃▃▃▃▄▄▄▅▅▅▆▆▆▆▇▇▇██▅"
  end

  test "status dashboard keeps historical TPS bars stable within the active bucket" do
    now_ms = 600_000
    current_tokens = 74_400
    next_current_tokens = current_tokens + 120
    samples = graph_samples_for_stability_test(now_ms)

    graph_at_now = StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens)

    graph_next_second =
      StatusDashboard.tps_graph_for_test(samples, now_ms + 1_000, next_current_tokens)

    historical_changes =
      graph_at_now
      |> String.graphemes()
      |> Enum.zip(String.graphemes(graph_next_second))
      |> Enum.take(23)
      |> Enum.count(fn {left, right} -> left != right end)

    assert historical_changes == 0
  end

  test "application configures a rotating file logger handler" do
    assert {:ok, handler_config} = :logger.get_handler_config(:rondo_disk_log)
    assert handler_config.module == :logger_disk_log_h

    disk_config = handler_config.config
    assert disk_config.type == :wrap
    assert is_list(disk_config.file)
    assert disk_config.max_no_bytes > 0
    assert disk_config.max_no_files > 0
  end

  test "status dashboard renders latest gate status in EVENT column" do
    row =
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-GATE",
          state: "In Progress",
          session_id: "session-gate-status",
          last_claude_event: :gates_completed,
          last_claude_message: %{event: :gates_completed},
          latest_gate: %{status: :fail, failed: [%{name: "unit", status: :fail, exit_status: 2}]},
          runtime_seconds: 12,
          turn_count: 1,
          claude_total_tokens: 42
        },
        140
      )

    assert row =~ "gates: fail unit"
  end

  test "status dashboard renders policy-blocked gate status distinctly" do
    row =
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-GATE-POLICY-BLOCKED",
          state: "In Progress",
          session_id: "session-gate-policy-blocked",
          last_claude_event: :gates_completed,
          last_claude_message: %{event: :gates_completed},
          latest_gate: %{status: :policy_blocked, failed: [%{name: "read", status: :policy_blocked}]},
          runtime_seconds: 12,
          turn_count: 1,
          claude_total_tokens: 42
        },
        140
      )

    assert row =~ "gates: policy_blocked read"
  end

  test "status dashboard renders reused gate status distinctly" do
    row =
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-GATE-REUSED",
          state: "In Progress",
          session_id: "session-gate-reused",
          last_claude_event: :gates_reused,
          last_claude_message: %{event: :gates_reused},
          latest_gate: %{status: :reused, results_path: "artifacts/gates/turn-0002/results.json"},
          runtime_seconds: 12,
          turn_count: 2,
          claude_total_tokens: 84
        },
        140
      )

    assert row =~ "gates: reused"
    assert row =~ IO.ANSI.light_black()
  end

  test "status dashboard labels pi runs as pi in the phase column" do
    rendered =
      StatusDashboard.format_running_summary_for_test(%{
        identifier: "MT-PI",
        state: "In Progress",
        adapter: "pi",
        session_id: "agent-session-123456",
        runtime_seconds: 15,
        turn_count: 1,
        claude_total_tokens: 42,
        last_claude_event: :assistant_message,
        last_claude_message: %{event: :assistant_message, message: "Working"}
      })

    plain = String.replace(rendered, ~r/\e\[[0-9;]*m/, "")
    assert plain =~ ~r/MT-PI\s+In Progress\s+pi\s+/
    assert plain =~ "Working"
    refute plain =~ "claude"
  end

  test "status dashboard renders last claude message in EVENT column" do
    row =
      StatusDashboard.format_running_summary_for_test(%{
        identifier: "MT-233",
        state: "running",
        session_id: "thread-1234567890",
        claude_session_id: "4242",
        claude_total_tokens: 12,
        runtime_seconds: 15,
        last_claude_event: :notification,
        last_claude_message: %{
          event: :notification,
          message: %{
            "method" => "turn/completed",
            "params" => %{"turn" => %{"status" => "completed"}}
          }
        }
      })

    plain = Regex.replace(~r/\e\[[\\d;]*m/, row, "")

    assert plain =~ "turn completed (completed)"
    assert (String.split(plain, "turn completed (completed)") |> length()) - 1 == 1
    refute plain =~ " notification "
  end

  test "status dashboard strips ANSI and control bytes from last claude message" do
    payload =
      "cmd: " <>
        <<27>> <>
        "[31mRED" <>
        <<27>> <>
        "[0m" <>
        <<0>> <>
        " after\nline"

    row =
      StatusDashboard.format_running_summary_for_test(%{
        identifier: "MT-898",
        state: "running",
        session_id: "thread-1234567890",
        claude_session_id: "4242",
        claude_total_tokens: 12,
        runtime_seconds: 15,
        last_claude_event: :notification,
        last_claude_message: payload
      })

    plain = Regex.replace(~r/\e\[[0-9;]*m/, row, "")

    assert plain =~ "cmd: RED after line"
    refute plain =~ <<27>>
    refute plain =~ <<0>>
  end

  test "status dashboard expands running row to requested terminal width" do
    terminal_columns = 140

    row =
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-598",
          state: "running",
          session_id: "thread-1234567890",
          claude_session_id: "4242",
          claude_total_tokens: 123,
          runtime_seconds: 15,
          last_claude_event: :notification,
          last_claude_message: %{
            event: :notification,
            message: %{
              "method" => "turn/completed",
              "params" => %{"turn" => %{"status" => "completed"}}
            }
          }
        },
        terminal_columns
      )

    plain = Regex.replace(~r/\e\[[\d;]*m/, row, "")

    assert String.length(plain) == terminal_columns
    assert plain =~ "turn completed (completed)"
  end

  test "status dashboard humanizes full claude event set" do
    event_cases = [
      {"turn/started", %{"params" => %{"turn" => %{"id" => "turn-1"}}}, "turn started"},
      {"turn/completed", %{"params" => %{"turn" => %{"status" => "completed"}}}, "turn completed"},
      {"turn/diff/updated", %{"params" => %{"diff" => "line1\nline2"}}, "turn diff updated"},
      {"turn/plan/updated", %{"params" => %{"plan" => [%{"step" => "a"}, %{"step" => "b"}]}}, "plan updated"},
      {"thread/tokenUsage/updated",
       %{
         "params" => %{
           "usage" => %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11}
         }
       }, "thread token usage updated"},
      {"item/started",
       %{
         "params" => %{
           "item" => %{
             "id" => "item-1234567890abcdef",
             "type" => "commandExecution",
             "status" => "running"
           }
         }
       }, "item started: command execution"},
      {"item/completed", %{"params" => %{"item" => %{"type" => "fileChange", "status" => "completed"}}}, "item completed: file change"},
      {"item/agentMessage/delta", %{"params" => %{"delta" => "hello"}}, "agent message streaming"},
      {"item/plan/delta", %{"params" => %{"delta" => "step"}}, "plan streaming"},
      {"item/reasoning/summaryTextDelta", %{"params" => %{"summaryText" => "thinking"}}, "reasoning summary streaming"},
      {"item/reasoning/summaryPartAdded", %{"params" => %{"summaryText" => "section"}}, "reasoning summary section added"},
      {"item/reasoning/textDelta", %{"params" => %{"textDelta" => "reason"}}, "reasoning text streaming"},
      {"item/commandExecution/outputDelta", %{"params" => %{"outputDelta" => "ok"}}, "command output streaming"},
      {"item/fileChange/outputDelta", %{"params" => %{"outputDelta" => "changed"}}, "file change output streaming"},
      {"item/commandExecution/requestApproval", %{"params" => %{"parsedCmd" => "git status"}}, "command approval requested (git status)"},
      {"item/fileChange/requestApproval", %{"params" => %{"fileChangeCount" => 2}}, "file change approval requested (2 files)"},
      {"item/tool/call", %{"params" => %{"tool" => "linear_graphql"}}, "dynamic tool call requested (linear_graphql)"},
      {"item/tool/requestUserInput", %{"params" => %{"question" => "Continue?"}}, "tool requires user input: Continue?"}
    ]

    Enum.each(event_cases, fn {method, payload, expected_fragment} ->
      message = Map.put(payload, "method", method)

      humanized =
        StatusDashboard.humanize_claude_message(%{event: :notification, message: message})

      assert humanized =~ expected_fragment
    end)
  end

  test "status dashboard humanizes dynamic tool wrapper events" do
    completed = %{
      event: :tool_call_completed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"name" => "linear_graphql"}}
      }
    }

    failed = %{
      event: :tool_call_failed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "linear_graphql"}}
      }
    }

    unsupported = %{
      event: :unsupported_tool_call,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "unknown_tool"}}
      }
    }

    assert StatusDashboard.humanize_claude_message(completed) =~
             "dynamic tool call completed (linear_graphql)"

    assert StatusDashboard.humanize_claude_message(failed) =~
             "dynamic tool call failed (linear_graphql)"

    assert StatusDashboard.humanize_claude_message(unsupported) =~
             "unsupported dynamic tool call rejected (unknown_tool)"
  end

  test "status dashboard unwraps nested claude payload envelopes" do
    wrapped = %{
      event: :notification,
      message: %{
        payload: %{
          "method" => "turn/completed",
          "params" => %{
            "turn" => %{"status" => "completed"},
            "usage" => %{"input_tokens" => "10", "output_tokens" => 2, "total_tokens" => 12}
          }
        },
        raw: "{\"method\":\"turn/completed\"}"
      }
    }

    assert StatusDashboard.humanize_claude_message(wrapped) =~ "turn completed"
    assert StatusDashboard.humanize_claude_message(wrapped) =~ "in 10"
  end

  test "status dashboard uses shell command line as exec command status text (legacy)" do
    message = %{
      event: :notification,
      message: %{
        "method" => "claude/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => "git status --short"}}
      }
    }

    assert StatusDashboard.humanize_claude_message(message) == "git status --short"
  end

  test "status dashboard formats auto-approval updates from claude" do
    message = %{
      event: :approval_auto_approved,
      message: %{
        payload: %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{"parsedCmd" => "mix test"}
        },
        decision: "acceptForSession"
      }
    }

    humanized = StatusDashboard.humanize_claude_message(message)
    assert humanized =~ "command approval requested"
    assert humanized =~ "auto-approved"
  end

  test "status dashboard formats auto-answered tool input updates from claude" do
    message = %{
      event: :tool_input_auto_answered,
      message: %{
        payload: %{
          "method" => "item/tool/requestUserInput",
          "params" => %{"question" => "Continue?"}
        },
        answer: "This is a non-interactive session. Operator input is unavailable."
      }
    }

    humanized = StatusDashboard.humanize_claude_message(message)
    assert humanized =~ "tool requires user input"
    assert humanized =~ "auto-answered"
  end

  test "status dashboard enriches wrapper reasoning and message streaming events with payload context" do
    reasoning_message = %{
      event: :notification,
      message: %{
        "method" => "claude/event/agent_reasoning",
        "params" => %{
          "msg" => %{
            "payload" => %{"summaryText" => "compare retry paths for Linear polling"}
          }
        }
      }
    }

    message_delta = %{
      event: :notification,
      message: %{
        "method" => "claude/event/agent_message_delta",
        "params" => %{
          "msg" => %{
            "payload" => %{"delta" => "writing workpad reconciliation update"}
          }
        }
      }
    }

    fallback_reasoning = %{
      event: :notification,
      message: %{
        "method" => "claude/event/agent_reasoning",
        "params" => %{"msg" => %{"payload" => %{}}}
      }
    }

    assert StatusDashboard.humanize_claude_message(reasoning_message) =~
             "reasoning update: compare retry paths for Linear polling"

    assert StatusDashboard.humanize_claude_message(message_delta) =~
             "agent message streaming: writing workpad reconciliation update"

    assert StatusDashboard.humanize_claude_message(fallback_reasoning) == "reasoning update"
  end

  test "application stop renders offline status" do
    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Rondo.Application.stop(:normal)
      end)

    assert rendered =~ "app_status=offline"
    refute rendered =~ "Timestamp:"
  end

  defp wait_for_snapshot(pid, predicate, timeout_ms \\ 200) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_snapshot(pid, predicate, deadline_ms)
  end

  defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if predicate.(snapshot) do
      snapshot
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator snapshot state: #{inspect(snapshot)}")
      else
        Process.sleep(5)
        do_wait_for_snapshot(pid, predicate, deadline_ms)
      end
    end
  end

  defp graph_samples_from_rates(rates_per_bucket) do
    bucket_ms = 25_000

    {timestamp, tokens, samples} =
      Enum.reduce(rates_per_bucket, {0, 0, []}, fn rate, {timestamp, tokens, acc} ->
        next_timestamp = timestamp + bucket_ms
        next_tokens = tokens + trunc(rate * bucket_ms / 1000)
        {next_timestamp, next_tokens, [{timestamp, tokens} | acc]}
      end)

    {tokens, [{timestamp, tokens} | samples]}
  end

  test "orchestrator accumulates per-message usage across multiple assistant events" do
    issue_id = "issue-multi-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-MULTI",
      title: "Multi-event usage test",
      state: "In Progress",
      url: "https://example.org/issues/MT-MULTI"
    }

    orchestrator_name = Module.concat(__MODULE__, :MultiUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    # First assistant event: 1000 input, 500 output
    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :assistant,
         usage: %{input_tokens: 1000, output_tokens: 500, total_tokens: 1500},
         timestamp: now
       }}
    )

    # Second assistant event: 800 input, 300 output (LOWER than first -- per-message, not cumulative)
    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :assistant,
         usage: %{input_tokens: 800, output_tokens: 300, total_tokens: 1100},
         timestamp: now
       }}
    )

    # Third assistant event: 1200 input, 600 output
    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :assistant,
         usage: %{input_tokens: 1200, output_tokens: 600, total_tokens: 1800},
         timestamp: now
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [entry]} = snapshot

    # All three events should accumulate: 1000+800+1200=3000 input, 500+300+600=1400 output
    assert entry.claude_input_tokens == 3000
    assert entry.claude_output_tokens == 1400
    assert entry.claude_total_tokens == 4400
  end

  test "dashboard output does not contain a Rate Limits line" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0, 115)
    refute rendered =~ "Rate Limit"
  end

  defp graph_samples_for_stability_test(now_ms) do
    rates_per_bucket = Enum.map(1..24, &(&1 * 5))
    bucket_ms = 25_000

    rate_for_timestamp = fn timestamp ->
      bucket_idx = min(div(max(timestamp, 0), bucket_ms), 23)
      Enum.at(rates_per_bucket, bucket_idx, 0)
    end

    0..(now_ms - 1_000)//1_000
    |> Enum.reduce({0, []}, fn timestamp, {tokens, acc} ->
      next_tokens = tokens + rate_for_timestamp.(timestamp)
      {next_tokens, [{timestamp, next_tokens} | acc]}
    end)
    |> elem(1)
  end

  test "snapshot includes event_log from claude updates" do
    issue_id = "issue-event-log"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-301",
      title: "Event log test",
      description: "Verify event log accumulates",
      state: "In Progress",
      url: "https://example.org/issues/MT-301"
    }

    orchestrator_name = Module.concat(__MODULE__, :EventLogOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at,
      event_log: []
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(pid, {:claude_worker_update, issue_id, %{event: :session_started, session_id: "sess-1", timestamp: now}})
    send(pid, {:claude_worker_update, issue_id, %{event: :unknown, raw: %{}, timestamp: now}})
    send(pid, {:claude_worker_update, issue_id, %{event: :assistant, raw: %{}, timestamp: now}})
    send(pid, {:claude_worker_update, issue_id, %{event: :notification, payload: %{method: "tool_use"}, timestamp: now}})

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :assistant,
         raw: %{"message" => %{"content" => [%{"type" => "text", "text" => "hello world"}]}},
         timestamp: now
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [entry]} = snapshot
    assert is_list(entry.event_log)
    # :unknown and empty :assistant events are filtered out
    assert length(entry.event_log) == 3

    # event_log is stored newest-first (prepended); presenter reverses for display
    [newest, middle, oldest] = entry.event_log
    assert oldest.event == :session_started
    assert middle.event == :notification
    assert newest.event == :assistant
    assert newest.message == "hello world"
  end

  test "snapshot includes meaningful event_log from pi v3 events" do
    issue_id = "issue-pi-event-log"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-PI-LOG",
      title: "Pi event log test",
      description: "Verify pi events are observable",
      state: "In Progress",
      url: "https://example.org/issues/MT-PI-LOG"
    }

    orchestrator_name = Module.concat(__MODULE__, :PiEventLogOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 0,
      claude_output_tokens: 0,
      claude_total_tokens: 0,
      claude_last_reported_input_tokens: 0,
      claude_last_reported_output_tokens: 0,
      claude_last_reported_total_tokens: 0,
      started_at: started_at,
      event_log: []
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:claude_worker_update, issue_id, %{event: :session_started, adapter: "pi", session_id: "pi-sess", timestamp: now}}
    )

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :assistant_message,
         adapter: "pi",
         message: "Working from pi",
         raw: %{"type" => "message", "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "Working from pi"}]}},
         timestamp: now
       }}
    )

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :tool_started,
         adapter: "pi",
         message: "bash: command=mix test",
         raw: %{"type" => "message", "message" => %{"role" => "assistant", "content" => [%{"type" => "toolCall", "name" => "bash", "arguments" => %{"command" => "mix test"}}]}},
         timestamp: now
       }}
    )

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :tool_completed,
         adapter: "pi",
         message: "bash: ok",
         raw: %{"type" => "message", "message" => %{"role" => "toolResult", "toolName" => "bash", "content" => [%{"type" => "text", "text" => "ok"}]}},
         timestamp: now
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [entry]} = snapshot

    assert [newest, tool_started, assistant, oldest] = entry.event_log
    assert oldest.event == :session_started
    assert assistant.event == :assistant
    assert assistant.message == "Working from pi"
    assert tool_started.event == :bash
    assert tool_started.message == "bash: command=mix test"
    assert newest.event == :bash
    assert newest.message == "bash: ok"
  end

  test "dispatch creates run ledger and exposes it in running snapshot" do
    workspace_root = tmp_dir("orchestrator-ledger-dispatch")
    claude_bin = fake_claude_script(workspace_root, "ledger-session", 1)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: claude_bin,
      max_turns: 1
    )

    issue = %Issue{
      id: "issue-ledger-dispatch",
      identifier: "MT-LEDGER",
      title: "Ledger dispatch test",
      description: "Create a run ledger",
      state: "Todo",
      url: "https://example.org/issues/MT-LEDGER"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :LedgerDispatchOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    state = :sys.get_state(pid)
    state = %{state | max_concurrent_agents: 1, poll_interval_ms: 60_000}
    :sys.replace_state(pid, fn _ -> state end)

    send(pid, {:tick, state.tick_token})

    snapshot_entry =
      wait_until(fn ->
        case GenServer.call(pid, :snapshot).running do
          [entry | _] -> entry
          _ -> nil
        end
      end)

    assert snapshot_entry.run_id =~ "MT-LEDGER-"
    assert snapshot_entry.run_dir =~ Path.join([workspace_root, ".rondo_runs", "MT-LEDGER"])
    assert File.exists?(Path.join(snapshot_entry.run_dir, "manifest.json"))
  end

  test "claude worker updates append run ledger artifacts and checkpoints" do
    workspace_root = tmp_dir("orchestrator-ledger-updates")
    issue_id = "issue-ledger-update"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-LEDGER-UPD",
      title: "Ledger update test",
      description: "Capture worker updates",
      state: "In Progress",
      url: "https://example.org/issues/MT-LEDGER-UPD"
    }

    assert {:ok, ledger} = Rondo.RunLedger.create_run(issue, workspace_root: workspace_root, random_suffix: "feedface")

    orchestrator_name = Module.concat(__MODULE__, :LedgerUpdateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      started_at: DateTime.utc_now(),
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      ledger: ledger
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :assistant,
         session_id: "session-ledger-update",
         timestamp: DateTime.utc_now(),
         raw: %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "completed"}}}
       }}
    )

    checkpoint_index =
      wait_until(fn ->
        manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
        Enum.find(manifest["checkpoints"], &(&1["kind"] == "turn_completed"))
      end)

    checkpoint = ledger.run_dir |> Path.join(checkpoint_index["path"]) |> File.read!() |> Jason.decode!()
    assert checkpoint["source"] == %{"adapter" => "claude_code", "event" => "turn/completed"}

    artifact_path = Path.join(ledger.run_dir, "artifacts/agent-events.ndjson")
    assert File.read!(artifact_path) =~ "turn/completed"
  end

  test "orchestrator retries and marks run ledger failed when configured gates fail" do
    workspace_root = tmp_dir("orchestrator-gate-failure-retry")
    claude_bin = fake_claude_script(workspace_root, "gate-failure-session", 0)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: claude_bin,
      max_turns: 1,
      action_policy_command: fake_action_policy_script(workspace_root, "allow"),
      gates: [%{name: "proof", command: "echo nope; exit 3", timeout_ms: 1_000}]
    )

    issue = %Issue{
      id: "issue-orchestrator-gate-failure",
      identifier: "MT-GATE-FAIL-ORCH",
      title: "Gate failure retry test",
      description: "Fail a configured gate in orchestrator path",
      state: "Todo",
      url: "https://example.org/issues/MT-GATE-FAIL-ORCH"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :GateFailureRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    state = :sys.get_state(pid)
    state = %{state | max_concurrent_agents: 1, poll_interval_ms: 60_000}
    :sys.replace_state(pid, fn _ -> state end)

    send(pid, {:tick, state.tick_token})

    retry_entry =
      wait_until(fn ->
        case GenServer.call(pid, :snapshot).retrying do
          [entry | _] -> entry
          _ -> nil
        end
      end)

    assert retry_entry.identifier == "MT-GATE-FAIL-ORCH"
    assert retry_entry.attempt == 1
    assert retry_entry.error =~ "agent exited:"
    assert retry_entry.error =~ "gate_failed"

    archived_entry =
      wait_until(fn ->
        case GenServer.call(pid, :snapshot).archived do
          [entry | _] -> entry
          _ -> nil
        end
      end)

    assert archived_entry.exit_reason =~ "gate_failed"
    assert archived_entry.latest_gate.status == :fail

    manifest =
      [workspace_root, ".rondo_runs", "MT-GATE-FAIL-ORCH", "*", "manifest.json"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> File.read!() |> Jason.decode!() end)
      |> Enum.find(&(&1["status"] == "failed"))

    assert manifest
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "gates_completed"))
    assert Enum.any?(manifest["artifacts"], &(&1["kind"] == "gate_results"))

    run_decision_checkpoint = Enum.find(manifest["checkpoints"], &(&1["kind"] == "run_decision"))
    assert run_decision_checkpoint

    run_decision =
      Path.join(manifest["run_dir"], run_decision_checkpoint["path"])
      |> File.read!()
      |> Jason.decode!()

    assert run_decision["payload"]["decision_kind"] == "retry"
    assert run_decision["payload"]["reason_code"] == "gate_failed"
  end

  test "orchestrator pauses instead of retrying after a second gate failure" do
    workspace_root = tmp_dir("orchestrator-gate-failure-pause")
    claude_bin = fake_claude_script(workspace_root, "gate-pause-session", 0)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: claude_bin,
      max_turns: 1,
      action_policy_command: fake_action_policy_script(workspace_root, "allow"),
      gates: [%{name: "proof", command: "echo nope; exit 3", timeout_ms: 1_000}]
    )

    issue = %Issue{
      id: "issue-orchestrator-gate-pause",
      identifier: "MT-GATE-PAUSE",
      title: "Gate failure pause test",
      description: "Pause after repeated configured gate failures",
      state: "Todo",
      url: "https://example.org/issues/MT-GATE-PAUSE"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :GateFailurePauseOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    state = :sys.get_state(pid)
    state = %{state | max_concurrent_agents: 1, poll_interval_ms: 60_000}
    :sys.replace_state(pid, fn _ -> state end)

    send(pid, {:tick, state.tick_token})

    retry_entry =
      wait_until(fn ->
        case :sys.get_state(pid).retry_attempts do
          %{"issue-orchestrator-gate-pause" => entry} -> entry
          _ -> nil
        end
      end)

    assert retry_entry.attempt == 1
    assert retry_entry.failure_reason == :gate_failed

    send(pid, {:retry_issue, issue.id, retry_entry.retry_token})

    paused_entry =
      wait_until(fn ->
        case GenServer.call(pid, :snapshot).paused do
          [entry | _] -> entry
          _ -> nil
        end
      end)

    assert paused_entry.issue_id == issue.id
    assert paused_entry.identifier == "MT-GATE-PAUSE"
    assert paused_entry.interrupt["reason"] == "repeated_gate_failure"
    assert paused_entry.interrupt["gate"]["status"] == "fail"
    assert paused_entry.interrupt["resume"]["retry_attempt"] == 1
    assert paused_entry.interrupt["resume"]["session_id"] == "gate-pause-session"

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.retrying == []
    assert snapshot.archived |> Enum.count(&(&1.identifier == "MT-GATE-PAUSE")) == 1

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue.id)
    assert MapSet.member?(state.claimed, issue.id)
    assert %Rondo.RunLedger{} = state.paused_interrupts[issue.id].ledger
    assert state.paused_interrupts[issue.id].ledger.run_id == paused_entry.run_id
    assert state.paused_interrupts[issue.id].ledger.run_dir == paused_entry.run_dir

    paused_manifest =
      [workspace_root, ".rondo_runs", "MT-GATE-PAUSE", "*", "manifest.json"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> File.read!() |> Jason.decode!() end)
      |> Enum.find(&(&1["status"] == "paused"))

    assert paused_manifest
    assert Enum.any?(paused_manifest["checkpoints"], &(&1["kind"] == "interrupt_created"))

    run_decision_checkpoint = Enum.find(paused_manifest["checkpoints"], &(&1["kind"] == "run_decision"))
    assert run_decision_checkpoint

    run_decision =
      Path.join(paused_manifest["run_dir"], run_decision_checkpoint["path"])
      |> File.read!()
      |> Jason.decode!()

    assert run_decision["payload"]["decision_kind"] == "pause"
    assert run_decision["payload"]["reason_code"] == "repeated_gate_failure"
  end

  test "orchestrator loads paused ledgers on startup and exposes tracker-state mismatches" do
    workspace_root = tmp_dir("orchestrator-paused-startup")
    claude_bin = fake_claude_script(workspace_root, "paused-startup-session", 0)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: claude_bin,
      max_turns: 1
    )

    issue = %Issue{
      id: "issue-paused-startup",
      identifier: "MT-PAUSED-STARTUP",
      title: "Paused startup test",
      description: "Load paused ledger on orchestrator init",
      state: "In Progress",
      url: "https://example.org/issues/MT-PAUSED-STARTUP"
    }

    assert {:ok, ledger} = Rondo.RunLedger.create_run(issue, workspace_root: workspace_root, random_suffix: "5eeded00")

    interrupt =
      Rondo.Interrupt.repeated_gate_failure(%{
        issue: issue,
        gate: %{status: :fail, results_path: "artifacts/gates/turn-0002/results.json"},
        run_id: ledger.run_id,
        run_dir: ledger.run_dir,
        workspace: Path.join(workspace_root, issue.identifier),
        session_id: "paused-startup-session",
        retry_attempt: 1,
        model_routing_context: %{skill: "review-response", phase: "fix", stage: :turn},
        timestamp: ~U[2026-05-28 10:00:00Z]
      })

    assert {:ok, _ledger} = Rondo.RunLedger.pause_run(ledger, interrupt, timestamp: ~U[2026-05-28 10:00:00Z])

    Application.put_env(:rondo, :memory_tracker_issues, [%{issue | state: "Todo"}])

    orchestrator_name = Module.concat(__MODULE__, :PausedStartupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    state = :sys.get_state(pid)
    assert state.paused_interrupts[issue.id].model_routing_context == %{"skill" => "review-response", "phase" => "fix", "stage" => "turn"}
    assert MapSet.member?(state.claimed, issue.id)
    assert %Rondo.RunLedger{} = state.paused_interrupts[issue.id].ledger
    assert state.paused_interrupts[issue.id].ledger.run_id == ledger.run_id
    assert state.paused_interrupts[issue.id].ledger.run_dir == ledger.run_dir
    assert state.paused_interrupts[issue.id].ledger.next_seq == 2

    send(pid, {:tick, state.tick_token})

    paused_entry =
      wait_until(fn ->
        case GenServer.call(pid, :snapshot).paused do
          [
            %{
              issue_id: "issue-paused-startup",
              identifier: "MT-PAUSED-STARTUP",
              state: "Todo",
              paused_state: "In Progress",
              tracker_state: "Todo",
              tracker_state_mismatch: true
            } = paused_entry
          ] ->
            paused_entry

          _ ->
            nil
        end
      end)

    assert paused_entry.interrupt["reason"] == "repeated_gate_failure"
    assert paused_entry.tracker_visibility == "known"
    assert paused_entry.blocks_dispatch == true

    state = :sys.get_state(pid)
    assert state.running == %{}
    assert Map.has_key?(state.paused_interrupts, issue.id)
  end

  test "gate worker updates append run ledger checkpoints and artifacts" do
    workspace_root = tmp_dir("orchestrator-ledger-gates")
    issue_id = "issue-ledger-gates"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-LEDGER-GATES",
      title: "Ledger gate test",
      description: "Capture gate updates",
      state: "In Progress",
      url: "https://example.org/issues/MT-LEDGER-GATES"
    }

    assert {:ok, ledger} = Rondo.RunLedger.create_run(issue, workspace_root: workspace_root, random_suffix: "decafbad")

    orchestrator_name = Module.concat(__MODULE__, :LedgerGateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      started_at: DateTime.utc_now(),
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      ledger: ledger
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :gates_completed,
         timestamp: DateTime.utc_now(),
         raw: %{
           status: :fail,
           results_path: "artifacts/gates/results.json",
           results: [
             %{
               name: "unit",
               status: :fail,
               exit_status: 2,
               stdout_path: "artifacts/gates/unit-stdout.log",
               stderr_path: "artifacts/gates/unit-stderr.log"
             }
           ]
         }
       }}
    )

    manifest =
      wait_until(fn ->
        manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()

        if Enum.any?(manifest["checkpoints"], &(&1["kind"] == "gates_completed")) do
          manifest
        end
      end)

    assert Enum.any?(manifest["artifacts"], &(&1["kind"] == "gate_results"))
    assert Enum.any?(manifest["artifacts"], &(&1["kind"] == "gate_stdout" and &1["name"] == "unit"))

    send(
      pid,
      {:claude_worker_update, issue_id,
       %{
         event: :gates_reused,
         timestamp: DateTime.utc_now(),
         raw: %{
           status: :reused,
           results_path: "artifacts/gates/turn-0002/results.json",
           state_path: "artifacts/gates/state.json",
           workspace_identity: %{head: "abc123", tree_hash: "def456"},
           gate_signature: "gate-sig",
           reused_from: %{status: :pass, results_path: "artifacts/gates/results.json"},
           results: []
         }
       }}
    )

    reused_manifest =
      wait_until(fn ->
        manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()

        if Enum.any?(manifest["checkpoints"], &(&1["kind"] == "gates_reused")) and
             Enum.any?(manifest["artifacts"], &(&1["kind"] == "gate_state")) do
          manifest
        end
      end)

    assert Enum.any?(reused_manifest["artifacts"], &(&1["kind"] == "gate_results" and &1["path"] == "artifacts/gates/turn-0002/results.json"))
    assert Enum.any?(reused_manifest["artifacts"], &(&1["kind"] == "gate_state" and &1["path"] == "artifacts/gates/state.json"))

    [snapshot_entry] = GenServer.call(pid, :snapshot).running
    assert snapshot_entry.latest_gate.status == :reused
  end

  test "orchestrator shutdown marks active run ledgers terminated" do
    workspace_root = tmp_dir("orchestrator-ledger-shutdown")
    issue_id = "issue-ledger-shutdown"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-LEDGER-STOP",
      title: "Ledger shutdown test",
      description: "Terminate active ledger",
      state: "In Progress",
      url: "https://example.org/issues/MT-LEDGER-STOP"
    }

    assert {:ok, ledger} = Rondo.RunLedger.create_run(issue, workspace_root: workspace_root, random_suffix: "5a5a5a5a")

    orchestrator_name = Module.concat(__MODULE__, :LedgerShutdownOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    worker = spawn(fn -> Process.sleep(:infinity) end)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "session-ledger-shutdown",
      turn_count: 3,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      started_at: DateTime.utc_now(),
      event_log: [],
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      ledger: ledger
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    GenServer.stop(pid, :normal)

    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
    assert manifest["status"] == "terminated"
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "terminated"))

    run_decision_checkpoint = Enum.find(manifest["checkpoints"], &(&1["kind"] == "run_decision"))
    assert run_decision_checkpoint

    run_decision =
      Path.join(manifest["run_dir"], run_decision_checkpoint["path"])
      |> File.read!()
      |> Jason.decode!()

    assert run_decision["payload"]["decision_kind"] == "terminate"
    assert run_decision["payload"]["reason_code"] == "orchestrator_shutdown"
  end

  test "completed agent runs complete ledger and link existing archive" do
    workspace_root = tmp_dir("orchestrator-ledger-complete")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    issue_id = "issue-ledger-complete"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-LEDGER-DONE",
      title: "Ledger completion test",
      description: "Finish the ledger",
      state: "In Progress",
      url: "https://example.org/issues/MT-LEDGER-DONE"
    }

    assert {:ok, ledger} = Rondo.RunLedger.create_run(issue, workspace_root: workspace_root, random_suffix: "cafebabe")

    orchestrator_name = Module.concat(__MODULE__, :LedgerCompleteOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    initial_state = :sys.get_state(pid)
    ref = make_ref()

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: "session-ledger-complete",
      turn_count: 1,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      started_at: DateTime.utc_now(),
      event_log: [],
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      ledger: ledger
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    manifest =
      wait_until(fn ->
        manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()

        if manifest["status"] == "completed" and Enum.any?(manifest["artifacts"], &(&1["kind"] == "archive")) do
          manifest
        end
      end)

    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "completed"))
    assert Enum.any?(manifest["artifacts"], &(&1["kind"] == "archive"))
  end

  test "dispatch transitions todo issue to in progress via tracker" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-todo-transition",
      identifier: "MT-302",
      title: "Transition test",
      description: "Should move to In Progress",
      state: "Todo",
      url: "https://example.org/issues/MT-302"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])
    Application.put_env(:rondo, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :TransitionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_recipient)
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)

    state_with_dispatch =
      initial_state
      |> Map.put(:max_concurrent_agents, 1)
      |> Map.put(:poll_interval_ms, 60_000)

    :sys.replace_state(pid, fn _ -> state_with_dispatch end)

    # Trigger a poll by sending the tick message
    send(pid, {:tick, state_with_dispatch.tick_token})

    assert_receive {:memory_tracker_state_update, "issue-todo-transition", "In Progress"}, 10_000
  end

  test "dispatch pauses as needs guidance when tracker transition policy asks" do
    workspace_root = tmp_dir("orchestrator-transition-policy-ask")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: fake_claude_script(workspace_root, "transition-policy-ask-session", 0),
      action_policy_command: fake_action_policy_script(workspace_root, "ask")
    )

    issue = %Issue{
      id: "issue-transition-ask",
      identifier: "MT-POLICY-ASK",
      title: "Transition ask test",
      description: "Should pause before transition",
      state: "Todo",
      url: "https://example.org/issues/MT-POLICY-ASK"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])
    Application.put_env(:rondo, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :TransitionPolicyAskOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_recipient)
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    state = :sys.get_state(pid)
    state = %{state | max_concurrent_agents: 1, poll_interval_ms: 60_000}
    :sys.replace_state(pid, fn _ -> state end)

    send(pid, {:tick, state.tick_token})
    Process.sleep(4_000)

    paused_entry =
      case GenServer.call(pid, :snapshot, 15_000).paused do
        [entry | _] -> entry
        _ -> flunk("timed out waiting for paused entry")
      end

    assert paused_entry.issue_id == "issue-transition-ask"
    paused_state = :sys.get_state(pid)
    assert %Rondo.RunLedger{} = paused_state.paused_interrupts["issue-transition-ask"].ledger
    assert paused_state.paused_interrupts["issue-transition-ask"].ledger.run_id == paused_entry.run_id
    assert paused_state.paused_interrupts["issue-transition-ask"].ledger.run_dir == paused_entry.run_dir
    assert paused_entry.interrupt["reason"] == "action_policy_guidance_required"
    assert paused_entry.interrupt["blocked_side_effect"]["label"] == "Tracker update"
    assert paused_entry.interrupt["suggested_responses"] |> Enum.any?(&(&1["id"] == "approve_once"))

    manifest = paused_entry.run_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "action_policy_decision"))
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "interrupt_created"))

    refute_receive {:memory_tracker_state_update, "issue-transition-ask", "In Progress"}, 100
    assert GenServer.call(pid, :snapshot).running == []
    File.mkdir_p!(Path.join(workspace_root, "MT-POLICY-ASK"))

    assert {:ok, %{status: :resumed}} = Orchestrator.submit_guidance(orchestrator_name, "issue-transition-ask", "approve_once")
    assert_receive {:memory_tracker_state_update, "issue-transition-ask", "In Progress"}, 10_000

    # The resume path can finish before a transient running snapshot becomes visible under load,
    # so assert the durable post-resume ledger artifact updates instead of the fleeting running phase.
    resumed_manifest =
      wait_until(fn ->
        manifest = paused_entry.run_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

        if Enum.any?(manifest["checkpoints"], &(&1["kind"] == "guidance_submitted")) and
             Enum.any?(manifest["checkpoints"], &(&1["kind"] == "spawned")) do
          manifest
        else
          nil
        end
      end)

    assert Enum.any?(resumed_manifest["checkpoints"], &(&1["kind"] == "guidance_submitted"))
    assert Enum.any?(resumed_manifest["checkpoints"], &(&1["kind"] == "spawned"))
  end

  test "review-state issues with no PR evidence move back to rework and start an agent" do
    workspace_root = tmp_dir("orchestrator-review-state-rework")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      release_loop_enabled: true,
      release_loop_rework_state: "In Progress",
      tracker_review_states: ["In Review"],
      claude_command: fake_claude_script(workspace_root, "review-state-rework-session", 1)
    )

    assert Config.tracker_review_states() == ["In Review"]
    assert Config.release_loop_enabled?() == true

    issue = %Issue{
      id: "issue-review-rework",
      identifier: "MT-REVIEW-REWORK",
      title: "Review rework test",
      description: "Should resume implementation when the PR is missing",
      state: "In Review",
      branch_name: nil,
      url: "https://example.org/issues/MT-REVIEW-REWORK"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])
    Application.put_env(:rondo, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :ReviewStateReworkOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_recipient)
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    state = :sys.get_state(pid)
    state = %{state | max_concurrent_agents: 1, poll_interval_ms: 60_000}
    :sys.replace_state(pid, fn _ -> state end)

    send(pid, {:tick, state.tick_token})

    assert_receive {:memory_tracker_state_update, "issue-review-rework", "In Progress"}, 10_000

    wait_until(fn ->
      case GenServer.call(pid, :snapshot) do
        %{running: [%{issue_id: "issue-review-rework"} | _], retrying: []} -> true
        _ -> nil
      end
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert Enum.any?(snapshot.running, &(&1.issue_id == "issue-review-rework"))
    assert snapshot.retrying == []

    [running_entry] = Enum.filter(snapshot.running, &(&1.issue_id == "issue-review-rework"))
    manifest = running_entry.run_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    checkpoint_kinds = Enum.map(manifest["checkpoints"], & &1["kind"])

    assert "release_loop_pr_missing" in checkpoint_kinds
    assert "release_loop_action_selected" in checkpoint_kinds

    action_checkpoint_path =
      manifest["checkpoints"]
      |> Enum.find(&(&1["kind"] == "release_loop_action_selected"))
      |> Map.fetch!("path")

    action_checkpoint =
      running_entry.run_dir
      |> Path.join(action_checkpoint_path)
      |> File.read!()
      |> Jason.decode!()

    assert action_checkpoint["payload"]["action"] == "rework"

    state_after = :sys.get_state(pid)
    assert MapSet.member?(state_after.claimed, issue.id)
  end

  test "review-state retries expose release-loop lifecycle metadata" do
    workspace_root = tmp_dir("orchestrator-review-state-metadata")

    pr =
      %{
        number: 15,
        url: "https://github.com/sandsower/rondo/pull/15",
        title: "Review wait",
        state: "OPEN",
        headRefName: "feature/review-wait",
        baseRefName: "main",
        isDraft: false,
        mergeable: "MERGEABLE",
        mergeStateStatus: "CLEAN",
        reviewDecision: "APPROVED"
      }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      release_loop_enabled: true
    )

    issue = %Issue{
      id: "issue-review-metadata",
      identifier: "MT-REVIEW-META",
      title: "Review metadata test",
      description: "Should surface PR lifecycle metadata in the retry queue",
      state: "In Review",
      branch_name: "feature/review-wait",
      url: "https://example.org/issues/MT-REVIEW-META"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])
    Application.put_env(:rondo, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :ReviewStateMetadataOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_recipient)
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    state = :sys.get_state(pid)

    retry_entry = %{
      attempt: 2,
      due_at_ms: System.monotonic_time(:millisecond) + 60_000,
      identifier: issue.identifier,
      error: "release loop waiting for PR checks",
      delay_type: :release_loop_wait,
      release_loop: %{
        phase: :wait,
        pr: %{number: pr.number, url: pr.url},
        wait_interval_seconds: 9,
        blocked_reason: :checks_pending
      }
    }

    :sys.replace_state(pid, fn _ -> %{state | retry_attempts: %{issue.id => retry_entry}} end)

    snapshot = GenServer.call(pid, :snapshot)
    [retry] = Enum.filter(snapshot.retrying, &(&1.issue_id == issue.id))
    assert retry.error =~ "release loop waiting for PR checks"
    assert retry.delay_type == :release_loop_wait
    assert get_in(retry, [:release_loop, :phase]) == :wait
    assert get_in(retry, [:release_loop, :pr, :url]) == pr.url
    assert get_in(retry, [:release_loop, :pr, :number]) == 15
  end

  test "freeform guidance resumes paused run with operator prompt and previous run ref" do
    workspace_root = tmp_dir("orchestrator-operator-guidance-resume")
    trace_file = Path.join(workspace_root, "claude-resume.trace")
    claude_script = Path.join(workspace_root, "fake-claude-guidance.sh")

    File.write!(claude_script, """
    #!/bin/sh
    printf '%s\n' "$@" > #{trace_file}
    echo '{"type":"system","subtype":"init","session_id":"operator-session","tools":[]}'
    echo '{"type":"result","subtype":"success","session_id":"operator-session","usage":{"input_tokens":1,"output_tokens":1}}'
    """)

    File.chmod!(claude_script, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: claude_script,
      max_turns: 1
    )

    issue = %Issue{
      id: "issue-operator-guidance",
      identifier: "MT-OP-GUIDE",
      title: "Operator guidance test",
      description: "Should resume with operator guidance",
      state: "In Progress",
      url: "https://example.org/issues/MT-OP-GUIDE"
    }

    # Keep the tracker empty until the paused claim is injected so startup cannot
    # race this resume-path test by dispatching a fresh run first.
    Application.put_env(:rondo, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :OperatorGuidanceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    paused_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      state: issue.state,
      session_id: "paused-session",
      run_id: "run-paused",
      run_dir: nil,
      workspace: Path.join(workspace_root, issue.identifier),
      paused_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      retry_attempt: 1,
      latest_gate: nil,
      interrupt: %{
        "reason" => "repeated_gate_failure",
        "resume" => %{
          "run_ref" => %{
            "adapter" => "claude_code",
            "provider_ref" => "paused-session",
            "provider_ref_kind" => "session_id",
            "resumable?" => true
          }
        }
      },
      tracker_visibility: "known",
      ledger: nil
    }

    :sys.replace_state(pid, fn state ->
      %{state | paused_interrupts: %{issue.id => paused_entry}, claimed: MapSet.new([issue.id])}
    end)

    Application.put_env(:rondo, :memory_tracker_issues, [issue])

    assert {:ok, %{status: :resumed}} =
             Orchestrator.submit_guidance(orchestrator_name, issue.id, "Please reuse the existing fix and add the missing regression test.")

    trace =
      wait_until(fn ->
        if File.exists?(trace_file), do: File.read!(trace_file)
      end)

    assert trace =~ "--resume\npaused-session"
    assert trace =~ "Operator guidance for paused run"
    assert trace =~ "Please reuse the existing fix and add the missing regression test."
    assert GenServer.call(pid, :snapshot).paused == []
  end

  test "freeform guidance rejects non-resumable paused run refs" do
    workspace_root = tmp_dir("orchestrator-operator-guidance-nonresumable")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: fake_claude_script(workspace_root, "nonresumable-session", 0),
      max_turns: 1
    )

    issue = %Issue{
      id: "issue-nonresumable-guidance",
      identifier: "MT-NONRESUME-GUIDE",
      title: "Non-resumable guidance test",
      description: "Should not resume non-resumable refs",
      state: "In Progress",
      url: "https://example.org/issues/MT-NONRESUME-GUIDE"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :NonResumableGuidanceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    paused_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      state: issue.state,
      session_id: "paused-session",
      run_id: "run-paused",
      run_dir: nil,
      workspace: Path.join(workspace_root, issue.identifier),
      paused_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      retry_attempt: 1,
      latest_gate: nil,
      interrupt: %{
        "reason" => "repeated_gate_failure",
        "resume" => %{
          "run_ref" => %{
            adapter: "claude_code",
            provider_ref: "paused-session",
            provider_ref_kind: "session_id",
            resumable?: false
          }
        }
      },
      tracker_visibility: "known",
      ledger: nil
    }

    :sys.replace_state(pid, fn state ->
      %{state | paused_interrupts: %{issue.id => paused_entry}, claimed: MapSet.new([issue.id])}
    end)

    assert {:error, {:guidance_resume_failed, :resume_ref_not_resumable}} =
             Orchestrator.submit_guidance(orchestrator_name, issue.id, "Please continue.")

    assert [%{issue_id: "issue-nonresumable-guidance"}] = GenServer.call(pid, :snapshot).paused
    assert GenServer.call(pid, :snapshot).running == []
  end

  test "approve_once guidance revalidates tracker transition before resume" do
    workspace_root = tmp_dir("orchestrator-transition-policy-stale")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: fake_claude_script(workspace_root, "transition-policy-stale-session", 0),
      action_policy_command: fake_action_policy_script(workspace_root, "ask")
    )

    issue = %Issue{
      id: "issue-transition-stale",
      identifier: "MT-POLICY-STALE",
      title: "Transition stale test",
      description: "Should not resume stale transition",
      state: "Todo",
      url: "https://example.org/issues/MT-POLICY-STALE"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])
    Application.put_env(:rondo, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :TransitionPolicyStaleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_recipient)
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    state = :sys.get_state(pid)
    state = %{state | max_concurrent_agents: 1, poll_interval_ms: 60_000}
    :sys.replace_state(pid, fn _ -> state end)

    send(pid, {:tick, state.tick_token})

    wait_until(fn ->
      case GenServer.call(pid, :snapshot).paused do
        [_entry | _] -> true
        _ -> nil
      end
    end)

    Application.put_env(:rondo, :memory_tracker_issues, [%{issue | state: "Done"}])

    assert {:error, {:guidance_side_effect_failed, :guidance_issue_not_todo}} =
             Orchestrator.submit_guidance(orchestrator_name, "issue-transition-stale", "approve_once")

    refute_receive {:memory_tracker_state_update, "issue-transition-stale", "In Progress"}, 100
    assert [%{issue_id: "issue-transition-stale"}] = GenServer.call(pid, :snapshot).paused
    assert GenServer.call(pid, :snapshot).running == []
  end

  test "retry polling releases terminal issues without relaunching" do
    workspace_root = tmp_dir("orchestrator-retry-terminal")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: fake_claude_script(workspace_root, "retry-terminal-session", 0),
      action_policy_command: fake_action_policy_script(workspace_root, "allow")
    )

    issue = %Issue{
      id: "issue-retry-terminal",
      identifier: "MT-RETRY-TERMINAL",
      title: "Retry terminal test",
      description: "Retry polling should release terminal issues",
      state: "Done",
      url: "https://example.org/issues/MT-RETRY-TERMINAL"
    }

    workspace = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(workspace)

    Application.put_env(:rondo, :memory_tracker_issues, [issue])
    Application.put_env(:rondo, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :RetryTerminalOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_recipient)
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    initial_state = :sys.get_state(pid)
    retry_token = make_ref()

    retry_entry = %{
      attempt: 1,
      retry_token: retry_token,
      identifier: issue.identifier
    }

    :sys.replace_state(pid, fn _ ->
      %{initial_state | poll_interval_ms: 60_000, retry_attempts: %{issue.id => retry_entry}, claimed: MapSet.new([issue.id])}
    end)

    send(pid, {:retry_issue, issue.id, retry_token})

    Process.sleep(50)

    refute_receive {:memory_tracker_state_update, "issue-retry-terminal", "In Progress"}, 100
    assert GenServer.call(pid, :snapshot).retrying == []
    refute MapSet.member?(:sys.get_state(pid).claimed, issue.id)
    refute File.exists?(workspace)
  end

  test "tracker transition guard classifies terminal issues before state writes" do
    issue = %Issue{
      id: "issue-transition-guard",
      identifier: "MT-TRANSITION-GUARD",
      title: "Transition guard test",
      description: "Terminal issues should be detected before transition writes",
      state: "Todo",
      url: "https://example.org/issues/MT-TRANSITION-GUARD"
    }

    assert {:terminal, %Issue{state: "Done"}} =
             Orchestrator.guard_issue_for_transition_for_test(issue, fn [_issue_id] ->
               {:ok, [%{issue | state: "Done"}]}
             end)
  end

  test "completed agent runs appear in snapshot archived list" do
    issue_id = "issue-archive-test"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-401",
      title: "Archive test",
      description: "Verify archiving",
      state: "In Progress",
      url: "https://example.org/issues/MT-401"
    }

    orchestrator_name = Module.concat(__MODULE__, :ArchiveOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: "sess-archive",
      turn_count: 2,
      last_claude_message: nil,
      last_claude_timestamp: nil,
      last_claude_event: nil,
      claude_input_tokens: 50,
      claude_output_tokens: 100,
      claude_total_tokens: 150,
      claude_last_reported_input_tokens: 50,
      claude_last_reported_output_tokens: 100,
      claude_last_reported_total_tokens: 150,
      started_at: DateTime.utc_now(),
      event_log: [
        %{
          at: DateTime.utc_now(),
          event: :session_started,
          message: "test",
          tokens: %{input_tokens: 100, output_tokens: 50, total_tokens: 150}
        }
      ]
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    # Simulate agent completion
    send(pid, {:DOWN, process_ref, :process, self(), :normal})

    # Give the orchestrator time to process
    Process.sleep(50)

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.running == []
    assert snapshot.archived != []

    archived = Enum.find(snapshot.archived, &(&1.identifier == "MT-401" and &1.session_id == "sess-archive"))
    assert archived != nil
    assert archived.identifier == "MT-401"
    assert archived.session_id == "sess-archive"
    assert archived.exit_reason == "completed"
    assert archived.tokens.total_tokens == 150
    assert archived.turn_count == 2

    # Event log is persisted to disk, not in-memory index
    filename =
      case archived.started_at do
        %DateTime{} = started_at ->
          started_at
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601()
          |> String.replace(~r/[:\.]/, "-")
          |> Kernel.<>(".json")

        started_at when is_binary(started_at) ->
          case DateTime.from_iso8601(started_at) do
            {:ok, datetime, _offset} ->
              datetime
              |> DateTime.truncate(:second)
              |> DateTime.to_iso8601()
              |> String.replace(~r/[:\.]/, "-")
              |> Kernel.<>(".json")

            _ ->
              started_at
              |> String.replace(~r/[:\.]/, "-")
              |> Kernel.<>(".json")
          end
      end

    assert {:ok, full_run} = Rondo.Orchestrator.load_archived_run("MT-401", filename)
    assert [event] = full_run.event_log
    assert event.event == :session_started
    assert event.tokens.total_tokens == 150
  end

  test "snapshot normalizes archived run timestamps" do
    issue = %Issue{
      id: "issue-archive-normalize-timestamps",
      identifier: "MT-402",
      title: "Archive timestamp normalization",
      description: "Verify archived snapshot timestamps are normalized",
      state: "In Progress",
      url: "https://example.org/issues/MT-402"
    }

    orchestrator_name = Module.concat(__MODULE__, :ArchiveTimestampNormalizationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)

    archived_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      session_id: "sess-archive-string",
      state: issue.state,
      started_at: "2026-06-29T13:19:45.206052Z",
      finished_at: "2026-06-29T13:20:45.206052Z",
      exit_reason: "completed",
      turn_count: 2,
      tokens: %{input_tokens: 50, output_tokens: 100, total_tokens: 150},
      event_log: []
    }

    :sys.replace_state(pid, fn _ ->
      Map.put(initial_state, :archived_runs, [archived_entry])
    end)

    snapshot = GenServer.call(pid, :snapshot)
    [archived] = snapshot.archived

    assert %DateTime{} = archived.started_at
    assert %DateTime{} = archived.finished_at
  end

  test "orchestrator pauses when the final report text reports blocked next_state without schema JSON" do
    workspace_root = tmp_dir("orchestrator-final-report-blocked")

    issue = %Issue{
      id: "issue-final-report-blocked",
      identifier: "MT-FR-BLOCKED",
      title: "Final report blocked",
      description: "Should pause on unparsed blocked state",
      state: "In Progress",
      url: "https://example.org/issues/MT-FR-BLOCKED"
    }

    on_exit(fn -> File.rm_rf(workspace_root) end)
    Application.put_env(:rondo, :memory_tracker_issues, [issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: fake_claude_script_with_result(workspace_root, "blocked-session", "Blocked: still waiting on external auth.\nnext_state: blocked\n"),
      max_turns: 3
    )

    orchestrator_name = Module.concat(__MODULE__, :FinalReportBlockedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    paused_entry =
      wait_until(fn ->
        case GenServer.call(pid, :snapshot).paused do
          [entry] -> entry
          _ -> nil
        end
      end)

    assert paused_entry.issue_id == issue.id
    assert paused_entry.interrupt["reason"] == "final_report_invalid"
    assert paused_entry.interrupt["classification"] == "blocked_state_unparsed"
    assert paused_entry.final_report_status == "missing"
    assert paused_entry.reported_next_state == "blocked"
    assert paused_entry.continuation_count == 0
    assert GenServer.call(pid, :snapshot).running == []
  end

  test "orchestrator pauses after a repeated invalid final report to avoid a loop" do
    workspace_root = tmp_dir("orchestrator-final-report-loop")

    issue = %Issue{
      id: "issue-final-report-loop",
      identifier: "MT-FR-LOOP",
      title: "Final report loop",
      description: "Should pause on repeated invalid reports",
      state: "In Progress",
      url: "https://example.org/issues/MT-FR-LOOP"
    }

    on_exit(fn -> File.rm_rf(workspace_root) end)
    Application.put_env(:rondo, :memory_tracker_issues, [issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_command: fake_claude_script_with_result(workspace_root, "loop-session", "{\"schema\": \"rondo.final_report/v0\", \"next_state\": \"In Progress\"}"),
      max_turns: 3
    )

    orchestrator_name = Module.concat(__MODULE__, :FinalReportLoopGuardOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_issues)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    snapshot =
      wait_until(fn ->
        case GenServer.call(pid, :snapshot) do
          %{paused: [_entry], running: []} = snapshot -> snapshot
          _ -> nil
        end
      end)

    [paused_entry] = snapshot.paused
    trace_file = Path.join(workspace_root, "claude.trace")

    argv_lines =
      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "ARGV:"))

    assert length(argv_lines) >= 2
    assert paused_entry.issue_id == issue.id
    assert paused_entry.interrupt["reason"] == "final_report_invalid"
    assert paused_entry.interrupt["classification"] == "repeated_final_report"
    assert paused_entry.final_report_status == "invalid"
    assert paused_entry.reported_next_state == "In Progress"
    assert paused_entry.continuation_count == 1
    assert GenServer.call(pid, :snapshot).running == []
  end

  test "archived run loader rejects path traversal" do
    assert {:error, :invalid_path} = Rondo.Orchestrator.load_archived_run("../outside", "run.json")
    assert {:error, :invalid_path} = Rondo.Orchestrator.load_archived_run("MT-401", "../outside.json")
    assert {:error, :invalid_path} = Rondo.Orchestrator.load_archived_run("MT-401", "..")
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp fake_action_policy_script(root, decision) do
    path = Path.join(root, "fake-action-policy.sh")

    File.write!(path, """
    #!/bin/sh
    action=""
    classes=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --action) action="$2"; shift 2 ;;
        --class) classes="$classes${classes:+,}$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '{"decision":"#{decision}","action":"%s","classes":["%s"],"mode":"unattended-auto","log_level":"warning","requires_human":true,"reason":"test #{decision}","matched_rules":[]}' "$action" "$classes"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp fake_claude_script(root, session_id, sleep_seconds) do
    path = Path.join(root, "fake-claude.sh")

    File.write!(path, """
    #!/bin/sh
    echo '{"type":"system","subtype":"init","session_id":"#{session_id}","tools":[]}'
    sleep #{sleep_seconds}
    echo '{"type":"result","subtype":"success","session_id":"#{session_id}","usage":{"input_tokens":1,"output_tokens":1}}'
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp fake_claude_script_with_result(root, session_id, result_text) do
    path = Path.join(root, "fake-claude.sh")
    trace_file = Path.join(root, "claude.trace")
    system_line = Jason.encode!(%{"type" => "system", "subtype" => "init", "session_id" => session_id, "tools" => []})
    result_line = Jason.encode!(%{"type" => "result", "subtype" => "success", "session_id" => session_id, "usage" => %{"input_tokens" => 1, "output_tokens" => 1}, "result" => result_text})

    File.write!(path, """
    #!/bin/sh
    printf 'ARGV:%s\n' "$*" >> "#{trace_file}"
    cat <<'EOF'
    #{system_line}
    #{result_line}
    EOF
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp polling_snapshot_for_test(state) do
    now_ms = System.monotonic_time(:millisecond)

    %{
      checking?: Map.get(state, :poll_check_in_progress) == true,
      next_poll_in_ms:
        case Map.get(state, :next_poll_due_at_ms) do
          nil -> nil
          next_poll_due_at_ms -> max(0, next_poll_due_at_ms - now_ms)
        end,
      poll_interval_ms: Map.get(state, :poll_interval_ms)
    }
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(50)
        wait_until(fun, attempts - 1)

      false ->
        Process.sleep(50)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end

  defp wait_until(_fun, 0), do: flunk("timed out waiting for condition")
end
