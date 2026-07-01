defmodule Rondo.AgentAdapterTest do
  use Rondo.TestSupport

  alias Rondo.Agent.Adapter
  alias Rondo.Agent.ClaudeCodeAdapter
  alias Rondo.Agent.PiAdapter
  alias Rondo.ProcessProvider.Beislid
  alias Rondo.RunLedger

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

      maybe_touch_workspace(workspace, invocation, opts)

      send(test_pid, {:fake_adapter_invoked, invocation, prompt, workspace, previous_run_ref})
      send(test_pid, {:fake_adapter_opts, opts})

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
         final_report: fake_final_report(invocation, opts),
         usage: %{input_tokens: invocation, output_tokens: 2, total_tokens: invocation + 2},
         capabilities: capabilities(),
         raw: %{invocation: invocation}
       )}
    end

    defp fake_final_report(invocation, opts) do
      case Keyword.get(opts, :fake_final_reports) do
        reports when is_map(reports) -> Map.get(reports, invocation, "fake final #{invocation}")
        reports when is_list(reports) -> Enum.at(reports, invocation - 1, "fake final #{invocation}")
        _other -> "fake final #{invocation}"
      end
    end

    defp maybe_touch_workspace(workspace, invocation, opts) do
      case Keyword.get(opts, :touch_workspace_on_invocation) do
        ^invocation ->
          path = Keyword.get(opts, :touch_workspace_path, "fake-adapter-change.txt")
          contents = Keyword.get(opts, :touch_workspace_contents, "changed #{invocation}\n")
          File.write!(Path.join(workspace, path), contents)

        _ ->
          :ok
      end
    end
  end

  defmodule RoutingFallbackAdapter do
    @behaviour Rondo.Agent.Adapter

    @impl true
    def id, do: "routing_fallback"

    @impl true
    def capabilities, do: FakeAdapter.capabilities()

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{available: :ok}}

    @impl true
    def invoke(%{prompt: _prompt, workspace: workspace, previous_run_ref: previous_run_ref, on_event: on_event, opts: opts}) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      failure_mode = Keyword.get(opts, :failure_mode, :codex_quota)
      invocation = Process.get({:routing_fallback_invocation, failure_mode}, 0) + 1
      Process.put({:routing_fallback_invocation, failure_mode}, invocation)

      maybe_touch_workspace(workspace, invocation, opts)

      send(test_pid, {:routing_fallback_invoked, failure_mode, invocation, Keyword.get(opts, :model), previous_run_ref})
      send(test_pid, {:routing_fallback_opts, failure_mode, opts})

      run_ref = Adapter.run_ref(id(), "routing-run-#{failure_mode}-#{invocation}", "routing_run_id", true)

      case {failure_mode, invocation} do
        {:codex_quota, 1} ->
          on_event.(failure_event("Codex error: The usage limit has been reached", run_ref))
          {:error, {:subprocess_exit, 1}}

        {:openrouter_rate_limit, 1} ->
          on_event.(failure_event("OpenRouter error: rate limited", run_ref))
          {:error, {:subprocess_exit, 1}}

        {:plain_failure, _invocation} ->
          on_event.(failure_event("Implementation failure: something went wrong", run_ref))
          {:error, {:subprocess_exit, 1}}

        _ ->
          on_event.(
            Adapter.event(:session_started,
              adapter: id(),
              run_ref: run_ref,
              usage: %{input_tokens: invocation, output_tokens: 4, total_tokens: invocation + 4},
              raw: %{"type" => "routing.started", "invocation" => invocation}
            )
          )

          on_event.(
            Adapter.event(:invocation_completed,
              adapter: id(),
              run_ref: run_ref,
              usage: %{input_tokens: invocation, output_tokens: 4, total_tokens: invocation + 4},
              final_report: "routing final #{failure_mode} #{invocation}",
              raw: %{invocation: invocation}
            )
          )

          {:ok,
           Adapter.result(
             run_ref: run_ref,
             final_report: "routing final #{failure_mode} #{invocation}",
             usage: %{input_tokens: invocation, output_tokens: 4, total_tokens: invocation + 4},
             capabilities: capabilities(),
             raw: %{invocation: invocation}
           )}
      end
    end

    defp failure_event(message, run_ref) do
      Adapter.event(:assistant_message,
        adapter: id(),
        run_ref: run_ref,
        message: message,
        raw: %{"message" => message}
      )
    end

    defp maybe_touch_workspace(workspace, invocation, opts) do
      case Keyword.get(opts, :touch_workspace_on_invocation) do
        ^invocation ->
          path = Keyword.get(opts, :touch_workspace_path, "routing-fallback-change.txt")
          contents = Keyword.get(opts, :touch_workspace_contents, "changed #{invocation}\n")
          File.write!(Path.join(workspace, path), contents)

        _ ->
          :ok
      end
    end
  end

  defp start_update_recorder(test_pid, ledger \\ nil) do
    spawn_link(fn -> update_recorder_loop(test_pid, ledger) end)
  end

  defp update_recorder_loop(test_pid, ledger) do
    receive do
      {:set_ledger, %RunLedger{} = new_ledger} ->
        update_recorder_loop(test_pid, new_ledger)

      {:claude_worker_update, issue_id, %{event: :model_routing_decision} = update} ->
        ledger =
          case {ledger, Map.get(update, :model_routing)} do
            {%RunLedger{} = current_ledger, %{} = routing} ->
              case RunLedger.record_model_routing_decision(current_ledger, routing, source: Map.get(update, :source, %{})) do
                {:ok, updated_ledger} -> updated_ledger
                {:error, _reason} -> current_ledger
              end

            _other ->
              ledger
          end

        send(test_pid, {:claude_worker_update, issue_id, update})
        update_recorder_loop(test_pid, ledger)

      message ->
        send(test_pid, message)
        update_recorder_loop(test_pid, ledger)
    end
  end

  defmodule ChangedFileProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "changed_file_process"

    @impl true
    def capabilities, do: %{gate_selection: :test, prompt: :test}

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{available: :ok}}

    @impl true
    def select_gates(opts \\ []) do
      changed_files = Keyword.get(opts, :changed_files, [])
      selector_metadata = Keyword.get(opts, :changed_files_metadata, %{})

      gates =
        if "src/change.txt" in changed_files do
          [%{name: "changed-proof", command: "echo changed > changed-gate.txt", timeout_ms: 1_000, action_id: nil, action_classes: ["read"]}]
        else
          []
        end

      {:ok,
       Rondo.ProcessProvider.gate_selection_result(gates,
         selected: Enum.map(gates, &%{name: &1.name, reason: "matched src/change.txt"}),
         skipped: if(gates == [], do: [%{name: "changed-proof", reason: "no changed files matched src/change.txt"}], else: []),
         changed_files: changed_files,
         metadata: %{provider: id(), selector_mode: "changed_files", changed_files_source: Map.get(selector_metadata, :source)}
       )}
    end

    @impl true
    def select_guides(_opts \\ []), do: {:ok, []}

    @impl true
    def prompt(%Rondo.Linear.Issue{} = issue, _opts \\ []), do: "Changed-file prompt for #{issue.identifier}"

    @impl true
    def model_routing_hints(_opts \\ []), do: %{}

    @impl true
    def proof_requirements(_opts \\ []), do: {:ok, []}

    @impl true
    def evaluate_action_policy(action, classes, opts \\ []) do
      {:ok, %{"decision" => "allow", "action" => action, "classes" => classes, "mode" => Keyword.fetch!(opts, :mode), "provider" => id()}}
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

  defmodule UnsupportedModelSelectionAdapter do
    @behaviour Rondo.Agent.Adapter

    @impl true
    def id, do: "unsupported_model_selection"

    @impl true
    def capabilities, do: FakeAdapter.capabilities()

    @impl true
    def probe(_opts \\ []), do: %{status: :degraded, checks: %{model_selection: :unsupported}}

    @impl true
    def invoke(request), do: FakeAdapter.invoke(request)
  end

  defmodule RaisingProbeAdapter do
    @behaviour Rondo.Agent.Adapter

    @impl true
    def id, do: "raising_probe"

    @impl true
    def capabilities, do: FakeAdapter.capabilities()

    @impl true
    def probe(_opts \\ []), do: raise("probe failed")

    @impl true
    def invoke(request), do: FakeAdapter.invoke(request)
  end

  defmodule ModelHintProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "model_hint_process"

    @impl true
    def capabilities, do: %{gate_selection: :test, prompt: :test, model_routing_hints: :test}

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{available: :ok}}

    @impl true
    def select_gates(_opts \\ []), do: {:ok, Rondo.ProcessProvider.gate_selection_result([])}

    @impl true
    def select_guides(_opts \\ []), do: {:ok, []}

    @impl true
    def prompt(%Rondo.Linear.Issue{} = issue, _opts \\ []), do: "Model hint prompt for #{issue.identifier}"

    @impl true
    def model_routing_hints(_opts \\ []), do: %{"model" => "routed-model"}

    @impl true
    def proof_requirements(_opts \\ []), do: {:ok, []}

    @impl true
    def evaluate_action_policy(_action, _classes, _opts \\ []), do: {:error, :not_used}
  end

  defmodule InitialContextModelHintProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "initial_context_model_hint_process"

    @impl true
    def capabilities, do: %{gate_selection: :test, prompt: :test, model_routing_hints: :test}

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{available: :ok}}

    @impl true
    def select_gates(_opts \\ []), do: {:ok, Rondo.ProcessProvider.gate_selection_result([])}

    @impl true
    def select_guides(_opts \\ []), do: {:ok, []}

    @impl true
    def prompt(%Rondo.Linear.Issue{} = issue, _opts \\ []), do: "Initial context model hint prompt for #{issue.identifier}"

    @impl true
    def model_routing_hints(_opts \\ []) do
      %{
        "tier" => "standard",
        "initial" => %{
          "skill" => "kickoff",
          "phase" => "context_discovery",
          "tier" => "heavy",
          "mode" => "prefer"
        }
      }
    end

    @impl true
    def proof_requirements(_opts \\ []), do: {:ok, []}

    @impl true
    def evaluate_action_policy(_action, _classes, _opts \\ []), do: {:error, :not_used}
  end

  defmodule TurnAwareModelHintProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "turn_aware_model_hint_process"

    @impl true
    def capabilities, do: %{gate_selection: :test, prompt: :test, model_routing_hints: :test}

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{available: :ok}}

    @impl true
    def select_gates(_opts \\ []), do: {:ok, Rondo.ProcessProvider.gate_selection_result([])}

    @impl true
    def select_guides(_opts \\ []), do: {:ok, []}

    @impl true
    def prompt(%Rondo.Linear.Issue{} = issue, _opts \\ []), do: "Turn-aware model hint prompt for #{issue.identifier}"

    @impl true
    def model_routing_hints(_opts \\ []) do
      %{
        "initial" => %{
          "skill" => "kickoff",
          "phase" => "context_discovery",
          "tier" => "standard",
          "mode" => "prefer"
        },
        "steps" => [
          %{
            "stage" => "turn",
            "phase" => "implementation",
            "tier" => "heavy",
            "mode" => "prefer"
          }
        ]
      }
    end

    @impl true
    def proof_requirements(_opts \\ []), do: {:ok, []}

    @impl true
    def evaluate_action_policy(_action, _classes, _opts \\ []), do: {:error, :not_used}
  end

  defmodule InitialStageLessStepModelHintProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "initial_stage_less_step_model_hint_process"

    @impl true
    def capabilities, do: %{gate_selection: :test, prompt: :test, model_routing_hints: :test}

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{available: :ok}}

    @impl true
    def select_gates(_opts \\ []), do: {:ok, Rondo.ProcessProvider.gate_selection_result([])}

    @impl true
    def select_guides(_opts \\ []), do: {:ok, []}

    @impl true
    def prompt(%Rondo.Linear.Issue{} = issue, _opts \\ []), do: "Initial stage-less step model hint prompt for #{issue.identifier}"

    @impl true
    def model_routing_hints(_opts \\ []) do
      %{
        "tier" => "standard",
        "steps" => [
          %{"skill" => "kickoff", "phase" => "context_discovery", "tier" => "heavy", "mode" => "prefer"}
        ]
      }
    end

    @impl true
    def proof_requirements(_opts \\ []), do: {:ok, []}

    @impl true
    def evaluate_action_policy(_action, _classes, _opts \\ []), do: {:error, :not_used}
  end

  defmodule InitialRequiredUnresolvedModelHintProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "initial_required_unresolved_model_hint_process"

    @impl true
    def capabilities, do: %{gate_selection: :test, prompt: :test, model_routing_hints: :test}

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{available: :ok}}

    @impl true
    def select_gates(_opts \\ []), do: {:ok, Rondo.ProcessProvider.gate_selection_result([])}

    @impl true
    def select_guides(_opts \\ []), do: {:ok, []}

    @impl true
    def prompt(%Rondo.Linear.Issue{} = issue, _opts \\ []), do: "Initial unresolved required context prompt for #{issue.identifier}"

    @impl true
    def model_routing_hints(_opts \\ []) do
      %{
        "initial" => %{
          "skill" => "kickoff",
          "phase" => "context_discovery",
          "tier" => "unknown-tier",
          "mode" => "require"
        }
      }
    end

    @impl true
    def proof_requirements(_opts \\ []), do: {:ok, []}

    @impl true
    def evaluate_action_policy(_action, _classes, _opts \\ []), do: {:error, :not_used}
  end

  defmodule InitialRequiredContextModelHintProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "initial_required_context_model_hint_process"

    @impl true
    def capabilities, do: %{gate_selection: :test, prompt: :test, model_routing_hints: :test}

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{available: :ok}}

    @impl true
    def select_gates(_opts \\ []), do: {:ok, Rondo.ProcessProvider.gate_selection_result([])}

    @impl true
    def select_guides(_opts \\ []), do: {:ok, []}

    @impl true
    def prompt(%Rondo.Linear.Issue{} = issue, _opts \\ []), do: "Initial required context prompt for #{issue.identifier}"

    @impl true
    def model_routing_hints(_opts \\ []) do
      %{
        "initial" => %{
          "skill" => "kickoff",
          "phase" => "context_discovery",
          "tier" => "heavy",
          "mode" => "require"
        }
      }
    end

    @impl true
    def proof_requirements(_opts \\ []), do: {:ok, []}

    @impl true
    def evaluate_action_policy(_action, _classes, _opts \\ []), do: {:error, :not_used}
  end

  defmodule RequiredModelHintProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "required_model_hint_process"

    @impl true
    def capabilities, do: %{gate_selection: :test, prompt: :test, model_routing_hints: :test}

    @impl true
    def probe(_opts \\ []), do: %{status: :ok, checks: %{available: :ok}}

    @impl true
    def select_gates(_opts \\ []), do: {:ok, Rondo.ProcessProvider.gate_selection_result([])}

    @impl true
    def select_guides(_opts \\ []), do: {:ok, []}

    @impl true
    def prompt(%Rondo.Linear.Issue{} = issue, _opts \\ []), do: "Required model hint prompt for #{issue.identifier}"

    @impl true
    def model_routing_hints(_opts \\ []), do: %{"model" => "routed-model", "mode" => "require"}

    @impl true
    def proof_requirements(_opts \\ []), do: {:ok, []}

    @impl true
    def evaluate_action_policy(_action, _classes, _opts \\ []), do: {:error, :not_used}
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

  test "config exposes agent.adapter with claude_code default and pi/codex config" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_adapter: nil)
    assert Config.agent_adapter() == "claude_code"
    assert Config.pi_command() == "pi"
    assert Config.codex_command() == "codex"
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), agent_adapter: "fake")

    assert {:error, {:invalid_workflow_config, _, [%{path: "agent.adapter", value: "fake"}]}} =
             Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), agent_adapter: "pi", claude_command: "", pi_command: "pi")
    assert Config.agent_adapter() == "pi"
    assert Config.pi_command() == "pi"
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), agent_adapter: "codex", codex_command: "codex")
    assert Config.agent_adapter() == "codex"
    assert Config.codex_command() == "codex"
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

  test "claude code adapter passes per-run model through to Claude CLI" do
    test_root = Path.join(System.tmp_dir!(), "rondo-claude-code-adapter-model-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "S-MODEL")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-adapter-model.trace")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf 'ARGV:%s\n' "$*" > "#{trace_file}"
      echo '{"type":"system","subtype":"init","session_id":"adapter-model-session"}'
      echo '{"type":"result","session_id":"adapter-model-session","result":"final","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      assert {:ok, _result} =
               ClaudeCodeAdapter.invoke(%{
                 prompt: "do work",
                 workspace: workspace,
                 previous_run_ref: nil,
                 on_event: fn _event -> :ok end,
                 opts: [model: "routed-model"]
               })

      assert File.read!(trace_file) =~ "--model routed-model"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner passes resolved provider model routing into adapter opts" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-model-routing-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-model-routing",
        identifier: "MT-MODEL-ROUTING",
        title: "Model routing",
        description: "Route model",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: ModelHintProcessProvider,
                 run_ledger: ledger,
                 test_pid: parent,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
               )

      assert_receive {:fake_adapter_opts, opts}, 500
      assert Keyword.get(opts, :model) == "routed-model"
      assert %{status: :honored, resolved: %{model: "routed-model"}} = Keyword.fetch!(opts, :model_routing)

      manifest = opts |> Keyword.fetch!(:run_ledger) |> then(&File.read!(&1.manifest_path)) |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "honored"
      assert manifest["agent"]["model_routing"]["resolved"]["model"] == "routed-model"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner passes repo default model routing to pi after delayed help probe" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-pi-model-routing-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-PI-MODEL")
      pi_binary = Path.join(test_root, "fake-pi")
      trace_file = Path.join(test_root, "pi-router.trace")
      File.mkdir_p!(workspace)

      File.write!(pi_binary, """
      #!/bin/sh
      if [ "$1" = "--help" ]; then
        echo '[mcp] noisy startup'
        sleep 1
        echo 'Usage: pi --model <pattern>'
        exit 0
      fi
      printf 'ARGV:%s\n' "$*" >> "#{trace_file}"
      echo '{"type":"session","version":3,"id":"routed-pi-session"}'
      echo '{"type":"agent_end","result":"{\"schema\":\"rondo.final_report/v0\",\"summary\":\"routed pi final\",\"changed_files\":[],\"gates_run\":[],\"failures\":[],\"risks\":[],\"next_state\":\"Done\"}","messages":[]}'
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        agent_adapter: "pi",
        pi_command: pi_binary,
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}]}
        }
      )

      issue = %Issue{
        id: "issue-pi-model-routing",
        identifier: "MT-PI-MODEL",
        title: "Pi model routing",
        description: "Route repo default model",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      issue_state_fetcher = fn [_issue_id] ->
        fetch_count = Process.get(:pi_model_routing_fetch_count, 0) + 1
        Process.put(:pi_model_routing_fetch_count, fetch_count)

        if fetch_count == 1 do
          {:ok, [%{issue | state: "In Progress"}]}
        else
          {:ok, [%{issue | state: "In Progress"}]}
        end
      end

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: PiAdapter,
                 process_provider: FakeProcessProvider,
                 run_ledger: ledger,
                 gates: [],
                 issue_state_fetcher: issue_state_fetcher
               )

      assert File.read!(trace_file) =~ "--model openai-codex/gpt-5.4-mini"

      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "honored"
      assert manifest["agent"]["model_routing"]["resolved"]["model"] == "openai-codex/gpt-5.4-mini"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner uses initial step-aware routing hints at spawn" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-initial-model-routing-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{
            standard: [%{model: "standard-model"}],
            heavy: [%{model: "heavy-model"}]
          }
        }
      )

      issue = %Issue{
        id: "issue-initial-model-routing",
        identifier: "MT-INITIAL-MODEL",
        title: "Initial model routing",
        description: "Route kickoff context discovery to heavy",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: InitialContextModelHintProcessProvider,
                 run_ledger: ledger,
                 test_pid: parent,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
               )

      assert_receive {:fake_adapter_opts, opts}, 500
      assert Keyword.get(opts, :model) == "heavy-model"

      assert %{
               status: :honored,
               requested_tier: "heavy",
               context: %{stage: "initial_spawn", skill: "kickoff", phase: "context_discovery"},
               resolved: %{adapter: nil, model: "heavy-model"}
             } = Keyword.fetch!(opts, :model_routing)

      manifest = opts |> Keyword.fetch!(:run_ledger) |> then(&File.read!(&1.manifest_path)) |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "honored"
      assert manifest["agent"]["model_routing"]["requested_tier"] == "heavy"
      assert manifest["agent"]["model_routing"]["context"]["stage"] == "initial_spawn"
      assert manifest["agent"]["model_routing"]["context"]["skill"] == "kickoff"
      assert manifest["agent"]["model_routing"]["context"]["phase"] == "context_discovery"
      assert manifest["agent"]["model_routing"]["resolved"]["model"] == "heavy-model"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner falls back when prefer model routing targets an adapter without model selection" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-model-routing-fallback-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-model-routing-fallback",
        identifier: "MT-MODEL-FALLBACK",
        title: "Model routing fallback",
        description: "Route model with fallback",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: UnsupportedModelSelectionAdapter,
                 process_provider: ModelHintProcessProvider,
                 run_ledger: ledger,
                 test_pid: parent,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
               )

      assert_receive {:fake_adapter_opts, opts}, 500
      refute Keyword.has_key?(opts, :model)
      assert %{status: :fallback, resolved: nil, reason: reason} = Keyword.fetch!(opts, :model_routing)
      assert reason =~ "does not support per-run model selection"

      manifest = opts |> Keyword.fetch!(:run_ledger) |> then(&File.read!(&1.manifest_path)) |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "fallback"
      assert manifest["agent"]["model_routing"]["resolved"] == nil
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner falls back to next configured model after a Codex usage-limit failure" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-model-routing-codex-fallback-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        gates: nil,
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{
            standard: [
              %{model: "openai-codex/gpt-5.4-mini"},
              %{model: "openrouter/deepseek/deepseek-v4-pro"}
            ]
          }
        }
      )

      issue = %Issue{
        id: "issue-routing-codex-fallback",
        identifier: "MT-ROUTING-CODEX-FALLBACK",
        title: "Routing codex fallback",
        description: "Exercise provider quota fallback",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: RoutingFallbackAdapter,
                 process_provider: FakeProcessProvider,
                 run_ledger: ledger,
                 failure_mode: :codex_quota,
                 test_pid: parent,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
               )

      assert_receive {:routing_fallback_invoked, :codex_quota, 1, "openai-codex/gpt-5.4-mini", _previous_run_ref}, 500
      assert_receive {:routing_fallback_invoked, :codex_quota, 2, "openrouter/deepseek/deepseek-v4-pro", _previous_run_ref}, 500
      refute_received {:routing_fallback_invoked, :codex_quota, 3, _, _}

      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "fallback"
      assert manifest["agent"]["model_routing"]["resolved"]["model"] == "openrouter/deepseek/deepseek-v4-pro"
      assert manifest["agent"]["model_routing"]["fallback"]["failed_candidate"]["model"] == "openai-codex/gpt-5.4-mini"
      assert manifest["agent"]["model_routing"]["fallback"]["next_candidate"]["model"] == "openrouter/deepseek/deepseek-v4-pro"
      assert manifest["agent"]["model_routing"]["fallback"]["failure_class"] == "usage_limit"
      assert manifest["agent"]["model_routing"]["fallback"]["exhausted"] == false
      assert Enum.count(manifest["checkpoints"], &(&1["kind"] == "model_routing_decision")) >= 2
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner falls back to the next configured model after an OpenRouter rate-limit failure" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-model-routing-openrouter-fallback-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        gates: nil,
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{
            standard: [
              %{model: "openrouter/deepseek/deepseek-v4-pro"},
              %{model: "openrouter/moonshotai/kimi-k2.7-code"}
            ]
          }
        }
      )

      issue = %Issue{
        id: "issue-routing-openrouter-fallback",
        identifier: "MT-ROUTING-OPENROUTER-FALLBACK",
        title: "Routing openrouter fallback",
        description: "Exercise OpenRouter quota fallback",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: RoutingFallbackAdapter,
                 process_provider: FakeProcessProvider,
                 run_ledger: ledger,
                 failure_mode: :openrouter_rate_limit,
                 test_pid: parent,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
               )

      assert_receive {:routing_fallback_invoked, :openrouter_rate_limit, 1, "openrouter/deepseek/deepseek-v4-pro", _previous_run_ref}, 500
      assert_receive {:routing_fallback_invoked, :openrouter_rate_limit, 2, "openrouter/moonshotai/kimi-k2.7-code", _previous_run_ref}, 500
      refute_received {:routing_fallback_invoked, :openrouter_rate_limit, 3, _, _}

      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "fallback"
      assert manifest["agent"]["model_routing"]["resolved"]["model"] == "openrouter/moonshotai/kimi-k2.7-code"
      assert manifest["agent"]["model_routing"]["fallback"]["failed_candidate"]["model"] == "openrouter/deepseek/deepseek-v4-pro"
      assert manifest["agent"]["model_routing"]["fallback"]["next_candidate"]["model"] == "openrouter/moonshotai/kimi-k2.7-code"
      assert manifest["agent"]["model_routing"]["fallback"]["failure_class"] == "rate_limit"
      assert manifest["agent"]["model_routing"]["fallback"]["exhausted"] == false
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner does not fall back on ordinary implementation failures" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-model-routing-plain-failure-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        gates: nil,
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{
            standard: [
              %{model: "openai-codex/gpt-5.4-mini"},
              %{model: "openrouter/deepseek/deepseek-v4-pro"}
            ]
          }
        }
      )

      issue = %Issue{
        id: "issue-routing-plain-failure",
        identifier: "MT-ROUTING-PLAIN-FAILURE",
        title: "Routing plain failure",
        description: "Ensure ordinary failures do not fallback",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert_raise RuntimeError, ~r/Agent run failed/, fn ->
        AgentRunner.run(issue, parent,
          agent_adapter: RoutingFallbackAdapter,
          process_provider: FakeProcessProvider,
          run_ledger: ledger,
          failure_mode: :plain_failure,
          test_pid: parent,
          issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
        )
      end

      assert_receive {:routing_fallback_invoked, :plain_failure, 1, "openai-codex/gpt-5.4-mini", _previous_run_ref}, 500
      refute_received {:routing_fallback_invoked, :plain_failure, 2, _, _}

      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "honored"
      assert manifest["agent"]["model_routing"]["resolved"]["model"] == "openai-codex/gpt-5.4-mini"
      refute Map.has_key?(manifest["agent"]["model_routing"], "fallback")
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner uses stage-less initial step routing hints at spawn" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-initial-step-model-routing-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{
            standard: [%{model: "standard-model"}],
            heavy: [%{model: "heavy-model"}]
          }
        }
      )

      issue = %Issue{
        id: "issue-initial-step-model-routing",
        identifier: "MT-INITIAL-STEP-MODEL",
        title: "Initial step model routing",
        description: "Route kickoff context discovery stage-less step to heavy",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: InitialStageLessStepModelHintProcessProvider,
                 run_ledger: ledger,
                 test_pid: parent,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
               )

      assert_receive {:fake_adapter_opts, opts}, 500
      assert Keyword.get(opts, :model) == "heavy-model"

      assert %{
               status: :honored,
               requested_tier: "heavy",
               context: %{skill: "kickoff", phase: "context_discovery"},
               resolved: %{adapter: nil, model: "heavy-model"}
             } = Keyword.fetch!(opts, :model_routing)

      manifest = opts |> Keyword.fetch!(:run_ledger) |> then(&File.read!(&1.manifest_path)) |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "honored"
      assert manifest["agent"]["model_routing"]["context"]["skill"] == "kickoff"
      assert manifest["agent"]["model_routing"]["context"]["phase"] == "context_discovery"
      assert manifest["agent"]["model_routing"]["resolved"]["model"] == "heavy-model"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner re-evaluates model routing on continuation turns" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-turn-routing-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 2,
        gates: nil,
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{
            standard: [%{model: "standard-model"}],
            heavy: [%{model: "heavy-model"}]
          }
        }
      )

      issue = %Issue{
        id: "issue-turn-routing",
        identifier: "MT-TURN-ROUTING",
        title: "Turn routing",
        description: "Exercise runtime turn-aware routing",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      state_fetcher = fn [_issue_id] ->
        fetch_count = Process.get(:turn_model_routing_fetch_count, 0) + 1
        Process.put(:turn_model_routing_fetch_count, fetch_count)

        state = if fetch_count == 1, do: "In Progress", else: "In Progress"
        {:ok, [%{issue | state: state}]}
      end

      planning_report = %{
        "schema" => "rondo.final_report/v0",
        "summary" => "planned continuation routing",
        "changed_files" => [],
        "gates_run" => [],
        "failures" => [],
        "risks" => [],
        "next_state" => "In Progress",
        "implementation_plan" => "Continue to implementation turn."
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: TurnAwareModelHintProcessProvider,
                 run_ledger: ledger,
                 test_pid: parent,
                 fake_final_reports: [Jason.encode!(planning_report), "fake final 2"],
                 issue_state_fetcher: state_fetcher
               )

      assert_receive {:fake_adapter_opts, first_opts}, 500
      assert Keyword.get(first_opts, :model) == "standard-model"
      assert %{status: :honored, context: %{stage: "initial_spawn"}} = Keyword.fetch!(first_opts, :model_routing)

      assert_receive {:fake_adapter_opts, second_opts}, 500
      assert Keyword.get(second_opts, :model) == "heavy-model"
      assert %{status: :honored, context: %{stage: "turn", phase: "implementation"}} = Keyword.fetch!(second_opts, :model_routing)

      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["context"]["stage"] == "turn"
      assert manifest["agent"]["model_routing"]["context"]["phase"] == "implementation"
      assert Enum.count(manifest["checkpoints"], &(&1["kind"] == "model_routing_decision")) >= 2
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner separates default planning and implementation phases with planning tier handoff" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-phase-routing-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 2,
        gates: [],
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{
            standard: [%{model: "standard-model"}],
            heavy: [%{model: "heavy-model"}],
            frontier: [%{model: "frontier-model"}]
          }
        }
      )

      issue = %Issue{
        id: "issue-phase-routing",
        identifier: "MT-PHASE-ROUTING",
        title: "Phase routing",
        description: "Plan with frontier, implement with recommended tier",
        state: "In Progress",
        labels: []
      }

      planning_report = %{
        "schema" => "rondo.final_report/v0",
        "summary" => "planned implementation",
        "changed_files" => [],
        "gates_run" => [],
        "failures" => [],
        "risks" => [],
        "next_state" => "In Progress",
        "implementation_plan" => "Implement the tested phase-aware routing slice.",
        "recommended_implementation_tier" => "heavy"
      }

      implementation_report = %{
        "schema" => "rondo.final_report/v0",
        "summary" => "implemented phase routing",
        "changed_files" => ["lib/rondo/agent_runner.ex"],
        "gates_run" => [],
        "failures" => [],
        "risks" => [],
        "next_state" => "Done"
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: Rondo.ProcessProvider.Native,
                 run_ledger: ledger,
                 test_pid: parent,
                 fake_final_reports: [Jason.encode!(planning_report), Jason.encode!(implementation_report)],
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
               )

      assert_receive {:fake_adapter_invoked, 1, planning_prompt, _workspace, nil}, 500
      assert planning_prompt =~ "Rondo planning phase"
      assert planning_prompt =~ "Do not edit files"

      assert_receive {:fake_adapter_opts, first_opts}, 500
      assert Keyword.get(first_opts, :model) == "frontier-model"
      assert %{requested_tier: "frontier", context: %{stage: "initial_spawn", phase: "planning"}} = Keyword.fetch!(first_opts, :model_routing)

      assert_receive {:fake_adapter_invoked, 2, implementation_prompt, _workspace, previous_run_ref}, 500
      assert previous_run_ref.provider_ref == "fake-run-1"
      assert implementation_prompt =~ "Planning checkpoint to implement from"
      assert implementation_prompt =~ "Implement the tested phase-aware routing slice."

      assert_receive {:fake_adapter_opts, second_opts}, 500
      assert Keyword.get(second_opts, :model) == "heavy-model"
      assert %{requested_tier: "heavy", context: %{stage: "turn", phase: "implementation"}} = Keyword.fetch!(second_opts, :model_routing)

      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "planning_completed"))
      assert Enum.count(manifest["checkpoints"], &(&1["kind"] == "model_routing_decision")) >= 2
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner does not implement from unsafe planning reports" do
    scenarios = [
      {:missing_plan,
       %{
         "schema" => "rondo.final_report/v0",
         "summary" => "planned without handoff",
         "changed_files" => [],
         "gates_run" => [],
         "failures" => [],
         "risks" => [],
         "next_state" => "In Progress"
       }, "planning_handoff_missing"},
      {:terminal,
       %{
         "schema" => "rondo.final_report/v0",
         "summary" => "incorrectly terminal",
         "changed_files" => [],
         "gates_run" => [],
         "failures" => [],
         "risks" => [],
         "next_state" => "Done",
         "implementation_plan" => "Implement later."
       }, "planning_final_report_terminal"},
      {:declared_changes,
       %{
         "schema" => "rondo.final_report/v0",
         "summary" => "planned with changes",
         "changed_files" => ["lib/rondo/agent_runner.ex"],
         "gates_run" => [],
         "failures" => [],
         "risks" => [],
         "next_state" => "In Progress",
         "implementation_plan" => "Implement later."
       }, "planning_report_declared_changes"},
      {:invalid, "not json", "planning_final_report_invalid"}
    ]

    Enum.each(scenarios, fn {name, planning_report, reason_code} ->
      Process.delete(:fake_adapter_invocation)
      test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-unsafe-planning-#{name}-#{System.unique_integer([:positive])}")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          max_turns: 2,
          gates: [],
          model_routing: %{
            defaults: %{tier: "standard", mode: "prefer"},
            tiers: %{
              standard: [%{model: "standard-model"}],
              frontier: [%{model: "frontier-model"}]
            }
          }
        )

        issue = %Issue{
          id: "issue-unsafe-planning-#{name}",
          identifier: "MT-UNSAFE-PLANNING-#{name}",
          title: "Unsafe planning #{name}",
          description: "Unsafe planning should not implement",
          state: "In Progress",
          labels: []
        }

        parent = start_update_recorder(self())
        assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
        send(parent, {:set_ledger, ledger})

        report = if is_map(planning_report), do: Jason.encode!(planning_report), else: planning_report

        assert :ok =
                 AgentRunner.run(issue, parent,
                   agent_adapter: FakeAdapter,
                   process_provider: Rondo.ProcessProvider.Native,
                   run_ledger: ledger,
                   test_pid: parent,
                   fake_final_reports: [report],
                   issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
                 )

        assert_receive {:fake_adapter_invoked, 1, _planning_prompt, _workspace, nil}, 500
        assert_receive {:claude_worker_update, _, %{event: :run_decision, reason_code: ^reason_code}}, 500
        refute_receive {:fake_adapter_invoked, 2, _implementation_prompt, _workspace, _previous_run_ref}, 100

        manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
        refute Enum.any?(manifest["checkpoints"], &(&1["kind"] == "planning_completed"))
      after
        File.rm_rf(test_root)
      end
    end)
  end

  test "agent runner stops before first adapter invocation when tracker state turns terminal" do
    workspace_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-terminal-pre-turn-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 2,
        gates: [],
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{
            standard: [%{model: "standard-model"}],
            frontier: [%{model: "frontier-model"}]
          }
        }
      )

      issue = %Issue{
        id: "issue-terminal-pre-turn",
        identifier: "MT-TERMINAL-PRE-TURN",
        title: "Terminal pre-turn",
        description: "Terminal state should stop before the first adapter invocation",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      exit_reason =
        catch_exit(
          AgentRunner.run(issue, parent,
            agent_adapter: FakeAdapter,
            process_provider: Rondo.ProcessProvider.Native,
            run_ledger: ledger,
            test_pid: parent,
            issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
          )
        )

      assert {:tracker_state_stop,
              %{
                classification: :terminal,
                stage: :pre_turn,
                state: "Done",
                issue_id: "issue-terminal-pre-turn"
              }} = exit_reason

      refute_received {:fake_adapter_invoked, _, _, _, _}
      assert_receive {:claude_worker_update, _, %{event: :run_decision, reason_code: "tracker_state_terminal"}}, 500
    after
      File.rm_rf(workspace_root)
    end
  end

  test "agent runner stops before planning checkpoint when tracker becomes terminal between turns" do
    workspace_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-terminal-planning-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 2,
        gates: [],
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{
            standard: [%{model: "standard-model"}],
            frontier: [%{model: "frontier-model"}]
          }
        }
      )

      issue = %Issue{
        id: "issue-terminal-planning",
        identifier: "MT-TERMINAL-PLANNING",
        title: "Terminal planning",
        description: "Terminal state should stop before planning checkpoint write",
        state: "In Progress",
        labels: []
      }

      planning_report = %{
        "schema" => "rondo.final_report/v0",
        "summary" => "planned continuation",
        "changed_files" => [],
        "gates_run" => [],
        "failures" => [],
        "risks" => [],
        "next_state" => "In Progress",
        "implementation_plan" => "Continue with the next phase.",
        "recommended_implementation_tier" => "heavy"
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      issue_state_fetcher = fn [_issue_id] ->
        fetch_count = Process.get(:terminal_planning_fetch_count, 0) + 1
        Process.put(:terminal_planning_fetch_count, fetch_count)

        state = if fetch_count == 1, do: "In Progress", else: "Done"
        {:ok, [%{issue | state: state}]}
      end

      exit_reason =
        catch_exit(
          AgentRunner.run(issue, parent,
            agent_adapter: FakeAdapter,
            process_provider: Rondo.ProcessProvider.Native,
            run_ledger: ledger,
            test_pid: parent,
            fake_final_reports: [Jason.encode!(planning_report)],
            issue_state_fetcher: issue_state_fetcher
          )
        )

      assert {:tracker_state_stop,
              %{
                classification: :terminal,
                stage: :planning_complete,
                state: "Done",
                issue_id: "issue-terminal-planning"
              }} = exit_reason

      assert_receive {:fake_adapter_invoked, 1, planning_prompt, _workspace, nil}, 500
      assert planning_prompt =~ "Rondo planning phase"
      refute_received {:fake_adapter_invoked, 2, _implementation_prompt, _workspace, _previous_run_ref}
      assert_receive {:claude_worker_update, _, %{event: :run_decision, reason_code: "tracker_state_terminal"}}, 500

      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      refute Enum.any?(manifest["checkpoints"], &(&1["kind"] == "planning_completed"))
    after
      Process.delete(:terminal_planning_fetch_count)
      File.rm_rf(workspace_root)
    end
  end

  test "agent runner stops before first adapter invocation when tracker issue is missing" do
    workspace_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-missing-pre-turn-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 2,
        gates: [],
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{
            standard: [%{model: "standard-model"}],
            frontier: [%{model: "frontier-model"}]
          }
        }
      )

      issue = %Issue{
        id: "issue-missing-pre-turn",
        identifier: "MT-MISSING-PRE-TURN",
        title: "Missing pre-turn",
        description: "Missing tracker state should stop before the first adapter invocation",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      exit_reason =
        catch_exit(
          AgentRunner.run(issue, parent,
            agent_adapter: FakeAdapter,
            process_provider: Rondo.ProcessProvider.Native,
            run_ledger: ledger,
            test_pid: parent,
            issue_state_fetcher: fn [_issue_id] -> {:ok, []} end
          )
        )

      assert {:tracker_state_stop,
              %{
                classification: :missing,
                stage: :pre_turn,
                state: "In Progress",
                issue_id: "issue-missing-pre-turn"
              }} = exit_reason

      refute_received {:fake_adapter_invoked, _, _, _, _}
      assert_receive {:claude_worker_update, _, %{event: :run_decision, reason_code: "tracker_state_missing"}}, 500
    after
      File.rm_rf(workspace_root)
    end
  end

  test "agent runner records unresolved required initial routing before blocking" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-initial-routing-unresolved-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        model_routing: %{
          defaults: %{tier: "standard", mode: "prefer"},
          tiers: %{standard: [%{model: "standard-model"}]}
        }
      )

      issue = %Issue{
        id: "issue-initial-routing-unresolved",
        identifier: "MT-INITIAL-ROUTING-UNRESOLVED",
        title: "Initial routing unresolved",
        description: "Required contextual route cannot resolve a model",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert_raise RuntimeError, ~r/model_routing_blocked/, fn ->
        AgentRunner.run(issue, parent,
          agent_adapter: FakeAdapter,
          process_provider: InitialRequiredUnresolvedModelHintProcessProvider,
          run_ledger: ledger,
          test_pid: parent,
          issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
        )
      end

      assert_receive {:claude_worker_update, _, %{event: :model_routing_decision}}, 500

      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "blocked"
      assert manifest["agent"]["model_routing"]["resolved"] == nil
      assert manifest["agent"]["model_routing"]["context"]["stage"] == "initial_spawn"
      assert manifest["agent"]["model_routing"]["context"]["skill"] == "kickoff"
      assert manifest["agent"]["model_routing"]["context"]["phase"] == "context_discovery"
      refute_receive {:fake_adapter_opts, _opts}, 100
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner blocks required initial step-aware routing when adapter lacks model selection" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-initial-model-routing-blocked-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        model_routing: %{
          tiers: %{heavy: [%{model: "heavy-model"}]}
        }
      )

      issue = %Issue{
        id: "issue-initial-model-routing-blocked",
        identifier: "MT-INITIAL-MODEL-BLOCKED",
        title: "Initial model routing blocked",
        description: "Route required kickoff context discovery model",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert_raise RuntimeError, ~r/model_routing_blocked/, fn ->
        AgentRunner.run(issue, parent,
          agent_adapter: UnsupportedModelSelectionAdapter,
          process_provider: InitialRequiredContextModelHintProcessProvider,
          run_ledger: ledger,
          test_pid: parent,
          issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
        )
      end

      assert_receive {:claude_worker_update, _, %{event: :model_routing_decision}}, 500

      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "blocked"
      assert manifest["agent"]["model_routing"]["resolved"] == nil
      assert manifest["agent"]["model_routing"]["context"]["stage"] == "initial_spawn"
      assert manifest["agent"]["model_routing"]["context"]["skill"] == "kickoff"
      assert manifest["agent"]["model_routing"]["context"]["phase"] == "context_discovery"
      refute_receive {:fake_adapter_opts, _opts}, 100
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner blocks required model routing when adapter lacks model selection" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-model-routing-blocked-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-model-routing-blocked",
        identifier: "MT-MODEL-BLOCKED",
        title: "Model routing blocked",
        description: "Route required model",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert_raise RuntimeError, ~r/model_routing_blocked/, fn ->
        AgentRunner.run(issue, parent,
          agent_adapter: UnsupportedModelSelectionAdapter,
          process_provider: RequiredModelHintProcessProvider,
          run_ledger: ledger,
          test_pid: parent,
          issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
        )
      end

      assert_receive {:claude_worker_update, _, %{event: :model_routing_decision}}, 500

      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "blocked"
      assert manifest["agent"]["model_routing"]["resolved"] == nil
      refute_receive {:fake_adapter_opts, _opts}, 100
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner treats adapter model-selection probe errors as unsupported for required routes" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-model-routing-probe-error-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-model-routing-probe-error",
        identifier: "MT-MODEL-PROBE-ERROR",
        title: "Model routing probe error",
        description: "Route required model",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())
      assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      send(parent, {:set_ledger, ledger})

      assert_raise RuntimeError, ~r/model_routing_blocked/, fn ->
        AgentRunner.run(issue, parent,
          agent_adapter: RaisingProbeAdapter,
          process_provider: RequiredModelHintProcessProvider,
          run_ledger: ledger,
          test_pid: parent,
          issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
        )
      end

      assert_receive {:claude_worker_update, _, %{event: :model_routing_decision}}, 500

      manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
      assert manifest["agent"]["model_routing"]["status"] == "blocked"
      assert manifest["agent"]["model_routing"]["resolved"] == nil
      refute_receive {:fake_adapter_opts, _opts}, 100
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
      echo '{"type":"result","session_id":"session-compat","result":"{\"schema\":\"rondo.final_report/v0\",\"summary\":\"compat final\",\"changed_files\":[],\"gates_run\":[],\"failures\":[],\"risks\":[],\"next_state\":\"Done\"}","usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
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

      parent = start_update_recorder(self())

      issue_state_fetcher = fn [_issue_id] ->
        fetch_count = Process.get(:claude_compat_fetch_count, 0) + 1
        Process.put(:claude_compat_fetch_count, fetch_count)

        if fetch_count == 1 do
          {:ok, [%{issue | state: "In Progress"}]}
        else
          {:ok, [%{issue | state: "In Progress"}]}
        end
      end

      assert :ok =
               AgentRunner.run(issue, parent, issue_state_fetcher: issue_state_fetcher)

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
                        event: :invocation_completed,
                        final_report: "Working",
                        raw: %{exit_code: 0, session_id: "session-compat"}
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

      parent = start_update_recorder(self())

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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

      parent = start_update_recorder(self())

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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

  test "agent runner resumes a paused run with operator guidance and initial run ref" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-operator-guidance-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1
      )

      parent = start_update_recorder(self())
      previous_run_ref = Adapter.run_ref("fake", "paused-run-1", "fake_run_id", true)

      issue = %Issue{
        id: "issue-guidance",
        identifier: "MT-GUIDANCE",
        title: "Operator guidance proof",
        description: "Exercise paused run resume",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 initial_run_ref: previous_run_ref,
                 operator_guidance: "Use the existing patch and add the missing test.",
                 issue_state_fetcher: &AgentRunner.no_tracker_issue_state_fetcher/1,
                 test_pid: parent
               )

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-GUIDANCE"))
      assert_receive {:fake_adapter_invoked, 1, prompt, ^workspace, ^previous_run_ref}, 500
      assert prompt =~ "Operator guidance"
      assert prompt =~ "Use the existing patch and add the missing test."
      refute prompt =~ "You are an agent for this repository."
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

      parent = start_update_recorder(self())

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:fake_adapter_fetch_count, 0) + 1
        Process.put(:fake_adapter_fetch_count, attempt)

        state = if attempt == 1, do: "In Progress", else: "In Progress"

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

      parent = start_update_recorder(self())

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
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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

  test "agent runner passes collected changed files into provider gate selection and ledger results" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-changed-files-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-CHANGED/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        hook_before_run:
          "git init && git config user.email rondo@example.test && git config user.name 'Rondo Test' && mkdir -p src && printf base > README.md && git add README.md && git commit -m base"
      )

      parent = start_update_recorder(self())

      issue = %Issue{
        id: "issue-changed-files",
        identifier: "MT-CHANGED",
        title: "Changed-file provider proof",
        description: "Provider should receive changed paths",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 process_provider: ChangedFileProcessProvider,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
                 run_dir: run_dir,
                 test_pid: parent,
                 touch_workspace_on_invocation: 1,
                 touch_workspace_path: "src/change.txt"
               )

      {:ok, workspace} = Rondo.PathSafety.canonicalize(Path.join(workspace_root, "MT-CHANGED"))
      assert File.read!(Path.join(workspace, "changed-gate.txt")) == "changed\n"

      assert_receive {
                       :claude_worker_update,
                       "issue-changed-files",
                       %{event: :gates_completed, raw: %{status: :pass, gate_selection: gate_selection}}
                     },
                     500

      assert gate_selection.changed_files == ["src/change.txt"]
      assert gate_selection.metadata.selector_mode == "changed_files"

      results_json = run_dir |> Path.join("artifacts/gates/turn-0001/results.json") |> File.read!() |> Jason.decode!()
      assert results_json["gate_selection"]["changed_files"] == ["src/change.txt"]
      assert results_json["gate_selection"]["metadata"]["selector_mode"] == "changed_files"
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

      parent = start_update_recorder(self())

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
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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
          issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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

      parent = start_update_recorder(self())

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
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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
          issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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

      parent = start_update_recorder(self())

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
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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

      parent = start_update_recorder(self())

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
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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

      parent = start_update_recorder(self())

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
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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

      parent = start_update_recorder(self())

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
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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
          issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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

      parent = start_update_recorder(self())

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
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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

      parent = start_update_recorder(self())

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
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
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
        gate_reuse_enabled: false,
        gates: [%{name: "proof", command: "echo gate", timeout_ms: 1_000}]
      )

      parent = start_update_recorder(self())

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

        state = if fetch_count == 1, do: "In Progress", else: "In Progress"
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

  test "agent runner reuses gates on an unchanged no-op continuation turn" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-gate-reuse-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "gate.trace")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-GATE-REUSE/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 2,
        gate_reuse_enabled: true,
        hook_after_create:
          "git init -b main && git config user.email test@example.org && git config user.name Rondo Test && printf 'base\n' > README.md && git add README.md && git commit -m initial --quiet",
        gates: [%{name: "proof", command: "printf 'gate\\n' >> #{inspect(trace_file)}", timeout_ms: 1_000}]
      )

      parent = start_update_recorder(self())

      issue = %Issue{
        id: "issue-gate-reuse",
        identifier: "MT-GATE-REUSE",
        title: "Gate reuse proof",
        description: "Exercise unchanged-worktree gate reuse after a no-op continuation",
        state: "In Progress",
        labels: []
      }

      # The fake adapter never emits a valid final report, so the second turn
      # continues via tracker state alone (our no-op continuation path).
      fetcher = fn [_issue_id] ->
        fetch_count = Process.get(:gate_reuse_fetch_count, 0) + 1
        Process.put(:gate_reuse_fetch_count, fetch_count)

        state = if fetch_count == 1, do: "In Progress", else: "In Progress"
        {:ok, [%{issue | state: state}]}
      end

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 issue_state_fetcher: fetcher,
                 run_dir: run_dir,
                 test_pid: parent
               )

      completed_results_path = "artifacts/gates/turn-0001/results.json"
      reused_results_path = "artifacts/gates/turn-0002/results.json"

      assert_receive {:fake_adapter_invoked, 1, _, _, nil}, 500

      assert_receive {:claude_worker_update, "issue-gate-reuse", %{event: :gates_completed, raw: raw_completed}},
                     500

      assert raw_completed.status == :pass
      assert raw_completed.results_path == completed_results_path

      assert_receive {:fake_adapter_invoked, 2, _, _, _}, 500

      assert_receive {:claude_worker_update, "issue-gate-reuse", %{event: :gates_reused, raw: raw_reused}},
                     500

      assert raw_reused.status == :reused
      assert raw_reused.results_path == reused_results_path

      assert File.read!(trace_file) == "gate
"
      assert String.contains?(File.read!(Path.join(run_dir, "artifacts/gates/state.json")), ~s("status":"reused"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner reruns gates when the continuation changes the worktree" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-gate-rerun-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "gate.trace")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-GATE-RERUN/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 2,
        gate_reuse_enabled: true,
        hook_after_create:
          "git init -b main && git config user.email test@example.org && git config user.name Rondo Test && printf 'base\n' > README.md && git add README.md && git commit -m initial --quiet",
        gates: [%{name: "proof", command: "printf 'gate\\n' >> #{inspect(trace_file)}", timeout_ms: 1_000}]
      )

      parent = start_update_recorder(self())

      issue = %Issue{
        id: "issue-gate-rerun",
        identifier: "MT-GATE-RERUN",
        title: "Gate rerun proof",
        description: "Exercise changed-worktree gate rerun",
        state: "In Progress",
        labels: []
      }

      fetcher = fn [_issue_id] ->
        fetch_count = Process.get(:gate_rerun_fetch_count, 0) + 1
        Process.put(:gate_rerun_fetch_count, fetch_count)

        state = if fetch_count == 1, do: "In Progress", else: "In Progress"
        {:ok, [%{issue | state: state}]}
      end

      assert :ok =
               AgentRunner.run(issue, parent,
                 agent_adapter: FakeAdapter,
                 issue_state_fetcher: fetcher,
                 run_dir: run_dir,
                 test_pid: parent,
                 touch_workspace_on_invocation: 2,
                 touch_workspace_path: "changed.txt",
                 touch_workspace_contents: "changed
"
               )

      completed_results_path = "artifacts/gates/turn-0001/results.json"
      rerun_results_path = "artifacts/gates/turn-0002/results.json"

      assert_receive {:fake_adapter_invoked, 1, _, _, nil}, 500

      assert_receive {:claude_worker_update, "issue-gate-rerun", %{event: :gates_completed, raw: raw_completed}},
                     500

      assert raw_completed.status == :pass
      assert raw_completed.results_path == completed_results_path

      assert_receive {:fake_adapter_invoked, 2, _, _, _}, 500

      assert_receive {:claude_worker_update, "issue-gate-rerun", %{event: :gates_completed, raw: raw_rerun}},
                     500

      assert raw_rerun.status == :pass
      assert raw_rerun.results_path == rerun_results_path

      assert File.read!(trace_file) == "gate
gate
"
      assert String.contains?(File.read!(Path.join(run_dir, "artifacts/gates/state.json")), ~s("status":"pass"))
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

      parent = start_update_recorder(self())

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
          issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
          run_dir: run_dir,
          test_pid: parent
        )
      end

      assert_receive {:claude_worker_update, "issue-gate-fail", %{event: :gates_completed, raw: %{status: :fail}}}, 500
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner pauses when a configured gate asks for guidance" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-gate-ask-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-GATE-ASK/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        action_policy_command: fake_gate_action_policy("ask"),
        gates: [%{name: "read proof", command: "touch should-not-run", timeout_ms: 1_000}]
      )

      parent = start_update_recorder(self())

      issue = %Issue{
        id: "issue-gate-ask",
        identifier: "MT-GATE-ASK",
        title: "Gate ask proof",
        description: "Exercise gate guidance",
        state: "In Progress",
        labels: []
      }

      assert {:action_policy_guidance_required, interrupt} =
               catch_exit(
                 AgentRunner.run(issue, parent,
                   agent_adapter: FakeAdapter,
                   issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
                   run_dir: run_dir,
                   test_pid: parent
                 )
               )

      assert interrupt["reason"] == "action_policy_guidance_required"
      assert interrupt["blocked_side_effect"]["action"] == "file.read"
      assert interrupt["blocked_side_effect"]["command"] == "touch should-not-run"
      assert interrupt["policy"]["decision"] == "ask"
      assert Enum.any?(interrupt["suggested_responses"], &(&1["id"] == "approve_once"))

      assert_receive {:claude_worker_update, "issue-gate-ask", %{event: :gates_completed, raw: raw}}, 500
      assert raw.status == :policy_blocked
      assert [%{status: :policy_blocked, policy_decision: %{"decision" => "ask", "side_effect_status" => "blocked"}}] = raw.results
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops with explicit policy-denied classification when a configured gate is denied" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-gate-deny-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      run_dir = Path.join(workspace_root, ".rondo_runs/MT-GATE-DENY/run-1")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        action_policy_command: fake_gate_action_policy("deny"),
        gates: [%{name: "read proof", command: "touch should-not-run", timeout_ms: 1_000}]
      )

      parent = start_update_recorder(self())

      issue = %Issue{
        id: "issue-gate-deny",
        identifier: "MT-GATE-DENY",
        title: "Gate deny proof",
        description: "Exercise policy denial",
        state: "In Progress",
        labels: []
      }

      assert {:action_policy_denied, envelope} =
               catch_exit(
                 AgentRunner.run(issue, parent,
                   agent_adapter: FakeAdapter,
                   issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
                   run_dir: run_dir,
                   test_pid: parent
                 )
               )

      assert envelope["decision"] == "deny"
      assert envelope["action"] == "file.read"
      assert envelope["classes"] == ["read"]

      assert_receive {:claude_worker_update, "issue-gate-deny", %{event: :gates_completed, raw: raw}}, 500
      assert raw.status == :policy_denied
      assert [%{status: :policy_denied, policy_decision: %{"decision" => "deny", "side_effect_status" => "blocked"}}] = raw.results
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

  defp fake_gate_action_policy(decision) do
    path = Path.join(System.tmp_dir!(), "rondo-agent-adapter-gate-policy-#{System.unique_integer([:positive])}")
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
    if [ "$action" = "file.read" ]; then
      final_decision="#{decision}"
    else
      final_decision="allow"
    fi
    printf '{"decision":"%s","action":"%s","mode":"%s","classes":["read"]}' "$final_decision" "$action" "$mode"
    """)

    File.chmod!(path, 0o755)
    path
  end

  test "pi adapter probe reports model selection when pi help exposes --model" do
    test_root = Path.join(System.tmp_dir!(), "rondo-pi-adapter-model-probe-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      pi_binary = Path.join(test_root, "fake-pi")
      File.mkdir_p!(workspace_root)

      File.write!(pi_binary, """
      #!/bin/sh
      if [ "$1" = "--help" ]; then
        echo 'Usage: pi --model <pattern>'
        exit 0
      fi
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "pi",
        pi_command: pi_binary
      )

      assert %{checks: %{model_selection: :ok}} = PiAdapter.probe([])
    after
      File.rm_rf(test_root)
    end
  end

  test "pi adapter probe accepts delayed noisy help output before timeout" do
    test_root = Path.join(System.tmp_dir!(), "rondo-pi-adapter-model-probe-slow-help-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      pi_binary = Path.join(test_root, "fake-pi")
      File.mkdir_p!(workspace_root)

      File.write!(pi_binary, """
      #!/bin/sh
      if [ "$1" = "--help" ]; then
        echo '[mcp] initializing noisy helper'
        sleep 3
        echo 'Usage: pi --model <pattern>'
        exit 0
      fi
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "pi",
        pi_command: pi_binary
      )

      assert %{checks: %{model_selection: :ok}} = PiAdapter.probe(help_probe_timeout_ms: 5_000)
    after
      File.rm_rf(test_root)
    end
  end

  test "pi adapter probe terminates help subprocess tree after early model detection" do
    test_root = Path.join(System.tmp_dir!(), "rondo-pi-adapter-model-probe-cleanup-#{System.unique_integer([:positive])}")
    child_pid_file = Path.join(test_root, "help-child.pid")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      pi_binary = Path.join(test_root, "fake-pi")
      File.mkdir_p!(workspace_root)

      File.write!(pi_binary, """
      #!/bin/sh
      if [ "$1" = "--help" ]; then
        sleep 30 &
        child=$!
        echo "$child" > "#{child_pid_file}"
        echo 'Usage: pi --model <pattern>'
        wait "$child"
        exit 0
      fi
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "pi",
        pi_command: pi_binary
      )

      assert %{checks: %{model_selection: :ok}} = PiAdapter.probe(help_probe_timeout_ms: 5_000)

      child_pid = child_pid_file |> File.read!() |> String.trim()
      assert_process_exits(child_pid)
    after
      if File.exists?(child_pid_file) do
        child_pid_file |> File.read!() |> String.trim() |> terminate_test_pid()
      end

      File.rm_rf(test_root)
    end
  end

  test "pi adapter probe treats hung model help as unsupported" do
    test_root = Path.join(System.tmp_dir!(), "rondo-pi-adapter-model-probe-timeout-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      pi_binary = Path.join(test_root, "fake-pi")
      File.mkdir_p!(workspace_root)

      File.write!(pi_binary, """
      #!/bin/sh
      if [ "$1" = "--help" ]; then
        sleep 5
        exit 0
      fi
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_adapter: "pi",
        pi_command: pi_binary
      )

      assert %{checks: %{model_selection: :unsupported}} = PiAdapter.probe(help_probe_timeout_ms: 50)
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

      parent = start_update_recorder(self())

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
      echo '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"{\"schema\":\"rondo.final_report/v0\",\"summary\":\"runner final\",\"changed_files\":[],\"gates_run\":[],\"failures\":[],\"risks\":[],\"next_state\":\"Done\"}"}]}]}'
      exit 0
      """)

      File.chmod!(pi_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
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

      parent = start_update_recorder(self())

      issue_state_fetcher = fn [_issue_id] ->
        fetch_count = Process.get(:pi_adapter_compat_fetch_count, 0) + 1
        Process.put(:pi_adapter_compat_fetch_count, fetch_count)

        if fetch_count == 1 do
          {:ok, [%{issue | state: "In Progress"}]}
        else
          {:ok, [%{issue | state: "In Progress"}]}
        end
      end

      assert :ok =
               AgentRunner.run(issue, parent, issue_state_fetcher: issue_state_fetcher)

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
                        final_report: "Working",
                        raw: %{adapter: "pi"}
                      }},
                     500
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner can resolve codex adapter from config and preserve compatibility envelope" do
    test_root = Path.join(System.tmp_dir!(), "rondo-agent-runner-codex-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      echo '{"type":"thread.started","thread_id":"runner-codex-thread"}'
      echo '{"type":"item.completed","thread_id":"runner-codex-thread","item":{"id":"msg-1","type":"agent_message","text":"{\"schema\":\"rondo.final_report/v0\",\"summary\":\"Working from codex\",\"changed_files\":[],\"gates_run\":[],\"failures\":[],\"risks\":[],\"next_state\":\"Done\"}"}}'
      echo '{"type":"turn.completed","thread_id":"runner-codex-thread","usage":{"input_tokens":2,"cached_input_tokens":1,"output_tokens":3,"reasoning_output_tokens":4}}'
      exit 0
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        max_turns: 1,
        agent_adapter: "codex",
        codex_command: codex_binary
      )

      issue = %Issue{
        id: "issue-codex",
        identifier: "MT-CODEX",
        title: "Codex adapter",
        description: "Run through codex",
        state: "In Progress",
        labels: []
      }

      parent = start_update_recorder(self())

      issue_state_fetcher = fn [_issue_id] ->
        fetch_count = Process.get(:codex_adapter_compat_fetch_count, 0) + 1
        Process.put(:codex_adapter_compat_fetch_count, fetch_count)

        if fetch_count == 1 do
          {:ok, [%{issue | state: "In Progress"}]}
        else
          {:ok, [%{issue | state: "In Progress"}]}
        end
      end

      assert :ok =
               AgentRunner.run(issue, parent, issue_state_fetcher: issue_state_fetcher)

      assert_receive {:claude_worker_update, "issue-codex",
                      %{
                        event: :session_started,
                        adapter: "codex",
                        run_ref: %{provider_ref: "runner-codex-thread", provider_ref_kind: "thread_id"},
                        session_id: "runner-codex-thread"
                      }},
                     500

      assert_receive {:claude_worker_update, "issue-codex",
                      %{
                        event: :invocation_completed,
                        adapter: "codex",
                        final_report: nil,
                        usage: %{total_tokens: 10}
                      }},
                     500
    after
      File.rm_rf(test_root)
    end
  end

  defp fixture_path(filename) do
    Path.expand(Path.join([__DIR__, "..", "fixtures", "beislid_process_provider", filename]))
  end

  defp assert_process_exits(pid, attempts \\ 20)

  defp assert_process_exits(pid, attempts) when attempts > 0 do
    if process_alive?(pid) do
      Process.sleep(50)
      assert_process_exits(pid, attempts - 1)
    else
      :ok
    end
  end

  defp assert_process_exits(pid, 0), do: refute(process_alive?(pid))

  defp process_alive?(pid) when is_binary(pid) and pid != "" do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      _result -> false
    end
  rescue
    _error -> false
  end

  defp process_alive?(_pid), do: false

  defp terminate_test_pid(pid) when is_binary(pid) and pid != "" do
    System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp terminate_test_pid(_pid), do: :ok

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
