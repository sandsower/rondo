defmodule Rondo.ProcessProviderTest do
  use Rondo.TestSupport

  alias Rondo.ProcessProvider
  alias Rondo.ProcessProvider.Beislid
  alias Rondo.ProcessProvider.Failure
  alias Rondo.ProcessProvider.Native

  defmodule ErrorProvider do
    def select_gates(_opts), do: {:error, :provider_unavailable}
  end

  defmodule LegacyListProvider do
    def select_gates(_opts) do
      {:ok, [%{name: "legacy", command: "mix test", timeout_ms: 1_000, action_classes: ["read"]}]}
    end
  end

  defmodule NoIdProvider do
  end

  test "native provider exposes current workflow gates and unsupported rich features" do
    write_workflow_file!(Workflow.workflow_file_path(),
      gates: [%{name: "unit", command: "mix test", timeout_ms: 120_000}],
      clean_eval_gates: [%{name: "clean-eval", command: "mix test --list", timeout_ms: 30_000}],
      claude_model: "claude-test",
      claude_allowed_tools: ["Read", "Bash"]
    )

    assert Native.id() == "native"
    assert Native.capabilities().gate_selection == "native_flat_gates"
    assert Native.capabilities().guide_selection == "unsupported"

    assert {:ok,
            %{
              gates: [%{name: "unit", command: "mix test", timeout_ms: 120_000, action_classes: ["read"]}],
              selected: [%{name: "unit", reason: reason}],
              skipped: [],
              warnings: []
            }} = Native.select_gates()

    assert reason =~ "WORKFLOW.md"

    assert {:ok,
            %{
              gates: [%{name: "clean-eval", command: "mix test --list", timeout_ms: 30_000, action_classes: ["read"]}],
              selected: [%{name: "clean-eval", reason: pre_pr_reason}],
              metadata: %{stage: "pre_pr"}
            }} = Native.select_gates(stage: "pre_pr")

    assert pre_pr_reason =~ "pre-PR"

    assert {:ok, []} = Native.select_guides()
    assert {:ok, []} = Native.proof_requirements()

    assert Native.model_routing_hints() == %{
             agent_adapter: "claude_code",
             claude_allowed_tools: ["Read", "Bash"],
             claude_model: "claude-test"
           }
  end

  test "native provider renders the existing workflow prompt" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}: {{ issue.title }}")

    issue = %Issue{id: "1", identifier: "RON-1", title: "Add seam", state: "Todo"}

    assert Native.prompt(issue) == "Ticket RON-1: Add seam"
    assert ProcessProvider.prompt(Native, issue) == "Ticket RON-1: Add seam"
  end

  test "native provider reports degraded probe metadata when action policy command is unavailable" do
    write_workflow_file!(Workflow.workflow_file_path(), action_policy_command: "rondo-missing-beislid")

    assert %{status: :degraded, checks: %{action_policy: :missing, guide_selection: :unsupported}} = Native.probe()
  end

  test "native provider evaluates action policy through configured evaluator" do
    write_workflow_file!(Workflow.workflow_file_path(), action_policy_command: fake_evaluator("allow"))

    assert {:ok, %{"decision" => "allow", "action" => "file.read"}} = Native.evaluate_action_policy("file.read", ["read"])
  end

  test "provider facade resolves native, beislid, and custom providers" do
    write_workflow_file!(Workflow.workflow_file_path(), process_provider_kind: "native")

    assert ProcessProvider.provider_module() == Native
    assert ProcessProvider.provider_module(:native) == Native
    assert ProcessProvider.provider_module("native") == Native
    assert ProcessProvider.provider_module("beislid") == Beislid
    assert ProcessProvider.provider_module(:beislid) == Beislid
    assert ProcessProvider.provider_module(__MODULE__) == __MODULE__
  end

  test "beislid provider loads approved artifact and exposes gate selection metadata" do
    artifact_path = fixture_path("approved.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: artifact_path
    )

    assert Beislid.id() == "beislid"
    assert Beislid.capabilities().gate_selection == "fixture"

    assert %{status: :ok, checks: %{artifact: :ok, guide_selection: :deferred, proof_requirements: :ok}} =
             Beislid.probe([])

    assert {:ok,
            %{
              gates: [
                %{
                  name: "beislid-unit",
                  command: "echo beislid > beislid-gate.txt",
                  timeout_ms: 1_000,
                  action_classes: ["read"]
                }
              ],
              selected: [%{name: "beislid-unit", reason: "matched Beislið post-turn proof requirement"}],
              skipped: [%{name: "slow-proof", reason: "not required for this slice"}],
              warnings: [%{message: "fixture-backed Beislið artifact"}],
              metadata: %{
                provider: "beislid",
                artifact_id: "beislid-fixture-approved",
                artifact_ref: "beislid-fixture-approved",
                source_kind: "fixture",
                stage: :post_turn
              }
            }} = Beislid.select_gates(stage: :post_turn)
  end

  test "beislid provider filters staged gates for pre-PR selection" do
    temp_dir = Path.join(System.tmp_dir!(), "rondo-beislid-provider-stages-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    artifact_path =
      write_json!(temp_dir, "staged.json", %{
        "schema" => "beislid-process-artifact-v1",
        "id" => "staged-fixture",
        "status" => "approved",
        "gates" => [
          %{"name" => "turn", "command" => "true", "stage" => "post_turn"},
          %{"name" => "pre-pr", "command" => "true", "stage" => "pre_pr"},
          %{"name" => "shared", "command" => "true", "stage" => "shared"},
          %{"name" => "unstaged", "command" => "true"}
        ]
      })

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: artifact_path
    )

    assert {:ok, %{gates: pre_pr_gates, metadata: %{stage: :pre_pr}}} = Beislid.select_gates(stage: :pre_pr)
    assert Enum.map(pre_pr_gates, & &1.name) == ["pre-pr", "shared", "unstaged"]

    assert {:ok, %{gates: post_turn_gates}} = Beislid.select_gates(stage: :post_turn)
    assert Enum.map(post_turn_gates, & &1.name) == ["turn", "shared", "unstaged"]
  end

  test "beislid provider selects deterministic gate union from changed-file selectors" do
    temp_dir = Path.join(System.tmp_dir!(), "rondo-beislid-provider-selectors-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    artifact_path =
      write_json!(temp_dir, "selectors.json", %{
        "schema" => "beislid-process-artifact-v1",
        "id" => "selector-artifact",
        "status" => "approved",
        "gate_sets" => [
          %{
            "id" => "runtime",
            "paths" => ["lib/**/*.ex"],
            "gates" => [
              %{"name" => "compile", "command" => "mix compile", "reason" => "runtime compile proof"},
              %{"name" => "unit", "command" => "mix test", "reason" => "runtime unit proof"}
            ]
          },
          %{
            "id" => "tests",
            "paths" => ["test/**/*.exs"],
            "gates" => [
              %{"name" => "unit", "command" => "mix test", "reason" => "test unit proof"},
              %{"name" => "coverage", "command" => "mix test --cover", "reason" => "test coverage proof"}
            ]
          }
        ],
        "action_policy" => %{"decision" => "allow"}
      })

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: artifact_path
    )

    assert {:ok,
            %{
              gates: [%{name: "compile"}, %{name: "unit"}, %{name: "coverage"}],
              selected: selected,
              skipped: skipped,
              warnings: warnings,
              changed_files: ["docs/usage.md", "lib/rondo/gates.ex", "test/rondo/gates_test.exs"],
              metadata: %{selector_mode: "changed_files", matched_selectors: ["runtime", "tests"]}
            }} =
             Beislid.select_gates(
               changed_files: ["test/rondo/gates_test.exs", "docs/usage.md", "lib/rondo/gates.ex"],
               stage: :post_turn
             )

    assert Enum.map(selected, & &1.name) == ["compile", "unit", "coverage"]
    assert Enum.any?(List.wrap(skipped), &(&1.name == "runtime" and &1.reason =~ "matched")) == false
    assert [%{message: warning, path: "docs/usage.md"}] = warnings
    assert warning =~ "no provider gate selector matched"
  end

  test "beislid provider reports selectors that match paths but no gates for selected stage" do
    temp_dir = Path.join(System.tmp_dir!(), "rondo-beislid-provider-stage-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    artifact_path =
      write_json!(temp_dir, "stage-empty.json", %{
        "schema" => "beislid-process-artifact-v1",
        "id" => "stage-empty-artifact",
        "status" => "approved",
        "gate_sets" => [
          %{
            "id" => "runtime",
            "paths" => ["lib/**/*.ex"],
            "gates" => [
              %{"name" => "post-turn-only", "command" => "mix test", "stage" => "post_turn"}
            ]
          }
        ]
      })

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: artifact_path
    )

    assert {:ok,
            %{
              gates: [],
              selected: [],
              skipped: [%{name: "runtime", reason: reason}],
              warnings: [%{selector: "runtime", stage: "pre_pr"}],
              metadata: %{matched_selectors: [], stage_empty_selectors: ["runtime"]}
            }} = Beislid.select_gates(changed_files: ["lib/rondo/gates.ex"], stage: :pre_pr)

    assert reason =~ "no gates matched stage pre_pr"

    any_stage_path =
      write_json!(temp_dir, "any-stage-empty.json", %{
        "schema" => "beislid-process-artifact-v1",
        "id" => "any-stage-empty-artifact",
        "status" => "approved",
        "gate_sets" => [
          %{
            "id" => "runtime",
            "paths" => ["lib/**/*.ex"],
            "gates" => []
          }
        ]
      })

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: any_stage_path
    )

    assert {:ok, %{skipped: [%{reason: any_stage_reason}]}} = Beislid.select_gates(changed_files: ["lib/rondo/gates.ex"])
    assert any_stage_reason =~ "no gates matched stage any"
  end

  test "beislid provider matches trailing slash and prefix selectors deterministically" do
    temp_dir = Path.join(System.tmp_dir!(), "rondo-beislid-provider-selector-paths-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    artifact_path =
      write_json!(temp_dir, "selector-paths.json", %{
        "schema" => "beislid-process-artifact-v1",
        "id" => "selector-paths-artifact",
        "status" => "approved",
        "gate_sets" => [
          %{
            "id" => "docs-root",
            "paths" => ["docs/"],
            "gates" => [
              %{"name" => "docs-root", "command" => "mix test docs-root", "reason" => "docs tree proof"}
            ]
          },
          %{
            "id" => "docs-changelog",
            "paths" => ["docs/changelog"],
            "gates" => [
              %{"name" => "docs-changelog", "command" => "mix test docs-changelog", "reason" => "docs changelog proof"}
            ]
          },
          %{
            "id" => "docs-usage",
            "paths" => ["docs/usage.md"],
            "gates" => [
              %{"name" => "docs-usage", "command" => "mix test docs-usage", "reason" => "docs usage proof"}
            ]
          }
        ],
        "action_policy" => %{"decision" => "allow"}
      })

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: artifact_path
    )

    assert %{status: :ok, checks: %{changed_file_selectors: :ok}} = Beislid.probe([])

    assert {:ok,
            %{
              gates: [%{name: "docs-root"}, %{name: "docs-changelog"}, %{name: "docs-usage"}],
              selected: selected,
              skipped: skipped,
              changed_files: ["docs/changelog/file.txt", "docs/notes/todo.md", "docs/usage.md"],
              metadata: %{selector_mode: "changed_files", matched_selectors: ["docs-root", "docs-changelog", "docs-usage"]}
            }} =
             Beislid.select_gates(
               changed_files: ["docs/notes/todo.md", "docs/changelog/file.txt", "docs/usage.md"],
               stage: :post_turn
             )

    assert Enum.map(selected, & &1.name) == ["docs-root", "docs-changelog", "docs-usage"]
    assert Enum.map(skipped, & &1.name) == []

    assert {:ok,
            %{
              gates: [],
              selected: [],
              skipped: [%{name: "docs-root"}, %{name: "docs-changelog"}, %{name: "docs-usage"}],
              changed_files: []
            }} =
             Beislid.select_gates(changed_files: :unexpected, stage: :post_turn)
  end

  test "beislid provider augments native prompt and evaluates fixture action policy" do
    artifact_path = fixture_path("approved.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: artifact_path
    )

    issue = %Issue{id: "1", identifier: "RON-9", title: "Adapter", state: "In Progress"}

    assert Beislid.prompt(issue) =~ "You are an agent for this repository."
    assert Beislid.prompt(issue) =~ "Beislið process context"
    assert Beislid.prompt(issue) =~ "beislid-fixture-approved"

    assert {:ok,
            %{
              "decision" => "allow",
              "action" => "gate.run",
              "mode" => "unattended-auto",
              "provider" => "beislid"
            }} = Beislid.evaluate_action_policy("gate.run", ["read"])
  end

  test "beislid provider reports missing and unapproved artifacts without blanket-blocking required model hints" do
    missing_path = Path.join(System.tmp_dir!(), "rondo-missing-beislid-#{System.unique_integer([:positive])}.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: missing_path
    )

    assert %{status: :missing, checks: %{artifact: {:error, {:read_failed, _path, :enoent}}}} =
             Beislid.probe([])

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: fixture_path("unapproved.json")
    )

    assert %{status: :missing, checks: %{artifact: {:error, {:artifact_not_approved, "draft"}}}} =
             Beislid.probe([])

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: fixture_path("required_model.json")
    )

    assert %{status: :ok, checks: %{model_routing_hints: :deferred}} = Beislid.probe([])
  end

  test "beislid provider preserves nested initial model routing hints" do
    temp_dir = Path.join(System.tmp_dir!(), "rondo-beislid-provider-routing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    artifact_path =
      write_json!(temp_dir, "initial-routing.json", %{
        "schema" => "beislid-process-artifact-v1",
        "id" => "initial-routing",
        "status" => "approved",
        "gates" => [],
        "model_routing_hints" => %{
          "tier" => "standard",
          "initial" => %{
            "skill" => "kickoff",
            "phase" => "context_discovery",
            "tier" => "heavy",
            "mode" => "prefer"
          }
        }
      })

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: artifact_path
    )

    assert %{
             "tier" => "standard",
             "initial" => %{
               "skill" => "kickoff",
               "phase" => "context_discovery",
               "tier" => "heavy",
               "mode" => "prefer"
             }
           } = Beislid.model_routing_hints()
  end

  test "beislid provider handles optional callbacks, source path fallback, and malformed artifacts" do
    approved_path = fixture_path("approved.json")
    temp_dir = Path.join(System.tmp_dir!(), "rondo-beislid-provider-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    write_workflow_file!(Workflow.workflow_file_path(), process_provider_kind: "beislid", process_provider_artifact_path: nil)

    issue = %Issue{id: "1", identifier: "RON-9", title: "Adapter", state: "In Progress"}

    assert %{status: :missing} = Beislid.probe()
    assert %{provider_kind: "beislid"} = Beislid.artifact_context()
    assert {:error, :missing_artifact_path} = Beislid.select_gates()
    assert {:ok, []} = Beislid.select_guides()
    assert %{} = Beislid.model_routing_hints()
    assert {:ok, []} = Beislid.proof_requirements()
    assert Beislid.prompt(issue) == Native.prompt(issue)

    rondo_manifest_path = write_json!(temp_dir, "rondo-request.json", %{"schema" => "rondo-execution-request-v1"})

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: approved_path
    )

    assert %{status: :ok} = Beislid.probe(source_contract: %{path: rondo_manifest_path})
    assert %{status: :ok} = Beislid.probe(source_contract: %{path: approved_path})
    assert %{status: :ok} = Beislid.probe(source_contract: %{manifest_path: approved_path})
    assert {:ok, [%{"id" => "review-guide"}]} = Beislid.select_guides()
    assert %{} = Beislid.model_routing_hints()
    assert {:ok, [%{"id" => "unit-proof"}]} = Beislid.proof_requirements()

    write_workflow_file!(Workflow.workflow_file_path(), process_provider_kind: "beislid", process_provider_artifact_path: nil)

    assert %{status: :missing, checks: %{artifact: {:error, :missing_artifact_path}}} =
             Beislid.probe(source_contract: %{path: Path.join(temp_dir, "missing-source-contract.json")})

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: approved_path
    )

    weird_path =
      write_json!(temp_dir, "weird-approved.json", %{
        "schema" => "beislid-process-artifact-v1",
        "id" => "weird",
        "status" => "approved",
        "gates" => [
          %{
            "name" => "weird-gate",
            "command" => "true",
            "timeout_ms" => "bad",
            "action_id" => 123,
            "action_classes" => "read",
            "reason" => ""
          }
        ],
        "skipped" => [%{"unexpected" => true}, %{"name" => "named-default"}],
        "warnings" => [%{"message" => "kept"}],
        "metadata" => %{"unknown_future_key" => "kept-safe", "artifact_ref" => "weird-ref"},
        "guides" => [],
        "proof_requirements" => [],
        "action_policy" => %{}
      })

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: weird_path,
      gates: [%{name: "fallback-timeout", command: "true", timeout_ms: 1234}]
    )

    assert %{checks: %{guide_selection: :unsupported, proof_requirements: :unsupported, action_policy: :missing}} =
             Beislid.probe()

    refute Beislid.action_policy_available?()

    assert {:ok,
            %{
              gates: [%{timeout_ms: 1_234, action_id: nil, action_classes: ["read"]}],
              metadata: %{"unknown_future_key" => "kept-safe", artifact_ref: "weird-ref"}
            }} = Beislid.select_gates()

    assert {:ok, %{metadata: metadata}} = Beislid.select_gates()
    assert Map.has_key?(metadata, "unknown_future_key")
    refute Map.has_key?(metadata, :unknown_future_key)

    assert {:error, :action_policy_unavailable} = Beislid.evaluate_action_policy("gate.run", ["read"])

    non_map_metadata_path =
      write_json!(
        temp_dir,
        "non-map-metadata.json",
        approved_payload(%{"metadata" => "not-a-map", "action_policy" => %{"decision" => "allow"}})
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: non_map_metadata_path
    )

    assert {:ok, %{metadata: metadata}} = Beislid.select_gates()
    assert metadata.artifact_id == "invalid-section-fixture"
    assert Beislid.action_policy_available?()

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: Path.join(temp_dir, "missing-action-policy-artifact.json")
    )

    refute Beislid.action_policy_available?()

    invalid_json_path = Path.join(temp_dir, "invalid.json")
    File.write!(invalid_json_path, "{")

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: invalid_json_path
    )

    assert %{status: :missing, checks: %{artifact: {:error, {:invalid_json, ^invalid_json_path, _message}}}} =
             Beislid.probe()

    explicit_missing_path = Path.join(temp_dir, "missing-explicit-artifact.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: approved_path
    )

    assert %{status: :missing, checks: %{artifact: {:error, {:read_failed, ^explicit_missing_path, :enoent}}}} =
             Beislid.probe(source_contract: %{process_provider: %{"artifact_path" => explicit_missing_path}})

    assert {:error, {:read_failed, ^explicit_missing_path, :enoent}} =
             Beislid.select_gates(source_contract: %{process_provider: %{"artifact_path" => explicit_missing_path}})

    for {filename, payload, reason} <- [
          {"unsupported.json", %{"schema" => "future-v1"}, {:unsupported_artifact_schema, "future-v1"}},
          {"invalid.json", [], :invalid_artifact},
          {"missing-id.json", approved_payload(%{"id" => nil}), :invalid_artifact_id},
          {"bad-gates.json", approved_payload(%{"gates" => "bad"}), {:invalid_artifact_field, "gates"}},
          {"bad-gate-sets.json", approved_payload(%{"gate_sets" => "bad"}), {:invalid_artifact_field, "gate_sets"}},
          {"bad-gate-set-entry.json", approved_payload(%{"gate_sets" => [123]}), {:invalid_artifact_field, "gate_sets"}},
          {"bad-gate.json", approved_payload(%{"gates" => [%{"name" => "missing-command"}]}), {:invalid_artifact_field, "gates"}},
          {"blank-gate.json", approved_payload(%{"gates" => [%{"name" => " ", "command" => "true"}]}), {:invalid_artifact_field, "gates"}},
          {"bad-skipped.json", approved_payload(%{"skipped" => "bad"}), {:invalid_artifact_field, "skipped"}},
          {"bad-skipped-entry.json", approved_payload(%{"skipped" => [123]}), {:invalid_artifact_field, "skipped"}},
          {"bad-skipped-name.json", approved_payload(%{"skipped" => [%{"name" => 123}]}), {:invalid_artifact_field, "skipped"}},
          {"bad-warnings.json", approved_payload(%{"warnings" => "bad"}), {:invalid_artifact_field, "warnings"}},
          {"bad-warning-entry.json", approved_payload(%{"warnings" => [123]}), {:invalid_artifact_field, "warnings"}},
          {"bad-guides.json", approved_payload(%{"guides" => "bad"}), {:invalid_artifact_field, "guides"}},
          {"bad-guide-entry.json", approved_payload(%{"guides" => [123]}), {:invalid_artifact_field, "guides"}},
          {"bad-proofs.json", approved_payload(%{"proof_requirements" => "bad"}), {:invalid_artifact_field, "proof_requirements"}},
          {"bad-proof-entry.json", approved_payload(%{"proof_requirements" => [123]}), {:invalid_artifact_field, "proof_requirements"}},
          {"bad-action-policy.json", approved_payload(%{"action_policy" => "bad"}), {:invalid_artifact_field, "action_policy"}},
          {"bad-action-policy-decision.json", approved_payload(%{"action_policy" => %{"decision" => "maybe"}}), {:invalid_artifact_field, "action_policy"}}
        ] do
      path = write_json!(temp_dir, filename, payload)

      write_workflow_file!(Workflow.workflow_file_path(),
        process_provider_kind: "beislid",
        process_provider_artifact_path: path
      )

      assert %{status: :missing, checks: %{artifact: {:error, ^reason}}} = Beislid.probe()
    end

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: fixture_path("required_model.json")
    )

    assert {:ok, %{gates: [], metadata: %{provider: "beislid"}}} = Beislid.select_gates()
  end

  test "process provider failure payload includes provider kind, artifact path, and actionable reason" do
    temp_dir = Path.join(System.tmp_dir!(), "rondo-process-provider-failure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    invalid_json_path = Path.join(temp_dir, "invalid.json")
    File.write!(invalid_json_path, "{")

    source_path = fixture_path("approved.json")
    request_path = Path.join(temp_dir, "compat-request.json")
    File.write!(request_path, Jason.encode!(%{"schema" => "rondo-execution-request-v1"}))

    for {phase, reason, expected_code, artifact_path, artifact_source, message_fragment, opts} <- [
          {
            :gate_selection,
            :missing_artifact_path,
            "process_provider_missing_artifact_path",
            nil,
            nil,
            "no configured artifact path",
            [process_provider_artifact_path: nil]
          },
          {
            :gate_selection,
            {:invalid_json, invalid_json_path, "bad json"},
            "process_provider_invalid_json",
            invalid_json_path,
            :config,
            "invalid JSON",
            [process_provider_artifact_path: invalid_json_path]
          },
          {
            :gate_selection,
            {:unsupported_artifact_schema, "future-v1"},
            "process_provider_unsupported_artifact_schema",
            source_path,
            :config,
            "unsupported schema",
            [process_provider_artifact_path: source_path]
          },
          {
            :gate_selection,
            {:artifact_not_approved, "draft"},
            "process_provider_artifact_not_approved",
            source_path,
            :config,
            "not approved",
            [
              process_provider_artifact_path: source_path,
              source_contract: %{path: request_path}
            ]
          },
          {
            :action_policy,
            :action_policy_unavailable,
            "process_provider_action_policy_unavailable",
            source_path,
            :source_contract_process_provider,
            "no usable action_policy",
            [
              process_provider_artifact_path: source_path,
              source_contract: %{process_provider: %{artifact_path: source_path}}
            ]
          },
          {
            :action_policy,
            {:action_policy_requires_approval, %{"decision" => "ask"}},
            "process_provider_action_policy_requires_approval",
            source_path,
            :source_contract_process_provider,
            "requires approval",
            [
              process_provider_artifact_path: source_path,
              source_contract: %{process_provider: %{artifact_path: source_path}}
            ]
          },
          {
            :action_policy,
            {:action_policy_denied, %{"decision" => "deny"}},
            "process_provider_action_policy_denied",
            source_path,
            :source_contract_process_provider,
            "rejected by action policy",
            [
              process_provider_artifact_path: source_path,
              source_contract: %{process_provider: %{artifact_path: source_path}}
            ]
          }
        ] do
      write_workflow_file!(Workflow.workflow_file_path(),
        process_provider_kind: "beislid",
        process_provider_artifact_path: Keyword.get(opts, :process_provider_artifact_path)
      )

      payload = ProcessProvider.failure_payload(Beislid, phase, reason, Keyword.put(opts, :required, true))

      assert payload.provider_kind == "beislid"
      assert payload.phase == Atom.to_string(phase)
      assert payload.reason_code == expected_code
      assert payload.required == true
      assert payload.reason =~ inspect(reason)
      assert payload.message =~ message_fragment
      assert Map.get(payload, :artifact_path) == artifact_path
      assert Map.get(payload, :artifact_source) == artifact_source
    end
  end

  test "failure payload fallback branches preserve provider context and wrapped artifact paths" do
    temp_dir = Path.join(System.tmp_dir!(), "rondo-process-provider-failure-fallback-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    compat_path = Path.join(temp_dir, "compat-request.json")
    config_path = Path.join(temp_dir, "config.json")
    File.write!(compat_path, Jason.encode!(%{"schema" => "rondo-execution-request-v1"}))
    File.write!(config_path, Jason.encode!(%{"schema" => "beislid-process-artifact-v1", "id" => "artifact", "status" => "draft"}))

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: config_path
    )

    assert %{
             provider_kind: "legacy",
             artifact_source: :source_contract_process_provider,
             artifact_path: ^compat_path,
             reason_code: "process_provider_missing_artifact_path"
           } =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               :missing_artifact_path,
               source_contract: %{process_provider: %{"artifact_path" => compat_path}}
             )

    assert %{
             artifact_source: :config,
             artifact_path: ^config_path,
             reason_code: "process_provider_read_failed"
           } =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:error, {:artifact_error, :config, config_path, {:read_failed, config_path, :enoent}}},
               source_contract: %{path: compat_path}
             )

    assert %{
             artifact_source: :source_contract_path,
             artifact_path: ^compat_path,
             reason_code: "process_provider_artifact_not_approved"
           } =
             ProcessProvider.failure_payload(
               "legacy",
               "action_policy",
               {:artifact_not_approved, "draft"},
               source_contract: %{manifest_path: compat_path}
             )

    assert %{
             artifact_source: :config,
             artifact_path: ^config_path,
             reason_code: "process_provider_missing_artifact_path"
           } = ProcessProvider.failure_payload("legacy", :gate_selection, :missing_artifact_path, [])

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: nil
    )

    assert %{
             provider_kind: "123",
             phase: "123",
             reason_code: "process_provider_123_failed"
           } = ProcessProvider.failure_payload(123, 123, :other, [])

    refute Map.has_key?(ProcessProvider.failure_payload(123, 123, :other, []), :artifact_path)
  end

  test "failure payload covers wrapped reasons, probe status fallbacks, and slug edge cases" do
    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: nil
    )

    assert %{reason_code: "process_provider_failed", reason: "{:process_provider_failed, %{foo: :bar}}"} =
             ProcessProvider.failure_payload("legacy", :gate_selection, {:process_provider_failed, %{foo: :bar}}, [])

    assert %{reason_code: "process_provider_gate_selection_failed"} =
             ProcessProvider.failure_payload("legacy", :gate_selection, :other)

    assert %{reason_code: "process_provider_gate_selection_failed"} =
             Failure.payload("legacy", :gate_selection, :other)

    assert %{provider_kind: "no_id_provider"} =
             ProcessProvider.failure_payload(NoIdProvider, :gate_selection, :other, [])

    assert %{reason_code: "process_provider_required_failed"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:process_provider_required_failed, %{foo: :bar}},
               []
             )

    assert %{reason_code: "process_provider_gate_selection_missing"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:probe_failed, %{status: :missing, checks: %{artifact: :ok}}},
               []
             )

    assert %{
             reason_code: "process_provider_read_failed",
             artifact_source: :config
           } =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:artifact_error, :config, nil, {:read_failed, nil, :enoent}},
               []
             )

    refute Map.has_key?(
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:artifact_error, :config, nil, {:read_failed, nil, :enoent}},
               []
             ),
             :artifact_path
           )

    assert %{reason_code: "process_provider_read_failed"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:read_failed, nil, :enoent},
               []
             )

    refute Map.has_key?(
             ProcessProvider.failure_payload("legacy", :gate_selection, {:read_failed, nil, :enoent}, []),
             :artifact_path
           )

    assert %{reason_code: "process_provider_invalid_json"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:invalid_json, nil, "bad json"},
               []
             )

    refute Map.has_key?(
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:invalid_json, nil, "bad json"},
               []
             ),
             :artifact_path
           )

    assert %{reason_code: "process_provider_invalid_artifact_id"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:invalid_artifact_id, %{foo: :bar}},
               []
             )

    assert %{reason_code: "process_provider_gate_selection_missing"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               %{status: :missing, checks: %{artifact: :ok}},
               []
             )

    assert %{reason_code: "process_provider_gate_selection_unknown"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               %{status: "", checks: %{artifact: :ok}},
               []
             )

    assert %{reason_code: "process_provider_action_policy_unavailable"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               %{status: :missing, checks: %{action_policy: :missing}},
               []
             )

    assert %{reason_code: "process_provider_action_policy_unavailable"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               %{status: :missing, checks: %{action_policy: "missing"}},
               []
             )

    assert %{reason_code: "process_provider_gate_selection_missing"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               %{status: :missing, checks: %{action_policy: :ok}},
               []
             )

    assert %{reason_code: "process_provider_gate_selection_missing"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               %{status: :missing, checks: %{action_policy: "ok"}},
               []
             )

    assert %{reason_code: "process_provider_gate_selection_missing"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               %{status: :missing, checks: %{action_policy: %{foo: "bar"}}},
               []
             )

    assert %{reason_code: "process_provider_invalid_artifact_field_some_field"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:invalid_artifact_field, :some_field},
               []
             )

    assert %{reason_code: "process_provider_invalid_artifact_field_unknown"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:invalid_artifact_field, ""},
               []
             )

    assert %{reason_code: "process_provider_invalid_artifact_field_123"} =
             ProcessProvider.failure_payload(
               "legacy",
               :gate_selection,
               {:invalid_artifact_field, 123},
               []
             )

    assert %{reason: "plain text"} =
             ProcessProvider.failure_payload("legacy", :gate_selection, "plain text")
  end

  test "beislid provider prefers source_contract process provider artifact path" do
    config_path = fixture_path("unapproved.json")
    source_path = fixture_path("approved.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: config_path
    )

    source_contract = %{process_provider: %{artifact_path: source_path}}

    assert %{status: :ok} = Beislid.probe(source_contract: source_contract)

    assert {:ok, %{metadata: %{artifact_id: "beislid-fixture-approved"}}} =
             Beislid.select_gates(source_contract: source_contract)
  end

  test "provider facade helpers expose defaults, normalized selections, and errors" do
    assert ProcessProvider.probe_result(:ok) == %{status: :ok, checks: %{}}

    assert {:ok,
            %{
              gates: [%{name: "legacy"}],
              selected: [%{name: "legacy", reason: "selected by process provider"}],
              skipped: [],
              warnings: []
            }} = ProcessProvider.select_gate_selection(LegacyListProvider)

    assert [%{name: "legacy"}] = ProcessProvider.select_gates!(LegacyListProvider)
    assert %{gates: []} = ProcessProvider.select_gate_selection!()

    assert_raise RuntimeError, ~r/process_provider_gate_selection_failed: :provider_unavailable/, fn ->
      ProcessProvider.select_gates!(ErrorProvider)
    end

    evaluator = ProcessProvider.action_policy_evaluator()

    assert {:ok, %{"decision" => "allow", "action" => "file.read"}} =
             evaluator.("file.read", ["read"], command: fake_evaluator("allow"))
  end

  defp fixture_path(filename) do
    Path.expand(Path.join([__DIR__, "..", "fixtures", "beislid_process_provider", filename]))
  end

  defp approved_payload(overrides) do
    Map.merge(
      %{
        "schema" => "beislid-process-artifact-v1",
        "id" => "invalid-section-fixture",
        "status" => "approved",
        "gates" => []
      },
      overrides
    )
  end

  defp write_json!(dir, filename, payload) do
    path = Path.join(dir, filename)
    File.write!(path, Jason.encode!(payload))
    path
  end

  defp fake_evaluator(decision) do
    evaluator_dir = Path.join(System.tmp_dir!(), "rondo-process-provider-evaluator-#{System.unique_integer([:positive])}")
    path = Path.join(evaluator_dir, "beislid")
    File.mkdir_p!(Path.dirname(path))

    script = ~s'''
    #!/bin/sh
    action=""
    classes=""
    mode=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --action) action="$2"; shift 2 ;;
        --class) classes="${classes}${classes:+,}$2"; shift 2 ;;
        --mode) mode="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '{"decision":"#{decision}","action":"%s","classes":["read"],"mode":"%s"}' "$action" "$mode"
    '''

    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end
end
