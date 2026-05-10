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

  test "ClaudeCLI.run preserves quoted claude.command shell strings" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-quoted-command-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-108")
      bin_dir = Path.join(test_root, "bin with spaces")
      claude_binary = Path.join(bin_dir, "fake claude")
      File.mkdir_p!(workspace)
      File.mkdir_p!(bin_dir)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"quoted-command-session","tools":[]}'
      echo '{"type":"result","subtype":"success","session_id":"quoted-command-session","usage":{"input_tokens":2,"output_tokens":3}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "\"#{claude_binary}\""
      )

      assert {:ok, result} = ClaudeCLI.run("Quoted command test", workspace)
      assert result.session_id == "quoted-command-session"
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run expands env-backed claude.command in the launched shell" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-env-command-#{System.unique_integer([:positive])}"
      )

    env_var = "RONDO_TEST_CLAUDE_BIN_#{System.unique_integer([:positive])}"
    previous_value = System.get_env(env_var)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-109")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"env-command-session","tools":[]}'
      echo '{"type":"result","subtype":"success","session_id":"env-command-session","usage":{"input_tokens":2,"output_tokens":3}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)
      System.put_env(env_var, claude_binary)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "$#{env_var}"
      )

      assert {:ok, result} = ClaudeCLI.run("Env command test", workspace)
      assert result.session_id == "env-command-session"
    after
      restore_env(env_var, previous_value)
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run supports env assignment claude.command values" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-env-assignment-command-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-110")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      if [ "$RONDO_TEST_FLAG" != "1" ]; then
        exit 65
      fi
      echo '{"type":"system","subtype":"init","session_id":"env-assignment-command-session","tools":[]}'
      echo '{"type":"result","subtype":"success","session_id":"env-assignment-command-session","usage":{"input_tokens":2,"output_tokens":3}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "RONDO_TEST_FLAG=1 #{claude_binary}"
      )

      assert {:ok, result} = ClaudeCLI.run("Env assignment command test", workspace)
      assert result.session_id == "env-assignment-command-session"
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run keeps generated prompt args inert" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-inert-generated-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-113")
      claude_binary = Path.join(test_root, "fake-claude")
      injected_file = Path.join(test_root, "injected")
      trace_file = Path.join(test_root, "argv.trace")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf 'ARGV:%s\n' "$*" > "#{trace_file}"
      echo '{"type":"system","subtype":"init","session_id":"inert-generated-args-session","tools":[]}'
      echo '{"type":"result","subtype":"success","session_id":"inert-generated-args-session","usage":{"input_tokens":2,"output_tokens":3}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      prompt = "Generated args stay inert $(touch #{injected_file}) '; exit 99 #'"
      assert {:ok, result} = ClaudeCLI.run(prompt, workspace)
      assert result.session_id == "inert-generated-args-session"
      refute File.exists?(injected_file)
      assert File.read!(trace_file) =~ prompt
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run supports wrapper claude.command values" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-wrapper-command-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-110")
      bin_dir = Path.join(test_root, "bin")
      mise_binary = Path.join(bin_dir, "mise")
      claude_binary = Path.join(bin_dir, "claude")
      trace_file = Path.join(test_root, "mise.trace")
      File.mkdir_p!(workspace)
      File.mkdir_p!(bin_dir)

      File.write!(mise_binary, """
      #!/bin/sh
      printf 'MISE:%s\n' "$*" > "#{trace_file}"
      if [ "$1" = "exec" ] && [ "$2" = "--" ]; then
        shift 2
        exec "$@"
      fi
      exit 64
      """)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"wrapper-command-session","tools":[]}'
      echo '{"type":"result","subtype":"success","session_id":"wrapper-command-session","usage":{"input_tokens":2,"output_tokens":3}}'
      exit 0
      """)

      File.chmod!(mise_binary, 0o755)
      File.chmod!(claude_binary, 0o755)
      System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "mise exec -- claude"
      )

      assert {:ok, result} = ClaudeCLI.run("Wrapper command test", workspace)
      assert result.session_id == "wrapper-command-session"
      assert File.read!(trace_file) =~ "MISE:exec -- claude"
    after
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run rejects symlink workspaces that escape the configured root before launch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-symlink-escape-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      workspace = Path.join(workspace_root, "MT-111")
      claude_binary = Path.join(test_root, "fake-claude")
      marker_file = Path.join(test_root, "launched")
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      touch "#{marker_file}"
      echo '{"type":"result","subtype":"success","session_id":"should-not-launch"}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      assert {:error, {:invalid_workspace_cwd, :symlink_escape}} = ClaudeCLI.run("Escape test", workspace)
      refute File.exists?(marker_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.run rejects the workspace root itself before launch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-root-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      claude_binary = Path.join(test_root, "fake-claude")
      marker_file = Path.join(test_root, "launched")
      File.mkdir_p!(workspace_root)

      File.write!(claude_binary, """
      #!/bin/sh
      touch "#{marker_file}"
      echo '{"type":"result","subtype":"success","session_id":"should-not-launch"}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      assert {:error, {:invalid_workspace_cwd, :workspace_equals_root}} = ClaudeCLI.run("Root test", workspace_root)
      refute File.exists?(marker_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "ClaudeCLI.resume includes configured model and allowed tools" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-claude-cli-resume-flags-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-112")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-resume-flags.trace")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf 'ARGV:%s\n' "$*" > "#{trace_file}"
      echo '{"type":"system","subtype":"init","session_id":"resume-flags-session","tools":[]}'
      echo '{"type":"result","subtype":"success","session_id":"resume-flags-session","usage":{"input_tokens":20,"output_tokens":10}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary,
        claude_model: "claude-sonnet-test",
        claude_allowed_tools: ["Bash", "Edit"]
      )

      assert {:ok, result} = ClaudeCLI.resume("prev-session-id", "Continue working", workspace)
      assert result.session_id == "resume-flags-session"

      trace = File.read!(trace_file)
      assert trace =~ "--resume"
      assert trace =~ "prev-session-id"
      assert trace =~ "--model claude-sonnet-test"
      assert trace =~ "--allowedTools Bash"
      assert trace =~ "--allowedTools Edit"
      assert trace =~ "--permission-mode bypassPermissions"
    after
      File.rm_rf(test_root)
    end
  end
end
