defmodule Rondo.CodexAdapterTest do
  use Rondo.TestSupport

  alias Rondo.Agent.Adapter
  alias Rondo.Agent.CodexAdapter

  test "codex adapter probe reports missing command" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_adapter: "codex",
      codex_command: "rondo-missing-codex-#{System.unique_integer([:positive])}"
    )

    assert %{status: :missing, checks: %{command: :missing, stream_parser: :ok, resume: :thread_id}} =
             CodexAdapter.probe()
  end

  test "codex adapter wraps codex exec JSONL and returns normalized events" do
    test_root = Path.join(System.tmp_dir!(), "rondo-codex-adapter-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CODEX")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      case "$*" in
        *"--help"*)
          echo 'codex exec --help'
          echo '  --model'
          exit 0
          ;;
      esac

      echo '{"type":"thread.started","thread_id":"codex-thread-1"}'
      echo '{"type":"turn.started"}'
      echo '{"type":"item.started","item":{"id":"tool-1","type":"command_execution","command":"mix test","aggregated_output":"","exit_code":null,"status":"in_progress"}}'
      echo '{"type":"item.updated","item":{"id":"tool-2","type":"mcp_tool_call","server":"mcp","tool":"search","arguments":{"query":"codex"}}}'
      echo '{"type":"item.updated","item":{"id":"tool-3","type":"collab_tool_call","tool":"review","prompt":"please check"}}'
      echo '{"type":"item.completed","item":{"id":"patch-1","type":"file_change","changes":[{"path":"lib/rondo.ex","kind":"update"}],"status":"completed"}}'
      echo '{"type":"item.completed","item":{"id":"msg-1","type":"agent_message","text":"Codex final"}}'
      echo '{"type":"turn.failed","error":{"message":"boom"}}'
      echo '{"type":"error","message":"hard failure"}'
      echo '{"type":"item.started","item":{"id":"mystery","type":"weird_type"}}'
      echo '{"type":"turn.completed","usage":{"input_tokens":12,"cached_input_tokens":3,"output_tokens":5,"reasoning_output_tokens":2}}'
      exit 0
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "codex",
        codex_command: codex_binary
      )

      parent = self()

      assert {:ok, result} =
               CodexAdapter.invoke(%{
                 prompt: "do work",
                 workspace: workspace,
                 previous_run_ref: nil,
                 on_event: fn event -> send(parent, {:adapter_event, event}) end,
                 opts: []
               })

      assert result.run_ref == Adapter.run_ref("codex", "codex-thread-1", "thread_id", true)
      assert result.usage == %{input_tokens: 12, output_tokens: 7, cache_read_tokens: 3, cache_write_tokens: 0, total_tokens: 22, cost: nil}
      assert result.final_report == "Codex final"
      assert result.capabilities.resume == :thread_id
      assert result.probe.status == :degraded
      assert result.probe.checks.model_selection == :ok

      assert_receive {:adapter_event, %{event_type: :session_started, adapter: "codex", run_ref: %{provider_ref: "codex-thread-1"}}}, 500
      assert_receive {:adapter_event, %{event_type: :turn_started, adapter: "codex"}}, 500
      assert_receive {:adapter_event, %{event_type: :assistant_message, adapter: "codex", message: "Codex final"}}, 500
      assert_receive {:adapter_event, %{event_type: :tool_started, adapter: "codex", message: message}}, 500
      assert message =~ "mix test"
      assert_receive {:adapter_event, %{event_type: :tool_updated, adapter: "codex", message: "mcp/search: query=codex"}}, 500
      assert_receive {:adapter_event, %{event_type: :tool_updated, adapter: "codex", message: "review: please check"}}, 500
      assert_receive {:adapter_event, %{event_type: :diff_updated, adapter: "codex", diff: %{status: "completed"}}}, 500
      assert_receive {:adapter_event, %{event_type: :invocation_failed, adapter: "codex", message: "boom"}}, 500
      assert_receive {:adapter_event, %{event_type: :invocation_failed, adapter: "codex", message: "hard failure"}}, 500
      assert_receive {:adapter_event, %{event_type: :invocation_completed, adapter: "codex", final_report: "Codex final"}}, 500
    after
      File.rm_rf(test_root)
    end
  end

  test "codex adapter reports unsupported resumes and invalid workspaces" do
    test_root = Path.join(System.tmp_dir!(), "rondo-codex-adapter-errors-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CODEX-ERRORS")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      case "$*" in
        *"--help"*)
          echo 'codex exec --help'
          echo '  --model'
          exit 0
          ;;
      esac

      echo '{"type":"thread.started","thread_id":"codex-thread-errors"}'
      echo '{"type":"turn.completed"}'
      exit 0
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "codex",
        codex_command: codex_binary
      )

      invalid_workspace = Path.join(test_root, "outside")
      File.mkdir_p!(invalid_workspace)

      assert {:error, {:invalid_workspace_cwd, _reason}} =
               CodexAdapter.invoke(%{
                 prompt: "Do not run",
                 workspace: invalid_workspace,
                 previous_run_ref: nil,
                 on_event: fn _event -> :ok end,
                 opts: []
               })

      previous_run_ref = %{
        provider_ref_kind: "thread_id",
        provider_ref: "codex-thread-prev",
        resumable?: false
      }

      assert {:error, {:resume_unsupported, ^previous_run_ref}} =
               CodexAdapter.invoke(%{
                 prompt: "Continue",
                 workspace: workspace,
                 previous_run_ref: previous_run_ref,
                 on_event: fn _event -> :ok end,
                 opts: []
               })

      assert {:error, {:invalid_resume_ref, %{provider_ref_kind: "other", provider_ref: "missing", resumable?: true}}} =
               CodexAdapter.invoke(%{
                 prompt: "Continue",
                 workspace: workspace,
                 previous_run_ref: %{provider_ref_kind: "other", provider_ref: "missing", resumable?: true, extra: true},
                 on_event: fn _event -> :ok end,
                 opts: []
               })
    after
      File.rm_rf(test_root)
    end
  end
end
