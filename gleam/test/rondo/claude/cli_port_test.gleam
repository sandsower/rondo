import gleeunit/should
import rondo/claude/cli.{type CliOptions, CliOptions}
import rondo/run_result

pub fn run_with_args_captures_json_stream_test() {
  let opts = test_opts()
  let result =
    cli.run_with_args(
      [
        "-c",
        "echo '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess-1\"}'; echo '{\"type\":\"result\",\"result\":\"done\",\"session_id\":\"sess-1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}'",
      ],
      "/tmp",
      opts,
      fn(_) { Nil },
    )
  case result {
    run_result.Completed(session_id, usage) -> {
      session_id |> should.equal("sess-1")
      usage.input_tokens |> should.equal(10)
      usage.output_tokens |> should.equal(5)
    }
    _ -> should.fail()
  }
}

pub fn run_with_args_nonzero_exit_test() {
  let opts = test_opts()
  let result =
    cli.run_with_args(["-c", "exit 42"], "/tmp", opts, fn(_) { Nil })
  case result {
    run_result.Failed(run_result.ProcessCrashed(code)) ->
      code |> should.equal(42)
    _ -> should.fail()
  }
}

pub fn run_with_args_timeout_test() {
  let opts = CliOptions(..test_opts(), turn_timeout_ms: 100)
  let result =
    cli.run_with_args(["-c", "sleep 10"], "/tmp", opts, fn(_) { Nil })
  case result {
    run_result.TimedOut(_, _) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

fn test_opts() -> CliOptions {
  CliOptions(
    command: "/bin/sh",
    output_format: "stream-json",
    max_turns: 1,
    permission_mode: "default",
    dangerously_skip_permissions: False,
    model: "",
    allowed_tools: [],
    turn_timeout_ms: 5000,
  )
}
