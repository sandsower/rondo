defmodule Rondo.Claude.CLITest do
  use Rondo.TestSupport

  test "ClaudeCLI.run returns session_id, exit_code, and usage on success" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-run-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-100")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"test-session-1","tools":[],"model":"claude-opus-4-6"}'
      echo '{"type":"assistant","message":{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"Working on it"}],"usage":{"input_tokens":80,"output_tokens":20}},"session_id":"test-session-1"}'
      echo '{"type":"result","subtype":"success","session_id":"test-session-1","usage":{"input_tokens":100,"output_tokens":50}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      assert {:ok, result} = ClaudeCLI.run("Fix the tests", workspace)
      assert result.session_id == "test-session-1"
      assert result.exit_code == 0
      assert result.usage.input_tokens == 100
      assert result.usage.output_tokens == 50
      assert result.usage.total_tokens == 150
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run invokes on_event callback for each parsed event" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-events-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-101")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"evt-session","tools":[],"model":"claude-opus-4-6"}'
      echo '{"type":"assistant","message":{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"Step 1"}],"usage":{"input_tokens":8,"output_tokens":3}},"session_id":"evt-session"}'
      echo '{"type":"result","subtype":"success","session_id":"evt-session","usage":{"input_tokens":10,"output_tokens":5}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      test_pid = self()

      on_event = fn event ->
        send(test_pid, {:claude_event, event})
      end

      assert {:ok, _result} = ClaudeCLI.run("Test events", workspace, on_event: on_event)

      assert_receive {:claude_event, %{"type" => "system", "subtype" => "init", "session_id" => "evt-session"}}, 500
      assert_receive {:claude_event, %{"type" => "assistant", "message" => %{"type" => "message"}}}, 500
      assert_receive {:claude_event, %{"type" => "result", "subtype" => "success"}}, 500
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run extracts usage from nested assistant message" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-nested-usage-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-107")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"nested-usage-session","tools":[]}'
      echo '{"type":"assistant","message":{"type":"message","usage":{"input_tokens":80,"output_tokens":20}},"session_id":"nested-usage-session"}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      test_pid = self()

      on_event = fn event ->
        send(test_pid, {:claude_event, event})
      end

      assert {:ok, result} = ClaudeCLI.run("Nested usage test", workspace, on_event: on_event)
      # Usage from assistant's nested message.usage should be captured
      assert result.usage.input_tokens == 80
      assert result.usage.output_tokens == 20
      assert result.usage.total_tokens == 100
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run returns error on non-zero exit code" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-102")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"fail-session","tools":[]}'
      echo '{"type":"assistant","message":{"type":"message","content":[{"type":"text","text":"Something went wrong"}]},"session_id":"fail-session"}'
      exit 1
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      assert {:error, {:subprocess_exit, 1}} = ClaudeCLI.run("Fail test", workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.resume passes --resume flag with session_id" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-resume-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-103")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-resume.trace")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" > "#{trace_file}"
      echo '{"type":"system","subtype":"init","session_id":"resumed-session","tools":[]}'
      echo '{"type":"result","subtype":"success","session_id":"resumed-session","usage":{"input_tokens":20,"output_tokens":10}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      assert {:ok, result} =
               ClaudeCLI.resume("prev-session-id", "Continue working", workspace)

      assert result.session_id == "resumed-session"
      assert result.exit_code == 0

      trace = File.read!(trace_file)
      assert trace =~ "--resume"
      assert trace =~ "prev-session-id"
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run handles session with no usage data" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-no-usage-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-104")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"no-usage-session","tools":[]}'
      echo '{"type":"assistant","message":{"type":"message","content":[{"type":"text","text":"Done"}]},"session_id":"no-usage-session"}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      assert {:ok, result} = ClaudeCLI.run("No usage test", workspace)
      assert result.session_id == "no-usage-session"
      assert result.exit_code == 0
      assert result.usage == nil
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-partial-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-105")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      # Write a script that outputs a very large JSON line that will exceed Port line buffer
      # and get split across multiple reads, followed by a normal result
      File.write!(claude_binary, """
      #!/bin/sh
      padding=$(printf '%*s' 1100000 '' | tr ' ' a)
      printf '{"type":"system","subtype":"init","session_id":"partial-session","padding":"%s"}\\n' "$padding"
      echo '{"type":"result","subtype":"success","session_id":"partial-session","usage":{"input_tokens":5,"output_tokens":3}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      assert {:ok, result} = ClaudeCLI.run("Partial line test", workspace)
      assert result.session_id == "partial-session"
      assert result.exit_code == 0
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run captures stderr merged into stdout stream" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-106")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"stderr-session"}' >&2
      echo '{"type":"result","subtype":"success","session_id":"stderr-session","usage":{"input_tokens":1,"output_tokens":1}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      # stderr is merged with stdout via :stderr_to_stdout, so the session_id
      # from the stderr line should be picked up
      assert {:ok, result} = ClaudeCLI.run("Stderr test", workspace)
      assert result.session_id == "stderr-session"
    after
      File.rm_rf(test_root)
    end
  end
end
