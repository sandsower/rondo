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
    assert [paused] = payload.paused
    assert paused.issue_identifier == "MT-PAUSED"
    assert paused.interrupt.reason == "repeated_gate_failure"
    assert paused.latest_gate.status == :fail

    assert {:ok, issue_payload} = RondoWeb.Presenter.issue_payload("MT-PAUSED", server_name, 1_000)
    assert issue_payload.status == "paused"
    assert issue_payload.paused.interrupt.reason == "repeated_gate_failure"
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
end
