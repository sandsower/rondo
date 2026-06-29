defmodule Rondo.Codex.CLITest do
  use Rondo.TestSupport

  alias Rondo.Codex.CLI, as: CodexCLI

  test "CodexCLI.run returns thread_id, exit_code, and usage on success" do
    test_root = Path.join(System.tmp_dir!(), "rondo-elixir-codex-cli-run-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-300")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      echo '{"type":"thread.started","thread_id":"codex-session-1"}'
      echo '{"type":"item.completed","thread_id":"codex-session-1","item":{"id":"msg-1","type":"agent_message","text":"Working from codex"}}'
      echo '{"type":"turn.completed","thread_id":"codex-session-1","usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":4}}'
      exit 0
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: codex_binary
      )

      test_pid = self()
      on_event = fn event -> send(test_pid, {:codex_event, event}) end

      assert {:ok, result} = CodexCLI.run("Fix the tests", workspace, on_event: on_event)
      assert result.thread_id == "codex-session-1"
      assert result.session_id == "codex-session-1"
      assert result.exit_code == 0
      assert result.usage == %{input_tokens: 10, output_tokens: 7, cache_read_tokens: 2, cache_write_tokens: 0, total_tokens: 19, cost: nil}

      assert_receive {:codex_event, %{event_type: :session_started, run_ref: %{provider_ref: "codex-session-1"}}}, 500
      assert_receive {:codex_event, %{event_type: :assistant_message, message: "Working from codex"}}, 500
      assert_receive {:codex_event, %{event_type: :invocation_completed}}, 500
    after
      File.rm_rf(test_root)
    end
  end

  test "CodexCLI.run supports default opts and CodexCLI.resume forwards explicit opts" do
    test_root = Path.join(System.tmp_dir!(), "rondo-elixir-codex-cli-defaults-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-301")
      codex_binary = Path.join(test_root, "fake-codex")
      run_trace = Path.join(test_root, "codex-run.trace")
      resume_trace = Path.join(test_root, "codex-resume.trace")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      if [ \"$1\" = \"exec\" ] && [ \"$2\" = \"--help\" ]; then
        echo 'codex exec --help'
        echo '  --model'
        exit 0
      fi

      if [ \"$3\" = \"resume\" ]; then
        {
          for arg in "$@"; do
            printf '%s\n' "$arg"
          done
        } > "#{resume_trace}"
      else
        {
          for arg in "$@"; do
            printf '%s\n' "$arg"
          done
        } > "#{run_trace}"
      fi

      echo '{"type":"thread.started","thread_id":"codex-session-default"}'
      echo '{"type":"turn.completed","thread_id":"codex-session-default"}'
      exit 0
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: codex_binary
      )

      assert {:ok, result} = CodexCLI.run("Run with defaults", workspace)
      assert result.thread_id == "codex-session-default"

      assert File.read!(run_trace) == "exec\n--json\nRun with defaults\n"

      assert {:ok, resumed} = CodexCLI.resume("prev-thread-id", "Continue working", workspace, model: "gpt-5.4")
      assert resumed.thread_id == "codex-session-default"
      assert File.read!(resume_trace) == "exec\n--json\nresume\nprev-thread-id\n--model\ngpt-5.4\nContinue working\n"
    after
      File.rm_rf(test_root)
    end
  end
end
