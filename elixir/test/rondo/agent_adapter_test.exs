defmodule Rondo.AgentAdapterTest do
  use Rondo.TestSupport

  alias Rondo.Agent.Adapter
  alias Rondo.Agent.ClaudeCodeAdapter
  alias Rondo.Agent.PiAdapter
  alias Rondo.ProcessProvider.Beislid

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
    def select_gates(opts \\ []) do
      gates = [%{name: "provider-proof", command: "echo provider > provider-gate.txt", timeout_ms: 1_000, action_id: nil, action_classes: ["read"]}]

      {:ok,
       Rondo.ProcessProvider.gate_selection_result(gates,
         selected: [%{name: "provider-proof", reason: "fake provider selected turn #{Keyword.get(opts, :turn_number)}"}],
         skipped: [%{name: "slow-proof", reason: "not needed for fake provider test"}],
         metadata: %{provider: id(), stage: Keyword.get(opts, :stage)}
       )}
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

  defmodule FailingGateSelectionProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "failing_gate_selection"

    @impl true
    def capabilities, do: %{gate_selection: :unavailable, prompt: :test}

    @impl true
    def probe(_opts \\ []), do: %{status: :missing, checks: %{gate_selection: :missing}}

    @impl true
    def select_gates(_opts \\ []), do: {:error, :provider_unavailable}

    @impl true
    def select_guides(_opts \\ []), do: {:ok, []}

    @impl true
    def prompt(%Rondo.Linear.Issue{} = issue, _opts \\ []), do: "Provider prompt for #{issue.identifier}"

    @impl true
    def model_routing_hints(_opts \\ []), do: %{}

    @impl true
    def proof_requirements(_opts \\ []), do: {:ok, []}

    @impl true
    def evaluate_action_policy(_action, _classes, _opts \\ []), do: {:error, :provider_unavailable}
  end

  defmodule EmptyGateSelectionProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "empty_gate_selection"

    @impl true
    def capabilities, do: %{gate_selection: :test, prompt: :test}

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{gate_selection: :ok}}

    @impl true
    def select_gates(_opts \\ []) do
      {:ok,
       Rondo.ProcessProvider.gate_selection_result([],
         skipped: [%{name: "slow-proof", reason: "not needed for documentation-only turn"}],
         metadata: %{provider: id(), stage: :post_turn}
       )}
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
      {:ok, %{"decision" => "allow", "action" => action, "classes" => classes, "mode" => Keyword.fetch!(opts, :mode)}}
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

  test "agent runner forwards action_policy_policy_file to workspace side-effect evaluations" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-policy-file-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      evaluator_path = Path.join(test_root, "beislid-argv-recorder")
      argv_file = Path.join(test_root, "argv.txt")

      File.write!(evaluator_path, """
      #!/bin/sh
      printf '%s ' "$@" >> '#{argv_file}'
      printf '\\n' >> '#{argv_file}'
      printf '{"decision":"allow","action":"x","mode":"unattended-auto","classes":[],"matched_rules":[],"requires_human":false,"log_level":"info","reason":"test","remediation":[]}'
      """)

      File.chmod!(evaluator_path, 0o755)

      policy_file = Path.join(test_root, "policy.json")
      File.write!(policy_file, ~s({"modes": {}}))

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: evaluator_path
      )

      issue = %Issue{
        id: "issue-policy-file",
        identifier: "MT-POLICY-FILE",
        title: "Policy file threading",
        description: "Workspace evaluations must receive the manifest policy file",
        state: "In Progress",
        labels: []
      }

      parent = self()

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 test_pid: parent,
                 action_policy_policy_file: policy_file
               )

      argv_lines = argv_file |> File.read!() |> String.split("\n", trim: true)
      assert argv_lines != []
      assert Enum.all?(argv_lines, &(&1 =~ "--policy-file #{policy_file}"))
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
                       %{
                         event: :gates_completed,
                         raw: %{status: :pass, results: [result], gate_selection: gate_selection}
                       }
                     },
                     500

      assert result.policy_decision["provider"] == "fake_process"
      assert gate_selection.selected == [%{name: "provider-proof", reason: "fake provider selected turn 1"}]
      assert gate_selection.skipped == [%{name: "slow-proof", reason: "not needed for fake provider test"}]
      assert gate_selection.metadata == %{provider: "fake_process", stage: :post_turn}
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner falls back to native gates when optional provider gate selection fails" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-provider-fallback-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-FALLBACK/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        process_provider_required: false,
        gates: [%{name: "native-proof", command: "echo native > native-gate.txt", timeout_ms: 1_000}]
      )

      parent = self()

      issue = %Issue{
        id: "issue-fallback",
        identifier: "MT-FALLBACK",
        title: "Provider fallback proof",
        description: "Exercise optional fallback",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: FailingGateSelectionProvider,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
                 run_dir: run_dir,
                 test_pid: parent
               )

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-FALLBACK"))
      assert File.read!(Path.join(workspace, "native-gate.txt")) == "native\n"

      assert_receive {
                       :claude_worker_update,
                       "issue-fallback",
                       %{event: :gates_completed, raw: %{gate_selection: gate_selection}}
                     },
                     500

      assert gate_selection.metadata.fallback_from == "failing_gate_selection"
      assert [%{message: message}] = gate_selection.warnings
      assert message =~ "provider_unavailable"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner does not fallback when optional beislid artifact has malformed action policy" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-beislid-bad-policy-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-BEISLID-BAD-POLICY/run-1")
      artifact_path = Path.join(test_root, "bad-policy.json")
      File.mkdir_p!(workspace_root)

      File.write!(
        artifact_path,
        Jason.encode!(%{
          "schema" => "beislid-process-artifact-v1",
          "id" => "bad-policy",
          "status" => "approved",
          "gates" => [%{"name" => "bad-policy-gate", "command" => "echo bad > bad-policy.txt"}],
          "action_policy" => %{"decision" => "maybe"}
        })
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        process_provider_kind: "beislid",
        process_provider_required: false,
        process_provider_artifact_path: artifact_path,
        gates: [%{name: "native-proof", command: "echo native > native-gate.txt", timeout_ms: 1_000}]
      )

      issue = %Issue{
        id: "issue-beislid-bad-policy",
        identifier: "MT-BEISLID-BAD-POLICY",
        title: "Bad policy proof",
        description: "Malformed present action_policy should fail closed",
        state: "In Progress",
        labels: []
      }

      assert_raise RuntimeError, ~r/process_provider_gate_selection_failed.*invalid_artifact_field.*action_policy/, fn ->
        AgentRunner.run(issue, self(),
          agent_adapter: FakeAdapter,
          process_provider: Beislid,
          issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
          run_dir: run_dir,
          test_pid: self()
        )
      end

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-BEISLID-BAD-POLICY"))
      refute File.exists?(Path.join(workspace, "native-gate.txt"))
      refute File.exists?(Path.join(workspace, "bad-policy.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner persists all-skipped provider gate selection explanations" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-empty-gates-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-EMPTY/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, max_turns: 1, gates: nil)

      parent = self()

      issue = %Issue{
        id: "issue-empty-gates",
        identifier: "MT-EMPTY",
        title: "Empty gate selection proof",
        description: "Exercise all-skipped gate selection metadata",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: EmptyGateSelectionProvider,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
                 run_dir: run_dir,
                 test_pid: parent
               )

      assert_receive {
                       :claude_worker_update,
                       "issue-empty-gates",
                       %{event: :gates_completed, raw: %{status: :pass, results: [], gate_selection: gate_selection}}
                     },
                     500

      assert gate_selection.skipped == [%{name: "slow-proof", reason: "not needed for documentation-only turn"}]
      assert gate_selection.metadata == %{provider: "empty_gate_selection", stage: :post_turn}

      results_json = run_dir |> Path.join("artifacts/gates/turn-0001/results.json") |> File.read!() |> Jason.decode!()
      assert results_json["gate_selection"]["skipped"] == [%{"name" => "slow-proof", "reason" => "not needed for documentation-only turn"}]
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner preflights required beislid provider before adapter invocation" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-beislid-preflight-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-BEISLID/run-1")
      hook_marker = "before-run-marker.txt"
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        process_provider_kind: "beislid",
        process_provider_required: true,
        process_provider_artifact_path: fixture_path("unapproved.json"),
        hook_before_run: "echo hook-ran > #{hook_marker}"
      )

      issue = %Issue{
        id: "issue-beislid-preflight",
        identifier: "MT-BEISLID",
        title: "Beislid preflight proof",
        description: "Strict provider preflight should stop before adapter invocation",
        state: "In Progress",
        labels: []
      }

      assert_raise RuntimeError, ~r/process_provider_preflight_failed.*beislid.*artifact_not_approved/, fn ->
        AgentRunner.run(issue, self(),
          agent_adapter: FakeAdapter,
          process_provider: Beislid,
          issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
          run_dir: run_dir,
          test_pid: self()
        )
      end

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-BEISLID"))
      assert File.read!(Path.join(workspace, hook_marker)) == "hook-ran\n"
      refute_received {:fake_adapter_invoked, _, _, _, _}
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner uses source_contract artifact for beislid gate selection" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-beislid-source-contract-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-BEISLID-SOURCE/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        process_provider_kind: "beislid",
        process_provider_artifact_path: fixture_path("unapproved.json")
      )

      parent = self()

      issue = %Issue{
        id: "issue-beislid-source",
        identifier: "MT-BEISLID-SOURCE",
        title: "Beislid source contract proof",
        description: "Provider gates should use source_contract artifact",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: Beislid,
                 source_contract: %{process_provider: %{"artifact_path" => fixture_path("approved.json")}},
                 issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
                 run_dir: run_dir,
                 test_pid: parent
               )

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-BEISLID-SOURCE"))
      assert File.read!(Path.join(workspace, "beislid-gate.txt")) == "beislid\n"

      assert_receive {
                       :claude_worker_update,
                       "issue-beislid-source",
                       %{event: :gates_completed, raw: %{gate_selection: gate_selection}}
                     },
                     500

      assert gate_selection.metadata.artifact_id == "beislid-fixture-approved"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner uses native action policy when beislid artifact has no fixture policy" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-beislid-no-policy-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-BEISLID-NO-POLICY/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        process_provider_kind: "beislid",
        process_provider_artifact_path: fixture_path("no_policy.json"),
        action_policy_command: fake_action_policy("allow")
      )

      parent = self()

      issue = %Issue{
        id: "issue-beislid-no-policy",
        identifier: "MT-BEISLID-NO-POLICY",
        title: "Beislid no policy proof",
        description: "Provider gates should fall back to native action policy",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: Beislid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
                 run_dir: run_dir,
                 test_pid: parent
               )

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-BEISLID-NO-POLICY"))
      assert File.read!(Path.join(workspace, "no-policy-gate.txt")) == "no-policy\n"

      assert_receive {
                       :claude_worker_update,
                       "issue-beislid-no-policy",
                       %{event: :gates_completed, raw: %{results: [result], gate_selection: gate_selection}}
                     },
                     500

      assert result.policy_decision["decision"] == "allow"
      refute result.policy_decision["provider"] == "beislid"
      assert gate_selection.metadata.action_policy_provider == "native"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner uses beislid provider artifact for prompt, gates, and policy" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-beislid-success-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-BEISLID-OK/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        process_provider_kind: "beislid",
        process_provider_artifact_path: fixture_path("approved.json")
      )

      parent = self()

      issue = %Issue{
        id: "issue-beislid-ok",
        identifier: "MT-BEISLID-OK",
        title: "Beislid success proof",
        description: "Provider selects fixture gate",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: Beislid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
                 run_dir: run_dir,
                 test_pid: parent
               )

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-BEISLID-OK"))
      assert File.read!(Path.join(workspace, "beislid-gate.txt")) == "beislid\n"
      assert_receive {:fake_adapter_invoked, 1, prompt, ^workspace, nil}, 500
      assert prompt =~ "Beislið process context"

      assert_receive {
                       :claude_worker_update,
                       "issue-beislid-ok",
                       %{event: :gates_completed, raw: %{results: [result], gate_selection: gate_selection}}
                     },
                     500

      assert result.policy_decision["provider"] == "beislid"
      assert gate_selection.metadata.provider == "beislid"
      assert gate_selection.metadata.artifact_id == "beislid-fixture-approved"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner falls back to native gates when optional beislid artifact is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-beislid-optional-fallback-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-BEISLID-FALLBACK/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        process_provider_kind: "beislid",
        process_provider_required: false,
        process_provider_artifact_path: "/tmp/rondo-missing-beislid-fallback.json",
        gates: [%{name: "native-proof", command: "echo native > native-gate.txt", timeout_ms: 1_000}]
      )

      parent = self()

      issue = %Issue{
        id: "issue-beislid-fallback",
        identifier: "MT-BEISLID-FALLBACK",
        title: "Beislid optional fallback proof",
        description: "Missing optional artifact should fall back to native gates",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: Beislid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
                 run_dir: run_dir,
                 test_pid: parent
               )

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-BEISLID-FALLBACK"))
      assert File.read!(Path.join(workspace, "native-gate.txt")) == "native\n"

      assert_receive {
                       :claude_worker_update,
                       "issue-beislid-fallback",
                       %{event: :gates_completed, raw: %{results: [result], gate_selection: gate_selection}}
                     },
                     500

      assert result.policy_decision["decision"] == "allow"
      refute result.policy_decision["provider"] == "beislid"
      assert gate_selection.metadata.fallback_from == "beislid"
      assert gate_selection.metadata.fallback_reason =~ "read_failed"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner fails clearly when required provider gate selection fails" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-provider-required-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-REQUIRED/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        process_provider_required: true,
        gates: [%{name: "native-proof", command: "echo native > native-gate.txt", timeout_ms: 1_000}]
      )

      issue = %Issue{
        id: "issue-required",
        identifier: "MT-REQUIRED",
        title: "Provider required proof",
        description: "Exercise required provider failure",
        state: "In Progress",
        labels: []
      }

      assert_raise RuntimeError, ~r/process_provider_gate_selection_failed.*provider_unavailable/, fn ->
        AgentRunner.run(issue, self(),
          agent_adapter: FakeAdapter,
          process_provider: FailingGateSelectionProvider,
          issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
          run_dir: run_dir,
          test_pid: self()
        )
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner uses native action policy for caller-provided flat gates" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-flat-gates-provider-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-FLAT/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        action_policy_command: fake_action_policy("allow")
      )

      parent = self()

      issue = %Issue{
        id: "issue-flat-gates",
        identifier: "MT-FLAT",
        title: "Flat gate provider proof",
        description: "Exercise caller-provided flat gates",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: FailingGateSelectionProvider,
                 gates: [%{name: "flat-proof", command: "echo flat > flat-gate.txt", timeout_ms: 1_000, action_classes: ["read"]}],
                 issue_state_fetcher: fn [_issue_id] -> {:ok, []} end,
                 run_dir: run_dir,
                 test_pid: parent
               )

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-FLAT"))
      assert File.read!(Path.join(workspace, "flat-gate.txt")) == "flat\n"

      assert_receive {
                       :claude_worker_update,
                       "issue-flat-gates",
                       %{event: :gates_completed, raw: %{results: [result]}}
                     },
                     500

      refute result.policy_decision["provider"] == "failing_gate_selection"
      assert result.policy_decision["decision"] == "allow"
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

  defp fake_action_policy(decision) do
    path = Path.join(System.tmp_dir!(), "rondo-agent-adapter-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/bin/sh
    action=""
    mode=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --action) action="$2"; shift 2 ;;
        --mode) mode="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '{"decision":"#{decision}","action":"%s","mode":"%s","classes":["read"]}' "$action" "$mode"
    """)

    File.chmod!(path, 0o755)
    path
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
      assert_receive {:adapter_event, %{event_type: :tool_started, adapter: "pi", message: "bash: command=mix test"}}, 500
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
      echo '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Working"}]},"usage":{"input":2,"output":3}}'
      echo '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"mix test"}}]}}'
      echo '{"type":"message","message":{"role":"toolResult","toolName":"bash","content":[{"type":"text","text":"ok"}]}}'
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
                        session_id: "runner-pi-session",
                        message: "Working"
                      }},
                     500

      assert_receive {:claude_worker_update, "issue-pi",
                      %{
                        event: :tool_started,
                        adapter: "pi",
                        message: "bash: command=mix test"
                      }},
                     500

      assert_receive {:claude_worker_update, "issue-pi",
                      %{
                        event: :tool_completed,
                        adapter: "pi",
                        message: "bash: ok"
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

  defp fixture_path(filename) do
    Path.expand(Path.join([__DIR__, "..", "fixtures", "beislid_process_provider", filename]))
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
