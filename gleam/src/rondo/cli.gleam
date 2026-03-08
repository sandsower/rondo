import argv
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import rondo/claude/cli as claude_cli
import rondo/config
import rondo/orchestrator
import rondo/tracker/linear
import simplifile

/// Map tracker errors to Nil for orchestrator compatibility
fn map_error_to_nil(r: Result(a, _b)) -> Result(a, Nil) {
  result.map_error(r, fn(_) { Nil })
}

pub type CliError {
  MissingGuardrailFlag
  ConfigError(config.ConfigError)
  StartupError(String)
}

pub fn run() -> Result(Nil, CliError) {
  let args = argv.load().arguments

  case
    list.contains(
      args,
      "--i_understand_that_this_will_be_running_without_the_usual_guardrails",
    )
  {
    False -> {
      io.println(
        "Error: You must pass --i_understand_that_this_will_be_running_without_the_usual_guardrails",
      )
      Error(MissingGuardrailFlag)
    }
    True -> {
      let workflow_path = find_positional_arg(args)
      let cfg = config.from_env()
      case config.validate(cfg) {
        Error(e) -> {
          io.println("Config validation failed: " <> string.inspect(e))
          Error(ConfigError(e))
        }
        Ok(validated_config) -> {
          start_system(validated_config, workflow_path)
        }
      }
    }
  }
}

fn start_system(
  cfg: config.Config,
  workflow_path: String,
) -> Result(Nil, CliError) {
  // Load workflow prompt from file if it exists
  let workflow_prompt = case simplifile.read(workflow_path) {
    Ok(content) -> content
    Error(_) -> cfg.workflow_prompt
  }
  let cfg = config.Config(..cfg, workflow_prompt: workflow_prompt)

  // Build CLI options for Claude
  let cli_opts = claude_cli.CliOptions(
    command: cfg.claude_command,
    output_format: cfg.claude_output_format,
    max_turns: cfg.claude_max_turns,
    permission_mode: cfg.claude_permission_mode,
    dangerously_skip_permissions: cfg.claude_dangerously_skip_permissions,
    model: cfg.claude_model,
    allowed_tools: cfg.claude_allowed_tools,
    turn_timeout_ms: cfg.claude_turn_timeout_ms,
  )

  // Start orchestrator
  case
    orchestrator.start(
      cfg,
      cli_opts,
      fn() { linear.fetch_candidate_issues(cfg) |> map_error_to_nil },
      fn(ids) { linear.fetch_issue_states_by_ids(cfg, ids) |> map_error_to_nil },
    )
  {
    Error(_) -> Error(StartupError("Failed to start orchestrator"))
    Ok(orch_subject) -> {
      io.println("Rondo starting...")

      // Start polling timer
      start_poll_timer(orch_subject, cfg.poll_interval_ms)

      // Send initial tick
      process.send(orch_subject, orchestrator.Tick)

      // Block forever
      process.sleep_forever()
      Ok(Nil)
    }
  }
}

fn start_poll_timer(
  orch: process.Subject(orchestrator.OrchestratorMessage),
  interval_ms: Int,
) -> Nil {
  let _ = process.start(fn() {
    poll_loop(orch, interval_ms)
  }, True)
  Nil
}

fn poll_loop(
  orch: process.Subject(orchestrator.OrchestratorMessage),
  interval_ms: Int,
) -> Nil {
  process.sleep(interval_ms)
  process.send(orch, orchestrator.Tick)
  poll_loop(orch, interval_ms)
}

fn find_positional_arg(args: List(String)) -> String {
  args
  |> list.filter(fn(a) { !string.starts_with(a, "--") })
  |> list.first()
  |> result.unwrap("WORKFLOW.md")
}
