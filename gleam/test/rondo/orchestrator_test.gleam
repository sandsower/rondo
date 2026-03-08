import gleam/dict
import gleam/erlang/process
import gleam/set
import gleeunit/should
import rondo/claude/cli.{CliOptions}
import rondo/claude/event
import rondo/config
import rondo/issue.{Issue}
import rondo/orchestrator.{type OrchestratorState, OrchestratorState}

pub fn snapshot_starts_empty_test() {
  let state = empty_state()
  state.running |> dict.size() |> should.equal(0)
  state.completed |> set.size() |> should.equal(0)
  state.totals |> should.equal(event.zero_usage())
}

pub fn orchestrator_dispatches_agent_on_tick_test() {
  let issue =
    Issue(
      id: "i-1",
      identifier: "DAL-1",
      title: "Test",
      description: "Do stuff",
      priority: 1,
      state: "Todo",
      branch_name: "",
      url: "",
      assignee_id: "",
      labels: [],
      blocked_by: [],
    )
  let c =
    config.Config(
      ..config.default(),
      linear_api_token: "tok",
      workspace_root: "/tmp/rondo-test-orch",
    )
  let cli_opts =
    CliOptions(
      command: "echo",
      output_format: "stream-json",
      max_turns: 1,
      permission_mode: "default",
      dangerously_skip_permissions: False,
      model: "",
      allowed_tools: [],
      turn_timeout_ms: 1000,
    )

  let assert Ok(orch) =
    orchestrator.start(c, cli_opts, fn() { Ok([issue]) }, fn(_) { Ok([]) })

  // Send Tick to trigger dispatch
  process.send(orch, orchestrator.Tick)

  // Give it time to process
  process.sleep(500)

  // Get snapshot — should have one running entry
  let snap_subject = process.new_subject()
  process.send(orch, orchestrator.GetSnapshot(snap_subject))
  let assert Ok(snap) = process.receive(snap_subject, 2000)
  dict.size(snap.running) |> should.equal(1)
}

fn empty_state() -> OrchestratorState {
  let c = config.Config(..config.default(), linear_api_token: "tok")
  let cli_opts =
    CliOptions(
      command: "echo",
      output_format: "stream-json",
      max_turns: 1,
      permission_mode: "default",
      dangerously_skip_permissions: False,
      model: "",
      allowed_tools: [],
      turn_timeout_ms: 5000,
    )
  OrchestratorState(
    config: c,
    cli_opts: cli_opts,
    running: dict.new(),
    completed: set.new(),
    claimed: set.new(),
    retry_attempts: dict.new(),
    totals: event.zero_usage(),
    fetch_candidates: fn() { Ok([]) },
    fetch_states: fn(_) { Ok([]) },
  )
}
