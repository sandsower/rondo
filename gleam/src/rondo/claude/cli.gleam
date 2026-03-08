import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import rondo/claude/event.{type ClaudeEvent, type TokenUsage}
import rondo/claude/stream
import rondo/ffi/port
import rondo/run_result.{
  type RunResult, Completed, Failed, ProcessCrashed, TimedOut,
}

pub type CliOptions {
  CliOptions(
    command: String,
    output_format: String,
    max_turns: Int,
    permission_mode: String,
    dangerously_skip_permissions: Bool,
    model: String,
    allowed_tools: List(String),
    turn_timeout_ms: Int,
  )
}

pub fn build_args(
  prompt: String,
  opts: CliOptions,
  resume_session_id: String,
) -> List(String) {
  let base = case string.is_empty(resume_session_id) {
    True -> ["-p", prompt]
    False -> ["-p", prompt, "--resume", resume_session_id]
  }
  let base =
    list.append(base, [
      "--verbose",
      "--output-format", opts.output_format,
      "--max-turns", int.to_string(opts.max_turns),
      "--permission-mode", opts.permission_mode,
    ])
  let base = case opts.dangerously_skip_permissions {
    True -> list.append(base, ["--dangerously-skip-permissions"])
    False -> base
  }
  let base = case string.is_empty(opts.model) {
    True -> base
    False -> list.append(base, ["--model", opts.model])
  }
  case list.is_empty(opts.allowed_tools) {
    True -> base
    False ->
      list.append(base, [
        "--allowedTools", string.join(opts.allowed_tools, ","),
      ])
  }
}

pub fn run(
  prompt: String,
  working_dir: String,
  opts: CliOptions,
  on_event: fn(ClaudeEvent) -> Nil,
) -> RunResult {
  run_session(prompt, working_dir, opts, "", on_event)
}

pub fn resume(
  guidance: String,
  session_id: String,
  working_dir: String,
  opts: CliOptions,
  on_event: fn(ClaudeEvent) -> Nil,
) -> RunResult {
  run_session(guidance, working_dir, opts, session_id, on_event)
}

pub fn run_with_args(
  args: List(String),
  _working_dir: String,
  opts: CliOptions,
  on_event: fn(ClaudeEvent) -> Nil,
) -> RunResult {
  case port.open(opts.command, args) {
    Error(_reason) -> Failed(reason: ProcessCrashed(exit_code: -1))
    Ok(p) -> {
      let result =
        collect_port_output(
          p,
          on_event,
          event.zero_usage(),
          "",
          "",
          opts.turn_timeout_ms,
        )
      let _ = port.close(p)
      result
    }
  }
}

fn run_session(
  prompt: String,
  working_dir: String,
  opts: CliOptions,
  resume_session_id: String,
  on_event: fn(ClaudeEvent) -> Nil,
) -> RunResult {
  let args = build_args(prompt, opts, resume_session_id)
  run_with_args(args, working_dir, opts, on_event)
}

fn collect_port_output(
  p: port.Port,
  on_event: fn(ClaudeEvent) -> Nil,
  usage: TokenUsage,
  session_id: String,
  line_buffer: String,
  timeout_ms: Int,
) -> RunResult {
  case port.receive_message(p, timeout_ms) {
    Error(_) -> TimedOut(session_id: session_id, elapsed_ms: timeout_ms)
    Ok(port.Line(data)) -> {
      let line = line_buffer <> bit_array_to_string(data)
      let #(new_usage, new_session_id) =
        process_line(line, on_event, usage, session_id)
      collect_port_output(p, on_event, new_usage, new_session_id, "", timeout_ms)
    }
    Ok(port.Partial(data)) -> {
      let chunk = bit_array_to_string(data)
      collect_port_output(
        p,
        on_event,
        usage,
        session_id,
        line_buffer <> chunk,
        timeout_ms,
      )
    }
    Ok(port.ExitStatus(0)) -> Completed(session_id: session_id, usage: usage)
    Ok(port.ExitStatus(code)) ->
      Failed(reason: ProcessCrashed(exit_code: code))
  }
}

fn process_line(
  line: String,
  on_event: fn(ClaudeEvent) -> Nil,
  usage: TokenUsage,
  session_id: String,
) -> #(TokenUsage, String) {
  case stream.parse_line(line) {
    Ok(evt) -> {
      on_event(evt)
      let new_usage = case evt {
        event.AssistantMessage(_, u) -> event.add_usage(usage, u)
        event.ResultEvent(_, _, u) -> event.add_usage(usage, u)
        _ -> usage
      }
      let new_sid = case evt {
        event.SessionStarted(sid) -> sid
        event.ResultEvent(_, sid, _) -> sid
        _ -> session_id
      }
      #(new_usage, new_sid)
    }
    Error(_) -> #(usage, session_id)
  }
}

fn bit_array_to_string(data: BitArray) -> String {
  case bit_array.to_string(data) {
    Ok(s) -> s
    Error(_) -> ""
  }
}
