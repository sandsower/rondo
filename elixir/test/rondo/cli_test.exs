defmodule Rondo.CLITest do
  use ExUnit.Case, async: true

  alias Rondo.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:rondo]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Rondo implementation is a low key engineering preview."
    assert banner =~ "Claude will run without any guardrails."
    assert banner =~ "Rondo is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Rondo with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "run-once sets workflow and runs selected issue without starting daemon" do
    parent = self()
    workflow_path = "tmp/run-once/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = run_once_deps(parent, expanded_path)

    assert :run_once_completed = CLI.evaluate(["run-once", @ack_flag, workflow_path, "--issue", "123"], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
    assert_received {:run_once, "123"}
    refute_received :started
  end

  test "run-once sets workflow and runs selected manifest without starting daemon" do
    parent = self()
    workflow_path = "tmp/run-once/WORKFLOW.md"
    manifest_path = "tmp/request.json"
    expanded_path = Path.expand(workflow_path)
    expanded_manifest_path = Path.expand(manifest_path)

    deps = run_once_deps(parent, expanded_path)

    assert :run_once_completed = CLI.evaluate(["run-once", @ack_flag, workflow_path, "--manifest", manifest_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
    assert_received {:run_manifest, ^expanded_manifest_path}
    refute_received :run_once
    refute_received :started
  end

  test "run-once rejects both issue and manifest" do
    deps = run_once_deps(self(), Path.expand("WORKFLOW.md"))

    assert {:error, message} = CLI.evaluate(["run-once", @ack_flag, "WORKFLOW.md", "--issue", "123", "--manifest", "request.json"], deps)
    assert message =~ "rondo run-once"
  end

  test "run-once treats blank targets as absent during validation and dispatch" do
    parent = self()
    workflow_path = "tmp/run-once/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)
    deps = run_once_deps(parent, expanded_path)

    assert :run_once_completed = CLI.evaluate(["run-once", @ack_flag, workflow_path, "--issue", "123", "--manifest", ""], deps)
    assert_received {:run_once, "123"}
    refute_received {:run_manifest, _}

    assert :run_once_completed = CLI.evaluate(["run-once", @ack_flag, workflow_path, "--issue", "", "--manifest", "request.json"], deps)
    assert_received {:run_manifest, manifest_path}
    assert manifest_path == Path.expand("request.json")
  end

  test "run-once requires an issue id or manifest" do
    deps = run_once_deps(self(), Path.expand("WORKFLOW.md"))

    assert {:error, message} = CLI.evaluate(["run-once", @ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "rondo run-once"
  end

  test "run-once returns workflow not found" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end,
      run_once: fn _issue_id -> :ok end,
      run_manifest: fn _manifest_path -> :ok end
    }

    assert {:error, message} = CLI.evaluate(["run-once", @ack_flag, "WORKFLOW.md", "--issue", "123"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "run-once returns runner errors" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end,
      run_once: fn "123" -> {:error, :boom} end,
      run_manifest: fn _manifest_path -> :ok end
    }

    assert {:error, message} = CLI.evaluate(["run-once", @ack_flag, "WORKFLOW.md", "--issue", "123"], deps)
    assert message =~ "run-once failed for issue 123: :boom"
  end

  defp run_once_deps(parent, expected_workflow_path) do
    %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expected_workflow_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:rondo]}
      end,
      run_once: fn issue_id ->
        send(parent, {:run_once, issue_id})
        :ok
      end,
      run_manifest: fn manifest_path ->
        send(parent, {:run_manifest, manifest_path})
        :ok
      end
    }
  end
end
