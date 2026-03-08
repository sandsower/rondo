import gleam/erlang/process
import gleeunit/should
import rondo/agent
import rondo/claude/cli.{type CliOptions, CliOptions}
import rondo/issue.{type Issue, Issue}

pub fn agent_starts_and_reports_status_test() {
  let issue = test_issue()
  let notify = process.new_subject()
  let opts = test_cli_opts()

  let assert Ok(agent_subject) =
    agent.start(issue, "/tmp/test", "do work", opts, notify)

  let status_subject = process.new_subject()
  process.send(agent_subject, agent.GetStatus(status_subject))

  let status = process.receive(status_subject, 1000)
  status |> should.be_ok()
}

pub fn agent_runs_and_finishes_test() {
  let issue = test_issue()
  let notify = process.new_subject()
  let opts = CliOptions(..test_cli_opts(), command: "echo")

  let assert Ok(agent_subject) =
    agent.start(issue, "/tmp", "work", opts, notify)
  process.send(agent_subject, agent.Begin(issue, "/tmp", "work"))

  // Receive AgentStarted
  let assert Ok(agent.AgentStarted(issue_id: id)) =
    process.receive(notify, 5000)
  id |> should.equal("uuid-1")

  // Drain until AgentFinished (skip AgentEvent messages)
  let assert Ok(finished) = receive_until_finished(notify, 5000)
  case finished {
    agent.AgentFinished(issue_id: fid, result: _) ->
      fid |> should.equal("uuid-1")
    _ -> should.fail()
  }
}

fn receive_until_finished(
  notify: process.Subject(agent.AgentNotification),
  timeout: Int,
) -> Result(agent.AgentNotification, Nil) {
  case process.receive(notify, timeout) {
    Ok(agent.AgentFinished(_, _) as msg) -> Ok(msg)
    Ok(agent.AgentEvent(_, _)) -> receive_until_finished(notify, timeout)
    Ok(other) -> Ok(other)
    Error(_) -> Error(Nil)
  }
}

fn test_issue() -> Issue {
  Issue(
    id: "uuid-1",
    identifier: "DAL-1",
    title: "Test",
    description: "",
    priority: 1,
    state: "Todo",
    branch_name: "",
    url: "",
    assignee_id: "",
    labels: [],
    blocked_by: [],
  )
}

fn test_cli_opts() -> CliOptions {
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
}
