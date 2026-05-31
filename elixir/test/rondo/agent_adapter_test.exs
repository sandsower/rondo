defmodule Rondo.AgentAdapterTest do
  use Rondo.TestSupport

  alias Rondo.Agent.Adapter
  alias Rondo.Agent.ClaudeCodeAdapter
  alias Rondo.Agent.PiAdapter

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

  defmodule FakeProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "fake_process"

    @impl true
    def capabilities, do: %{gate_selection: :test, prompt: :test}

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{available: :ok}}

    @impl true
    def select_gates(_opts \\ []) do
      {:ok, [%{name: "provider-proof", command: "echo provider > provider-gate.txt", timeout_ms: 1_000, action_id: nil, action_classes: ["read"]}]}
    end

    @impl true
    def select_guides(_opts \\ []), do: {:ok, []}

    @impl true
    def prompt(%Rondo.Linear.Issue{} = issue, _opts \\ []), do: "Provider prompt for #{issue.identifier}"

    @impl true
    def model_routing_hints(_opts \\ []), do: %{}

    @impl true
    def proof_requirements(_opts \\ []), do: {:ok, []}

    @impl true
    def evaluate_action_policy(action, classes, opts \\ []) do
      {:ok,
       %{
         "decision" => "allow",
         "action" => action,
         "classes" => classes,
         "mode" => Keyword.fetch!(opts, :mode),
         "provider" => "fake_process"
       }}
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

  test "config exposes agent.adapter with claude_code default and pi config" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_adapter: nil)
    assert Config.agent_adapter() == "claude_code"
    assert Config.pi_command() == "pi"
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), agent_adapter: "fake")

    assert {:error, {:invalid_workflow_config, _, [%{path: "agent.adapter", value: "fake"}]}} =
             Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), agent_adapter: "pi", claude_command: "", pi_command: "pi")
    assert Config.agent_adapter() == "pi"
    assert Config.pi_command() == "pi"
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), agent_adapter: "claude_code", claude_command: "claude", pi_command: "")
    assert Config.agent_adapter() == "claude_code"
    assert :ok = Config.validate!()
  end

  test "pi adapter probe reports missing command" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_adapter: "pi",
      pi_command: "rondo-missing-pi-#{System.unique_integer([:positive])}"
    )

    assert %{status: :missing, checks: %{command: :missing, stream_parser: :ok, resume: :degraded}} = PiAdapter.probe()
  end

  test "claude code adapter probe reports missing command" do
    write_workflow_file!(Workflow.workflow_file_path(), claude_command: "rondo-missing-claude-#{System.unique_integer([:positive])}")

    assert %{status: :missing, checks: %{command: :missing, stream_parser: :ok, resume: :ok}} = ClaudeCodeAdapter.probe()
  end

  test "claude code adapter rejects workspaces outside configured root before invoking CLI" do
    test_root = Path.join(System.tmp_dir!(), "rondo-claude-code-adapter-workspace-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo should-not-run > #{Path.join(test_root, "invoked")}
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      assert {:error, {:invalid_workspace_cwd, :outside_root}} =
               ClaudeCodeAdapter.invoke(%{
                 prompt: "do work",
                 workspace: outside_workspace,
                 previous_run_ref: nil,
                 on_event: fn _event -> :ok end,
                 opts: []
               })

      refute File.exists?(Path.join(test_root, "invoked"))
    after
      File.rm_rf(test_root)
    end
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

  test "agent runner forwards result-only adapter metadata through compatibility updates" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-result-only-adapter-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-result-only",
        identifier: "MT-RESULT",
        title: "Result-only adapter metadata",
        description: "No completion stream event",
        state: "In Progress",
        labels: []
      }

      parent = self()

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 test_pid: parent
               )

      assert_receive {:claude_worker_update, "issue-result-only",
                      %{
                        event: :invocation_completed,
                        adapter: "fake",
                        run_ref: %{provider_ref: "fake-run-1"},
                        usage: %{total_tokens: 3},
                        capabilities: %{final_report: :final},
                        final_report: "fake final 1",
                        raw: %{raw: %{invocation: 1}}
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

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-FAKE"))
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

  test "agent runner routes prompt, gate selection, and policy through process provider" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-process-provider-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-PROVIDER/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, max_turns: 1, gates: nil)

      parent = self()

      issue = %Issue{
        id: "issue-provider",
        identifier: "MT-PROVIDER",
        title: "Provider proof",
        description: "Exercise process provider boundary",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: FakeProcessProvider,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
                 run_dir: run_dir,
                 test_pid: parent
               )

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-PROVIDER"))
      assert File.read!(Path.join(workspace, "provider-gate.txt")) == "provider\n"
      assert_receive {:fake_adapter_invoked, 1, "Provider prompt for MT-PROVIDER", ^workspace, nil}, 500

      assert_receive {
                       :claude_worker_update,
                       "issue-provider",
                       %{event: :gates_completed, raw: %{status: :pass, results: [result]}}
                     },
                     500

      assert result.policy_decision["provider"] == "fake_process"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner runs configured gates after successful turns" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-gates-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-GATES/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        gates: [%{name: "proof", command: "pwd > gate-pwd.txt", timeout_ms: 1_000}]
      )

      parent = self()

      issue = %Issue{
        id: "issue-gates",
        identifier: "MT-GATES",
        title: "Gate adapter proof",
        description: "Exercise gate boundary",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
                 run_dir: run_dir,
                 test_pid: parent
               )

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-GATES"))
      assert File.read!(Path.join(workspace, "gate-pwd.txt")) == workspace <> "\n"
      assert_receive {:claude_worker_update, "issue-gates", %{event: :gates_completed, raw: %{status: :pass} = raw}}, 500
      assert raw.results_path == "artifacts/gates/turn-0001/results.json"
      assert File.exists?(Path.join(run_dir, "artifacts/gates/turn-0001/results.json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner namespaces gate artifacts for each continuation turn" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-gate-turns-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-GATE-TURNS/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 2,
        gates: [%{name: "proof", command: "echo gate", timeout_ms: 1_000}]
      )

      parent = self()

      issue = %Issue{
        id: "issue-gate-turns",
        identifier: "MT-GATE-TURNS",
        title: "Gate turn proof",
        description: "Exercise gate artifact namespacing",
        state: "In Progress",
        labels: []
      }

      fetcher = fn [_issue_id] ->
        fetch_count = Process.get(:gate_turn_fetch_count, 0) + 1
        Process.put(:gate_turn_fetch_count, fetch_count)

        state = if fetch_count == 1, do: "In Progress", else: "Done"
        {:ok, [%{issue | state: state}]}
      end

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 issue_state_fetcher: fetcher,
                 run_dir: run_dir,
                 test_pid: parent
               )

      assert_receive {:claude_worker_update, "issue-gate-turns", %{event: :gates_completed, raw: first_raw}}, 500
      assert_receive {:claude_worker_update, "issue-gate-turns", %{event: :gates_completed, raw: second_raw}}, 500

      assert first_raw.results_path == "artifacts/gates/turn-0001/results.json"
      assert second_raw.results_path == "artifacts/gates/turn-0002/results.json"
      assert File.read!(Path.join(run_dir, first_raw.results_path)) =~ "turn-0001"
      assert File.read!(Path.join(run_dir, second_raw.results_path)) =~ "turn-0002"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner fails the run when a configured gate fails" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-gate-fail-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-GATE-FAIL/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        gates: [%{name: "proof", command: "exit 3", timeout_ms: 1_000}]
      )

      parent = self()

      issue = %Issue{
        id: "issue-gate-fail",
        identifier: "MT-GATE-FAIL",
        title: "Gate fail proof",
        description: "Exercise gate failure",
        state: "In Progress",
        labels: []
      }

      assert_raise RuntimeError, ~r/gate_failed/, fn ->
        AgentRunner.run(issue, parent,
          agent_adapter: FakeAdapter,
          issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
          run_dir: run_dir,
          test_pid: parent
        )
      end

      assert_receive {:claude_worker_update, "issue-gate-fail", %{event: :gates_completed, raw: %{status: :fail}}}, 500
    after
      File.rm_rf(test_root)
    end
  end

  test "pi adapter wraps pi CLI and returns normalized events" do
    test_root = Path.join(System.tmp_dir!(), "rondo-pi-adapter-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "S-PI")
      pi_binary = Path.join(test_root, "fake-pi")
      File.mkdir_p!(workspace)

      File.write!(pi_binary, """
      #!/bin/sh
      echo '{"type":"session","version":3,"id":"pi-adapter-session"}'
      echo '{"type":"agent_start"}'
      echo '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"ignored streaming"}}'
      echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"assistant fallback"}],"usage":{"input":4,"output":6}}}'
      echo '{"type":"tool_execution_start","toolCallId":"tool-1","toolName":"bash","args":{"command":"mix test"}}'
      echo '{"type":"agent_end","result":"explicit pi result","messages":[{"role":"assistant","content":[{"type":"text","text":"final from pi"}]}]}'
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "pi",
        pi_command: pi_binary
      )

      parent = self()

      assert {:ok, result} =
               PiAdapter.invoke(%{
                 prompt: "do work",
                 workspace: workspace,
                 previous_run_ref: nil,
                 on_event: fn event -> send(parent, {:adapter_event, event}) end,
                 opts: []
               })

      assert result.run_ref == Adapter.run_ref("pi", "pi-adapter-session", "session_id", true)
      assert result.usage == %{input_tokens: 4, output_tokens: 6, cache_read_tokens: 0, cache_write_tokens: 0, total_tokens: 10, cost: nil}
      assert result.final_report == "explicit pi result"
      assert result.capabilities.resume == :session_id
      assert result.capabilities.stop == :degraded_process_termination
      assert result.capabilities.approval == :degraded
      assert result.capabilities.final_report == :explicit_result_or_last_assistant_message

      assert_receive {:adapter_event, %{event_type: :session_started, adapter: "pi", run_ref: %{provider_ref: "pi-adapter-session"}}}, 500
      assert_receive {:adapter_event, %{event_type: :assistant_message, adapter: "pi", message: "assistant fallback"}}, 500
      assert_receive {:adapter_event, %{event_type: :tool_started, adapter: "pi", message: "bash"}}, 500
      assert_receive {:adapter_event, %{event_type: :invocation_completed, adapter: "pi", final_report: "explicit pi result"}}, 500
      refute_receive {:adapter_event, %{raw: %{"type" => "message_update"}}}, 100
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner can resolve pi adapter from config and preserve compatibility envelope" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-pi-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      pi_binary = Path.join(test_root, "fake-pi")
      File.mkdir_p!(workspace_root)

      File.write!(pi_binary, """
      #!/bin/sh
      echo '{"type":"session","version":3,"id":"runner-pi-session"}'
      echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Working"}]}}'
      echo '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"runner final"}]}]}'
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "pi",
        pi_command: pi_binary
      )

      issue = %Issue{
        id: "issue-pi",
        identifier: "MT-PI",
        title: "Pi adapter",
        description: "Run through pi",
        state: "In Progress",
        labels: []
      }

      parent = self()

      assert :ok =
               AgentRunner.run(issue, parent, issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end)

      assert_receive {:claude_worker_update, "issue-pi",
                      %{
                        event: :assistant_message,
                        adapter: "pi",
                        run_ref: %{provider_ref: "runner-pi-session"},
                        session_id: "runner-pi-session"
                      }},
                     500

      assert_receive {:claude_worker_update, "issue-pi",
                      %{
                        event: :invocation_completed,
                        final_report: "runner final",
                        raw: %{adapter: "pi"}
                      }},
                     500
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
