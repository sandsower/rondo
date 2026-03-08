import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import rondo/claude/cli.{type CliOptions}
import rondo/claude/event.{type ClaudeEvent, type TokenUsage}
import rondo/issue.{type Issue}
import rondo/prompt
import rondo/run_result.{type RunResult, Completed}

pub type AgentMessage {
  Begin(issue: Issue, workspace_path: String, prompt: String)
  StreamEvent(event: ClaudeEvent)
  RunComplete(result: RunResult)
  Stop
  GetStatus(reply_to: Subject(AgentStatus))
}

pub type AgentPhase {
  Idle
  Running
  Finished(RunResult)
}

pub type AgentStatus {
  AgentStatus(
    issue_id: String,
    identifier: String,
    phase: AgentPhase,
    turn: Int,
    usage: TokenUsage,
    session_id: String,
  )
}

pub type AgentState {
  AgentState(
    issue: Issue,
    phase: AgentPhase,
    workspace_path: String,
    session_id: String,
    turn: Int,
    usage: TokenUsage,
    cli_opts: CliOptions,
    notify: Subject(AgentNotification),
    self: Subject(AgentMessage),
  )
}

pub type AgentNotification {
  AgentStarted(issue_id: String)
  AgentEvent(issue_id: String, event: ClaudeEvent)
  AgentFinished(issue_id: String, result: RunResult)
}

pub fn start(
  issue: Issue,
  workspace_path: String,
  _prompt: String,
  cli_opts: CliOptions,
  notify: Subject(AgentNotification),
) -> Result(Subject(AgentMessage), actor.StartError) {
  actor.start_spec(actor.Spec(
    init: fn() {
      let self = process.new_subject()
      let selector =
        process.new_selector()
        |> process.selecting(self, fn(msg) { msg })
      let state =
        AgentState(
          issue: issue,
          phase: Idle,
          workspace_path: workspace_path,
          session_id: "",
          turn: 0,
          usage: event.zero_usage(),
          cli_opts: cli_opts,
          notify: notify,
          self: self,
        )
      actor.Ready(state, selector)
    },
    init_timeout: 5000,
    loop: handle_message,
  ))
}

fn handle_message(
  msg: AgentMessage,
  state: AgentState,
) -> actor.Next(AgentMessage, AgentState) {
  case msg {
    Begin(issue, workspace_path, prompt_template) -> {
      let new_state =
        AgentState(
          ..state,
          issue: issue,
          workspace_path: workspace_path,
          phase: Running,
          turn: 1,
        )
      process.send(state.notify, AgentStarted(issue_id: issue.id))

      let self = state.self
      let cli_opts = state.cli_opts
      let notify = state.notify
      let _ =
        process.start(
          fn() {
            let result =
              run_turns(
                issue,
                workspace_path,
                prompt_template,
                cli_opts,
                "",
                1,
                cli_opts.max_turns,
                fn(evt) {
                  process.send(notify, AgentEvent(
                    issue_id: issue.id,
                    event: evt,
                  ))
                },
              )
            process.send(self, RunComplete(result))
          },
          True,
        )

      actor.continue(new_state)
    }
    RunComplete(result) -> {
      process.send(state.notify, AgentFinished(
        issue_id: state.issue.id,
        result: result,
      ))
      actor.continue(AgentState(..state, phase: Finished(result)))
    }
    StreamEvent(evt) -> {
      process.send(state.notify, AgentEvent(
        issue_id: state.issue.id,
        event: evt,
      ))
      let new_usage = case evt {
        event.AssistantMessage(_, usage) -> event.add_usage(state.usage, usage)
        event.ResultEvent(_, _, usage) -> event.add_usage(state.usage, usage)
        _ -> state.usage
      }
      let new_session_id = case evt {
        event.SessionStarted(sid) -> sid
        event.ResultEvent(_, sid, _) -> sid
        _ -> state.session_id
      }
      actor.continue(AgentState(
        ..state,
        usage: new_usage,
        session_id: new_session_id,
      ))
    }
    GetStatus(reply_to) -> {
      process.send(
        reply_to,
        AgentStatus(
          issue_id: state.issue.id,
          identifier: state.issue.identifier,
          phase: state.phase,
          turn: state.turn,
          usage: state.usage,
          session_id: state.session_id,
        ),
      )
      actor.continue(state)
    }
    Stop -> {
      actor.Stop(process.Normal)
    }
  }
}

fn run_turns(
  issue: Issue,
  workspace_path: String,
  prompt_template: String,
  cli_opts: CliOptions,
  session_id: String,
  turn: Int,
  max_turns: Int,
  on_event: fn(ClaudeEvent) -> Nil,
) -> RunResult {
  let built_prompt = prompt.build(prompt_template, issue, turn)
  let result = case session_id {
    "" -> cli.run(built_prompt, workspace_path, cli_opts, on_event)
    sid -> cli.resume(built_prompt, sid, workspace_path, cli_opts, on_event)
  }
  case result {
    Completed(new_sid, _usage) -> {
      case turn < max_turns {
        True ->
          run_turns(
            issue,
            workspace_path,
            prompt_template,
            cli_opts,
            new_sid,
            turn + 1,
            max_turns,
            on_event,
          )
        False -> result
      }
    }
    _ -> result
  }
}
