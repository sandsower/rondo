defmodule Rondo.Pi.CLITest do
  use Rondo.TestSupport

  alias Rondo.Pi.CLI, as: PiCLI

  test "PiCLI.run returns session_id, exit_code, and usage on success" do
    test_root = Path.join(System.tmp_dir!(), "rondo-elixir-pi-cli-run-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-200")
      pi_binary = Path.join(test_root, "fake-pi")
      File.mkdir_p!(workspace)

      File.write!(pi_binary, """
      #!/bin/sh
      echo '{"type":"session","version":3,"id":"pi-session-1","cwd":"#{workspace}"}'
      echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Working"}],"usage":{"input":8,"output":3}}}'
      echo '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"Done"}]}]}'
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "pi",
        pi_command: pi_binary
      )

      assert {:ok, result} = PiCLI.run("Fix the tests", workspace)
      assert result.session_id == "pi-session-1"
      assert result.exit_code == 0
      assert result.usage.input_tokens == 8
      assert result.usage.output_tokens == 3
      assert result.usage.total_tokens == 11
    after
      File.rm_rf(test_root)
    end
  end

  test "PiCLI.run invokes on_event callback for each parsed event" do
    test_root = Path.join(System.tmp_dir!(), "rondo-elixir-pi-cli-events-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-201")
      pi_binary = Path.join(test_root, "fake-pi")
      File.mkdir_p!(workspace)

      File.write!(pi_binary, """
      #!/bin/sh
      echo '{"type":"session","version":3,"id":"pi-event-session"}'
      echo '{"type":"agent_start"}'
      echo '{"type":"agent_end","messages":[]}'
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "pi",
        pi_command: pi_binary
      )

      test_pid = self()
      on_event = fn event -> send(test_pid, {:pi_event, event}) end

      assert {:ok, _result} = PiCLI.run("Test events", workspace, on_event: on_event)

      assert_receive {:pi_event, %{"type" => "session", "id" => "pi-event-session"}}, 500
      assert_receive {:pi_event, %{"type" => "agent_start"}}, 500
      assert_receive {:pi_event, %{"type" => "agent_end"}}, 500
    after
      File.rm_rf(test_root)
    end
  end

  test "PiCLI.resume passes --session flag with session_id" do
    test_root = Path.join(System.tmp_dir!(), "rondo-elixir-pi-cli-resume-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-202")
      pi_binary = Path.join(test_root, "fake-pi")
      trace_file = Path.join(test_root, "pi-resume.trace")
      File.mkdir_p!(workspace)

      File.write!(pi_binary, """
      #!/bin/sh
      printf 'ARGV:%s\n' "$*" > "#{trace_file}"
      echo '{"type":"session","version":3,"id":"resumed-pi-session"}'
      echo '{"type":"agent_end","messages":[]}'
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "pi",
        pi_command: pi_binary
      )

      assert {:ok, result} = PiCLI.resume("prev-session-id", "Continue working", workspace)
      assert result.session_id == "resumed-pi-session"

      trace = File.read!(trace_file)
      assert trace =~ "--mode json"
      assert trace =~ "--session prev-session-id"
      assert trace =~ "Continue working"
    after
      File.rm_rf(test_root)
    end
  end

  test "PiCLI.run returns error on non-zero exit code" do
    test_root = Path.join(System.tmp_dir!(), "rondo-elixir-pi-cli-failure-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-203")
      pi_binary = Path.join(test_root, "fake-pi")
      File.mkdir_p!(workspace)

      File.write!(pi_binary, """
      #!/bin/sh
      echo '{"type":"session","version":3,"id":"fail-pi-session"}'
      exit 2
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "pi",
        pi_command: pi_binary
      )

      assert {:error, {:subprocess_exit, 2}} = PiCLI.run("Fail test", workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "PiCLI.run rejects workspaces outside configured root before launch" do
    test_root = Path.join(System.tmp_dir!(), "rondo-elixir-pi-cli-workspace-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      pi_binary = Path.join(test_root, "fake-pi")
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      File.write!(pi_binary, """
      #!/bin/sh
      echo should-not-run > "#{Path.join(test_root, "invoked")}"
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "pi",
        pi_command: pi_binary
      )

      assert {:error, {:invalid_workspace_cwd, :outside_root}} = PiCLI.run("Escape test", outside_workspace)
      refute File.exists?(Path.join(test_root, "invoked"))
    after
      File.rm_rf(test_root)
    end
  end
end
