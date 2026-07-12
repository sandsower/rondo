defmodule Rondo.CLITest do
  use ExUnit.Case, async: true

  alias Rondo.CLI

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end
    }

    assert :ok = CLI.evaluate([], deps)
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

    assert :ok = CLI.evaluate([workflow_path], deps)
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

    assert :ok = CLI.evaluate(["--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
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

    assert {:error, message} = CLI.evaluate(["WORKFLOW.md"], deps)
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

    assert {:error, message} = CLI.evaluate(["WORKFLOW.md"], deps)
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

    assert :ok = CLI.evaluate(["WORKFLOW.md"], deps)
  end

  test "core mode starts trackerless on a dynamic port and publishes exact readiness" do
    parent = self()
    ready_file = Path.expand("tmp/core-ready.json")

    deps = %{
      file_regular?: fn _path -> flunk("core mode must not require a tracker workflow") end,
      set_workflow_file_path: fn _path -> flunk("core mode must not set a tracker workflow") end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn port ->
        send(parent, {:port, port})
        :ok
      end,
      set_service_mode: fn mode ->
        send(parent, {:service_mode, mode})
        :ok
      end,
      set_workspace_root: fn path ->
        send(parent, {:workspace_root, path})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:rondo]} end,
      core_readiness: fn ->
        {:ok,
         %{
           "surface" => "rondo.core/v1",
           "base_url" => "http://127.0.0.1:43123",
           "runtime_version" => "0.1.0",
           "instance_id" => "019b8941-4a0c-7ad5-b7ef-cb3c45e4a819",
           "service_mode" => "trackerless_core",
           "ready" => true,
           "active_run_count" => 0
         }}
      end,
      write_ready_file: fn path, readiness ->
        send(parent, {:ready_file, path, readiness})
        :ok
      end
    }

    assert :ok =
             CLI.evaluate(
               [
                 "core",
                 "--logs-root",
                 "tmp/core-logs",
                 "--workspace-root",
                 "tmp/core-workspaces",
                 "--port",
                 "0",
                 "--ready-file",
                 ready_file
               ],
               deps
             )

    assert_received {:logs_root, logs_root}
    assert logs_root == Path.expand("tmp/core-logs")
    assert_received {:port, 0}
    assert_received {:service_mode, :trackerless_core}
    assert_received {:workspace_root, "tmp/core-workspaces"}
    assert_received {:ready_file, ^ready_file, readiness}
    assert readiness["base_url"] == "http://127.0.0.1:43123"
    assert readiness["service_mode"] == "trackerless_core"
  end

  test "core mode reports runtime option setter failures without crashing" do
    base_deps = %{
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_workspace_root: fn _path -> :ok end,
      set_service_mode: fn _mode -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end,
      core_readiness: fn -> {:error, :not_expected} end,
      write_ready_file: fn _path, _readiness -> :ok end
    }

    logs_failure = Map.put(base_deps, :set_logs_root, fn _path -> {:error, :logs_failed} end)

    assert {:error, "Failed to start Rondo Core: :logs_failed"} =
             CLI.evaluate(
               ["core", "--logs-root", "tmp/core-logs", "--ready-file", "tmp/core-ready.json"],
               logs_failure
             )

    port_failure = Map.put(base_deps, :set_server_port_override, fn _port -> {:error, :port_failed} end)

    assert {:error, "Failed to start Rondo Core: :port_failed"} =
             CLI.evaluate(
               ["core", "--port", "0", "--ready-file", "tmp/core-ready.json"],
               port_failure
             )
  end

  test "core mode requires one nonblank readiness path before startup" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> flunk("invalid core invocation must not start Rondo") end
    }

    for args <- [["core"], ["core", "--ready-file", ""], ["core", "--ready-file", "a", "--ready-file", "b"]] do
      assert {:error, message} = CLI.evaluate(args, deps)
      assert message =~ "rondo core"
    end
  end

  test "run-once starts dependency applications and runs selected issue without starting daemon" do
    parent = self()
    workflow_path = "tmp/run-once/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = run_once_deps(parent, expanded_path)

    assert :run_once_completed = CLI.evaluate(["run-once", workflow_path, "--issue", "123"], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
    assert_received :run_once_dependencies_started
    assert_received {:run_once, "123"}
    refute_received :started
  end

  test "run-once starts dependency applications and runs selected manifest without starting daemon" do
    parent = self()
    workflow_path = "tmp/run-once/WORKFLOW.md"
    manifest_path = "tmp/request.json"
    expanded_path = Path.expand(workflow_path)
    expanded_manifest_path = Path.expand(manifest_path)

    deps = run_once_deps(parent, expanded_path)

    assert :run_once_completed = CLI.evaluate(["run-once", workflow_path, "--manifest", manifest_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
    assert_received :run_once_dependencies_started
    assert_received {:run_manifest, ^expanded_manifest_path}
    refute_received :run_once
    refute_received :started
  end

  test "run-once forwards explicit bypass intent for authoritative issue and manifest policy" do
    parent = self()
    workflow_path = "tmp/run-once/WORKFLOW.md"
    deps = run_once_deps(parent, Path.expand(workflow_path))

    deps =
      Map.put(deps, :run_once, fn issue_id, opts ->
        send(parent, {:run_once_with_opts, issue_id, opts})
        :ok
      end)

    assert :run_once_completed =
             CLI.evaluate(
               ["run-once", workflow_path, "--issue", "123", "--unsafe-child-credential-bypass"],
               deps
             )

    assert_received {:run_once_with_opts, "123", opts}
    assert Keyword.get(opts[:agent_opts], :dispatch_origin) == :run_once
    assert Keyword.get(opts[:agent_opts], :unsafe_child_credential_bypass) === true

    deps =
      Map.put(deps, :run_manifest, fn manifest_path, opts ->
        send(parent, {:run_manifest_with_opts, manifest_path, opts})
        :ok
      end)

    assert :run_once_completed =
             CLI.evaluate(
               ["run-once", workflow_path, "--manifest", "request.json", "--unsafe-child-credential-bypass"],
               deps
             )

    assert_received {:run_manifest_with_opts, _path, manifest_opts}
    assert Keyword.get(manifest_opts[:agent_opts], :dispatch_origin) == :manifest
    assert Keyword.get(manifest_opts[:agent_opts], :unsafe_child_credential_bypass) === true
  end

  test "run-once rejects both issue and manifest" do
    deps = run_once_deps(self(), Path.expand("WORKFLOW.md"))

    assert {:error, message} = CLI.evaluate(["run-once", "WORKFLOW.md", "--issue", "123", "--manifest", "request.json"], deps)
    assert message =~ "rondo run-once"
  end

  test "run-once rejects duplicate issue or manifest flags" do
    deps = run_once_deps(self(), Path.expand("WORKFLOW.md"))

    assert {:error, message} = CLI.evaluate(["run-once", "WORKFLOW.md", "--issue", "123", "--issue", "456"], deps)
    assert message =~ "rondo run-once"

    assert {:error, message} = CLI.evaluate(["run-once", "WORKFLOW.md", "--manifest", "one.json", "--manifest", "two.json"], deps)
    assert message =~ "rondo run-once"
  end

  test "run-once returns usage when the workflow positional is missing with one switch" do
    deps = run_once_deps(self(), Path.expand("WORKFLOW.md"))

    for args <- [
          ["run-once", "--manifest", "request.json"],
          ["run-once", "--issue", "RON-160"]
        ] do
      assert {:error, message} = CLI.evaluate(args, deps)
      assert message =~ "Usage: rondo"
      assert message =~ "rondo run-once"
    end
  end

  test "run-once rejects extra positional arguments" do
    deps = run_once_deps(self(), Path.expand("WORKFLOW.md"))

    assert {:error, message} = CLI.evaluate(["run-once", "WORKFLOW.md", "extra.md", "--issue", "123"], deps)
    assert message =~ "Usage: rondo"
  end

  test "run-once treats blank targets as absent during validation and dispatch" do
    parent = self()
    workflow_path = "tmp/run-once/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)
    deps = run_once_deps(parent, expanded_path)

    assert :run_once_completed = CLI.evaluate(["run-once", workflow_path, "--issue", "123", "--manifest", ""], deps)
    assert_received {:run_once, "123"}
    refute_received {:run_manifest, _}

    assert :run_once_completed = CLI.evaluate(["run-once", workflow_path, "--issue", "", "--manifest", "request.json"], deps)
    assert_received {:run_manifest, manifest_path}
    assert manifest_path == Path.expand("request.json")
  end

  test "run-once requires an issue id or manifest" do
    deps = run_once_deps(self(), Path.expand("WORKFLOW.md"))

    assert {:error, message} = CLI.evaluate(["run-once", "WORKFLOW.md"], deps)
    assert message =~ "rondo run-once"
  end

  test "run-once returns workflow not found" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end,
      ensure_run_once_dependencies_started: fn -> {:ok, [:req]} end,
      run_once: fn _issue_id, _opts -> :ok end,
      run_manifest: fn _manifest_path, _opts -> :ok end
    }

    assert {:error, message} = CLI.evaluate(["run-once", "WORKFLOW.md", "--issue", "123"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "run-once returns dependency startup errors before dispatch" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end,
      ensure_run_once_dependencies_started: fn -> {:error, {:req, :boom}} end,
      run_once: fn _issue_id, _opts -> flunk("run-once should not dispatch when dependencies fail") end,
      run_manifest: fn _manifest_path, _opts -> flunk("run-once should not dispatch when dependencies fail") end
    }

    assert {:error, message} = CLI.evaluate(["run-once", "WORKFLOW.md", "--issue", "123"], deps)
    assert message =~ "Failed to start run-once dependencies for workflow"
    assert message =~ ":req"
    assert message =~ ":boom"
  end

  test "run-once returns runner errors" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end,
      run_once: fn "123", _opts -> {:error, :boom} end,
      run_manifest: fn _manifest_path, _opts -> :ok end
    }

    assert {:error, message} = CLI.evaluate(["run-once", "WORKFLOW.md", "--issue", "123"], deps)
    assert message =~ "run-once failed for issue 123: :boom"
  end

  test "run-once rejects runners that cannot receive security provenance options" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:rondo]} end,
      run_once: fn _issue_id -> :ok end,
      run_manifest: fn _manifest_path, _opts -> :ok end
    }

    assert {:error, message} = CLI.evaluate(["run-once", "WORKFLOW.md", "--issue", "123"], deps)
    assert message =~ "invalid_runner_contract"
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
      ensure_run_once_dependencies_started: fn ->
        send(parent, :run_once_dependencies_started)
        {:ok, [:req]}
      end,
      run_once: fn issue_id, _opts ->
        send(parent, {:run_once, issue_id})
        :ok
      end,
      run_manifest: fn manifest_path, _opts ->
        send(parent, {:run_manifest, manifest_path})
        :ok
      end
    }
  end
end
