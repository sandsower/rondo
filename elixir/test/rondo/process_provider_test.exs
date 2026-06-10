defmodule Rondo.ProcessProviderTest do
  use Rondo.TestSupport

  alias Rondo.ProcessProvider
  alias Rondo.ProcessProvider.Beislid
  alias Rondo.ProcessProvider.Native

  defmodule ErrorProvider do
    def select_gates(_opts), do: {:error, :provider_unavailable}
  end

  defmodule LegacyListProvider do
    def select_gates(_opts) do
      {:ok, [%{name: "legacy", command: "mix test", timeout_ms: 1_000, action_classes: ["read"]}]}
    end
  end

  test "native provider exposes current workflow gates and unsupported rich features" do
    write_workflow_file!(Workflow.workflow_file_path(),
      gates: [%{name: "unit", command: "mix test", timeout_ms: 120_000}],
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

  test "beislid provider reports missing, unapproved, and unsupported required model artifacts" do
    write_workflow_file!(Workflow.workflow_file_path(),
      process_provider_kind: "beislid",
      process_provider_artifact_path: "/tmp/rondo-missing-beislid.json"
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

    assert %{status: :unsupported, checks: %{blocking: %{model_routing_hints: :unsupported_required_capability}}} =
             Beislid.probe([])
  end

  test "beislid provider handles optional callbacks, source path fallback, and malformed artifacts" do
    approved_path = fixture_path("approved.json")
    temp_dir = Path.join(System.tmp_dir!(), "rondo-beislid-provider-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    write_workflow_file!(Workflow.workflow_file_path(), process_provider_kind: "beislid", process_provider_artifact_path: nil)

    issue = %Issue{id: "1", identifier: "RON-9", title: "Adapter", state: "In Progress"}

    assert %{status: :missing} = Beislid.probe()
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
          {"bad-gates.json", approved_payload(%{"gates" => "bad"}), {:invalid_artifact_field, "gates"}},
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

    assert {:error, {:unsupported_required_capability, :model_routing_hints}} = Beislid.select_gates()
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
