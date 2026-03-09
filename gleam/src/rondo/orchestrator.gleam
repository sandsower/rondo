import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/set.{type Set}
import rondo/agent
import rondo/claude/cli.{type CliOptions}
import rondo/claude/event.{type TokenUsage}
import rondo/config.{type Config}
import rondo/issue.{type Issue}
import rondo/prompt
import rondo/run_result.{type RunResult}
import rondo/workspace

pub type OrchestratorMessage {
  Tick
  RunFinished(issue_id: String, result: RunResult)
  AgentNotification(agent.AgentNotification)
  GetSnapshot(reply_to: Subject(Snapshot))
  RequestRefresh
}

pub type RunningEntry {
  RunningEntry(
    issue_id: String,
    identifier: String,
    state: String,
    session_id: String,
    turn: Int,
    usage: TokenUsage,
    agent: Subject(agent.AgentMessage),
  )
}

pub type Snapshot {
  Snapshot(
    running: Dict(String, RunningEntry),
    completed: Set(String),
    totals: TokenUsage,
  )
}

pub type OrchestratorState {
  OrchestratorState(
    config: Config,
    cli_opts: CliOptions,
    running: Dict(String, RunningEntry),
    completed: Set(String),
    claimed: Set(String),
    retry_attempts: Dict(String, Int),
    totals: TokenUsage,
    fetch_candidates: fn() -> Result(List(Issue), Nil),
    fetch_states: fn(List(String)) -> Result(List(Issue), Nil),
  )
}

pub fn start(
  config: Config,
  cli_opts: CliOptions,
  fetch_candidates: fn() -> Result(List(Issue), Nil),
  fetch_states: fn(List(String)) -> Result(List(Issue), Nil),
) -> Result(Subject(OrchestratorMessage), actor.StartError) {
  actor.start_spec(actor.Spec(
    init: fn() {
      let state =
        OrchestratorState(
          config: config,
          cli_opts: cli_opts,
          running: dict.new(),
          completed: set.new(),
          claimed: set.new(),
          retry_attempts: dict.new(),
          totals: event.zero_usage(),
          fetch_candidates: fetch_candidates,
          fetch_states: fetch_states,
        )
      actor.Ready(state, process.new_selector())
    },
    init_timeout: 5000,
    loop: handle_message,
  ))
}

fn handle_message(
  msg: OrchestratorMessage,
  state: OrchestratorState,
) -> actor.Next(OrchestratorMessage, OrchestratorState) {
  case msg {
    Tick -> {
      let new_state = poll_and_dispatch(state)
      actor.continue(new_state)
    }
    RunFinished(issue_id, _result) -> {
      let new_running = dict.delete(state.running, issue_id)
      let new_completed = set.insert(state.completed, issue_id)
      actor.continue(OrchestratorState(
        ..state,
        running: new_running,
        completed: new_completed,
      ))
    }
    AgentNotification(notification) -> {
      let new_state = handle_agent_notification(state, notification)
      actor.continue(new_state)
    }
    GetSnapshot(reply_to) -> {
      process.send(reply_to, Snapshot(
        running: state.running,
        completed: state.completed,
        totals: state.totals,
      ))
      actor.continue(state)
    }
    RequestRefresh -> {
      let new_state = poll_and_dispatch(state)
      actor.continue(new_state)
    }
  }
}

fn poll_and_dispatch(state: OrchestratorState) -> OrchestratorState {
  let running = dict.size(state.running)
  let completed = set.size(state.completed)
  io.println(
    "[tick] running=" <> int.to_string(running)
    <> " completed=" <> int.to_string(completed)
    <> " fetching candidates...",
  )
  case state.fetch_candidates() {
    Error(_) -> {
      io.println("[tick] fetch failed")
      state
    }
    Ok(issues) -> {
      let candidate_count = list.length(issues)
      case candidate_count > 0 {
        True ->
          io.println(
            "[tick] " <> int.to_string(candidate_count) <> " candidate(s) found",
          )
        False -> io.println("[tick] no candidates")
      }
      let available_slots =
        state.config.max_concurrent_agents - dict.size(state.running)
      let to_start =
        issues
        |> list.filter(fn(i) {
          !dict.has_key(state.running, i.id)
          && !set.contains(state.completed, i.id)
          && !set.contains(state.claimed, i.id)
        })
        |> list.take(int.max(0, available_slots))

      list.fold(to_start, state, fn(acc, issue) {
        case start_agent(acc, issue) {
          Ok(new_state) -> new_state
          Error(_) -> acc
        }
      })
    }
  }
}

fn start_agent(
  state: OrchestratorState,
  issue: Issue,
) -> Result(OrchestratorState, Nil) {
  case workspace.create(state.config.workspace_root, issue) {
    Error(_) -> Error(Nil)
    Ok(workspace_path) -> {
      let built_prompt =
        prompt.build(state.config.workflow_prompt, issue, 1)
      let notify = process.new_subject()
      case
        agent.start(issue, workspace_path, built_prompt, state.cli_opts, notify)
      {
        Error(_) -> {
          io.println("[agent] failed to start agent for " <> issue.identifier)
          Error(Nil)
        }
        Ok(agent_subject) -> {
          io.println("[agent] started " <> issue.identifier <> " in " <> workspace_path)
          process.send(
            agent_subject,
            agent.Begin(issue, workspace_path, built_prompt),
          )
          let entry =
            RunningEntry(
              issue_id: issue.id,
              identifier: issue.identifier,
              state: "running",
              session_id: "",
              turn: 1,
              usage: event.zero_usage(),
              agent: agent_subject,
            )
          Ok(OrchestratorState(
            ..state,
            running: dict.insert(state.running, issue.id, entry),
            claimed: set.insert(state.claimed, issue.id),
          ))
        }
      }
    }
  }
}

fn handle_agent_notification(
  state: OrchestratorState,
  notification: agent.AgentNotification,
) -> OrchestratorState {
  case notification {
    agent.AgentStarted(_) -> state
    agent.AgentEvent(_issue_id, evt) -> {
      let new_totals = case evt {
        event.AssistantMessage(_, usage) -> event.add_usage(state.totals, usage)
        event.ResultEvent(_, _, usage) -> event.add_usage(state.totals, usage)
        _ -> state.totals
      }
      OrchestratorState(..state, totals: new_totals)
    }
    agent.AgentFinished(_, _) -> state
  }
}
