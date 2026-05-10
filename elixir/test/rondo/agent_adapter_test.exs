defmodule Rondo.AgentAdapterTest do
  use Rondo.TestSupport

  alias Rondo.Agent.Adapter
  alias Rondo.Agent.ClaudeCodeAdapter

  defmodule FakeAdapter do
    @behaviour Rondo.Agent.Adapter

    @impl true
    def id, do: "fake"

    @impl true
    def capabilities do
      %{
        launch: :in_process,
        streaming: true,
        resume: :run_ref,
        stop: :unsupported,
        approval: :unsupported,
        usage: :final,
        rate_limits: :unsupported,
        diff: :unsupported,
        final_report: :final
      }
    end

    @impl true
    def probe(_opts \\ []) do
      %{status: :ok, checks: %{available: :ok}}
    end

    @impl true
    def invoke(%{prompt: prompt, workspace: workspace, previous_run_ref: previous_run_ref, on_event: on_event, opts: opts}) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      invocation = Process.get(:fake_adapter_invocation, 0) + 1
      Process.put(:fake_adapter_invocation, invocation)

      send(test_pid, {:fake_adapter_invoked, invocation, prompt, workspace, previous_run_ref})

      run_ref = Adapter.run_ref(id(), "fake-run-#{invocation}", "fake_run_id", true)

      on_event.(
        Adapter.event(:session_started,
          adapter: id(),
          run_ref: run_ref,
          usage: %{input_tokens: invocation, output_tokens: 2, total_tokens: invocation + 2},
          raw: %{"type" => "fake.started", "invocation" => invocation}
        )
      )

      {:ok,
       Adapter.result(
         run_ref: run_ref,
         final_report: "fake final #{invocation}",
         usage: %{input_tokens: invocation, output_tokens: 2, total_tokens: invocation + 2},
         capabilities: capabilities(),
         raw: %{invocation: invocation}
       )}
    end
  end

  defmodule NonResumableFakeAdapter do
    @behaviour Rondo.Agent.Adapter

    @impl true
    def id, do: "non_resumable_fake"

    @impl true
    def capabilities, do: %{resume: :unsupported, streaming: true}

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{available: :ok}}

    @impl true
    def invoke(%{previous_run_ref: nil} = request) do
      on_event = Map.fetch!(request, :on_event)
      run_ref = Adapter.run_ref(id(), "first-only", "fake_run_id", false)
      on_event.(Adapter.event(:session_started, adapter: id(), run_ref: run_ref, raw: %{"type" => "fake.started"}))
      {:ok, Adapter.result(run_ref: run_ref, capabilities: capabilities(), final_report: "done")}
    end

    def invoke(%{previous_run_ref: previous_run_ref}) do
      {:error, {:resume_unsupported, previous_run_ref}}
    end
  end

  test "adapter helpers build provider-neutral run refs, events, results, and probes" do
    run_ref = Adapter.run_ref("fake", "native-123", "thread_id", true)

    assert run_ref == %{
             adapter: "fake",
             provider_ref: "native-123",
             provider_ref_kind: "thread_id",
             resumable?: true
           }

    event = Adapter.event(:assistant_message, adapter: "fake", run_ref: run_ref, raw: %{"type" => "message"})
    assert event.event_type == :assistant_message
    assert event.adapter == "fake"
    assert event.run_ref == run_ref
    assert event.raw == %{"type" => "message"}

    result = Adapter.result(run_ref: run_ref, final_report: "done", usage: %{total_tokens: 1})
    assert result.run_ref == run_ref
    assert result.final_report == "done"
    assert result.usage == %{total_tokens: 1}

    assert Adapter.probe_result(:degraded, %{binary: :missing}).status == :degraded
  end

  test "config exposes agent.adapter with claude_code default" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_adapter: nil)
    assert Config.agent_adapter() == "claude_code"
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), agent_adapter: "fake")
    assert Config.agent_adapter() == "fake"
  end

  test "claude code adapter wraps Claude CLI and returns a provider-neutral run ref" do
    test_root = Path.join(System.tmp_dir!(), "rondo-claude-code-adapter-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "S-1")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"session-adapter"}'
      echo '{"type":"assistant","session_id":"session-adapter","message":{"content":[{"type":"text","text":"assistant fallback"}]}}'
      echo '{"type":"result","session_id":"session-adapter","result":"final from claude","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      parent = self()

      assert {:ok, result} =
               ClaudeCodeAdapter.invoke(%{
                 prompt: "do work",
                 workspace: workspace,
                 previous_run_ref: nil,
                 on_event: fn event -> send(parent, {:adapter_event, event}) end,
                 opts: []
               })

      assert result.run_ref == Adapter.run_ref("claude_code", "session-adapter", "session_id", true)
      assert result.usage == %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
      assert result.final_report == "final from claude"
      assert result.capabilities.resume == :session_id

      assert_receive {:adapter_event,
                      %{
                        event_type: :session_started,
                        adapter: "claude_code",
                        run_ref: %{provider_ref: "session-adapter"}
                      }},
                     500

      assert_receive {:adapter_event,
                      %{
                        event_type: :invocation_completed,
                        adapter: "claude_code",
                        usage: %{total_tokens: 15},
                        final_report: "final from claude"
                      }},
                     500

      refute_receive {:adapter_event, %{event_type: :invocation_completed}}, 100
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner preserves Claude worker update compatibility while carrying adapter metadata" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-claude-compat-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace_root)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"session-compat"}'
      echo '{"type":"assistant","session_id":"session-compat","message":{"content":[{"type":"text","text":"Working"}]}}'
      echo '{"type":"result","session_id":"session-compat","result":"compat final","usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-compat",
        identifier: "MT-COMPAT",
        title: "Claude compatibility",
        description: "Keep legacy event envelope stable",
        state: "In Progress",
        labels: []
      }

      parent = self()

      assert :ok =
               AgentRunner.run(issue, parent, issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end)

      assert_receive {:claude_worker_update, "issue-compat",
                      %{
                        event: :assistant,
                        adapter: "claude_code",
                        run_ref: %{provider_ref: "session-compat"},
                        session_id: "session-compat",
                        raw: %{"type" => "assistant", "message" => %{"content" => [%{"text" => "Working"}]}}
                      }},
                     500

      assert_receive {:claude_worker_update, "issue-compat",
                      %{
                        event: :result,
                        final_report: "compat final",
                        raw: %{"type" => "result", "result" => "compat final"}
                      }},
                     500
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner can use a fake adapter for first invocation, continuation, and events" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-fake-adapter-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 2
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:fake_adapter_fetch_count, 0) + 1
        Process.put(:fake_adapter_fetch_count, attempt)

        state = if attempt == 1, do: "In Progress", else: "Done"

        {:ok,
         [
           %Issue{
             id: "issue-fake",
             identifier: "MT-FAKE",
             title: "Fake adapter proof",
             description: "Exercise adapter boundary",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-fake",
        identifier: "MT-FAKE",
        title: "Fake adapter proof",
        description: "Exercise adapter boundary",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 issue_state_fetcher: state_fetcher,
                 test_pid: parent
               )

      workspace = Path.join(workspace_root, "MT-FAKE")
      assert_receive {:fake_adapter_invoked, 1, first_prompt, ^workspace, nil}, 500
      assert first_prompt =~ "You are an agent for this repository."

      assert_receive {:fake_adapter_invoked, 2, continuation_prompt, ^workspace, previous_run_ref}, 500
      assert continuation_prompt =~ "Continuation guidance"
      assert previous_run_ref == Adapter.run_ref("fake", "fake-run-1", "fake_run_id", true)

      assert_receive {:claude_worker_update, "issue-fake", %{event: :session_started, session_id: nil, raw: %{adapter: "fake"}}}, 500
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner fails explicitly when a non-resumable adapter is asked to continue" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-nonresumable-adapter-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-nonresumable",
             identifier: "MT-NONRESUME",
             title: "Non resumable adapter",
             description: "Should fail clearly",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-nonresumable",
        identifier: "MT-NONRESUME",
        title: "Non resumable adapter",
        description: "Should fail clearly",
        state: "In Progress",
        labels: []
      }

      assert_raise RuntimeError, ~r/resume_unsupported/, fn ->
        AgentRunner.run(issue, nil,
          agent_adapter: NonResumableFakeAdapter,
          issue_state_fetcher: state_fetcher
        )
      end
    after
      File.rm_rf(test_root)
    end
  end
end
