import gleeunit/should
import rondo/workspace

pub fn run_hook_success_test() {
  let result = workspace.run_hook("echo hello", "/tmp", 5000)
  result |> should.be_ok()
}

pub fn run_hook_failure_test() {
  let result = workspace.run_hook("exit 1", "/tmp", 5000)
  case result {
    Error(workspace.HookFailed(_)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn run_hook_empty_command_skips_test() {
  let result = workspace.run_hook("", "/tmp", 5000)
  result |> should.be_ok()
}

pub fn run_hook_timeout_test() {
  let result = workspace.run_hook("sleep 10", "/tmp", 100)
  case result {
    Error(workspace.HookFailed(_)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}
