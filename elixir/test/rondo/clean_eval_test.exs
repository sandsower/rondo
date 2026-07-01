defmodule Rondo.CleanEvalTest do
  use Rondo.TestSupport

  alias Rondo.CleanEval
  alias Rondo.RunLedger

  defmodule PrePrProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "test_pre_pr"

    @impl true
    def capabilities, do: %{gate_selection: :test}

    @impl true
    def probe(_opts \\ []), do: Rondo.ProcessProvider.probe_result(:ok, %{gate_selection: :ok})

    @impl true
    def select_gates(opts \\ []) do
      if parent = Process.get(:clean_eval_test_parent) do
        send(parent, {:clean_eval_select_gates, opts})
      end

      gates = [
        %{
          name: "provider pre-pr",
          command: "test -f new.txt",
          timeout_ms: 10_000,
          action_id: "gate.provider-pre-pr",
          action_classes: ["read"]
        }
      ]

      {:ok,
       Rondo.ProcessProvider.gate_selection_result(gates,
         selected: [%{name: "provider pre-pr", reason: "selected for pre-PR clean evaluation"}],
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
         "mode" => Keyword.get(opts, :mode, "unattended-auto"),
         "provider" => id()
       }}
    end
  end

  defmodule FailingProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "failing_pre_pr"

    @impl true
    def capabilities, do: %{gate_selection: :test}

    @impl true
    def probe(_opts \\ []), do: Rondo.ProcessProvider.probe_result(:ok, %{gate_selection: :ok})

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
    def evaluate_action_policy(action, classes, opts \\ []) do
      {:ok,
       %{
         "decision" => "allow",
         "action" => action,
         "classes" => classes,
         "mode" => Keyword.get(opts, :mode, "unattended-auto"),
         "provider" => id()
       }}
    end
  end

  defmodule ConfigurableProcessProvider do
    @behaviour Rondo.ProcessProvider

    @impl true
    def id, do: "configurable_pre_pr"

    @impl true
    def capabilities, do: %{gate_selection: :test}

    @impl true
    def probe(_opts \\ []), do: Rondo.ProcessProvider.probe_result(:ok, %{gate_selection: :ok})

    @impl true
    def select_gates(_opts \\ []), do: Process.get(:clean_eval_select_gates_result)

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
         "mode" => Keyword.get(opts, :mode, "unattended-auto"),
         "provider" => id()
       }}
    end
  end

  test "exposes the clean-eval artifact contract" do
    assert CleanEval.schema() == "rondo.clean_eval/v0"
    assert CleanEval.result_relative_path() == "clean_eval/result.json"
  end

  test "is disabled by default and enabled via clean_eval config" do
    refute CleanEval.enabled?()

    write_workflow_file!(Workflow.workflow_file_path(), clean_eval_enabled: true)
    assert CleanEval.enabled?()
  end

  test "clean_eval gates fall back to top-level gates when unset" do
    write_workflow_file!(Workflow.workflow_file_path(),
      gates: [%{name: "unit", command: "true"}],
      clean_eval_enabled: true
    )

    assert [%{name: "unit", command: "true"}] = Config.clean_eval_gates()

    write_workflow_file!(Workflow.workflow_file_path(),
      gates: [%{name: "unit", command: "true"}],
      clean_eval_enabled: true,
      clean_eval_base_ref: "main",
      clean_eval_gates: [%{name: "eval", command: "false", timeout_ms: 2_000}]
    )

    assert [%{name: "eval", command: "false", timeout_ms: 2_000}] = Config.clean_eval_gates()
    assert Config.clean_eval_base_ref() == "main"
  end

  test "explicitly empty clean_eval gates mean apply-only evaluation" do
    context =
      setup_run("clean-eval-empty-gates",
        gates: [%{name: "would fail", command: "false"}],
        clean_eval_enabled: true,
        clean_eval_gates: []
      )

    write_patch_artifacts!(context)

    assert Config.clean_eval_gates() == []
    assert {:ok, _ledger, result} = CleanEval.run(context.ledger)
    assert result.status == :pass
    assert result.gates == nil
  end

  test "rejects invalid clean_eval config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      clean_eval_enabled: "maybe",
      clean_eval_base_ref: "",
      clean_eval_gates: [%{name: "", command: ""}]
    )

    assert {:error, {:invalid_workflow_config, _path, errors}} = Config.validate!()
    fields = Enum.map(errors, & &1.path)
    assert "clean_eval.enabled" in fields
    assert "clean_eval.base_ref" in fields
    assert "clean_eval.gates.0.name" in fields
    assert "clean_eval.gates.0.command" in fields
  end

  test "applies the patch on a clean worktree, runs gates, and reports pass in the ledger" do
    context = setup_run("clean-eval-pass")
    write_patch_artifacts!(context)

    gates = [%{name: "check files", command: "grep -q added file.txt && test -f new.txt", timeout_ms: 10_000}]

    assert {:ok, ledger, result} = CleanEval.run(context.ledger, gates: gates)
    assert result.status == :pass
    assert result.patch_status == "applied"
    assert result.apply_exit_status == 0
    assert result.base_ref == context.base_ref
    assert result.cleanup == %{removed: true, method: "worktree_remove"}
    assert result.gates.status == :pass

    # The dirty agent workspace is untouched; the eval workspace is gone.
    assert File.read!(Path.join(context.workspace, "file.txt")) =~ "added"
    refute File.exists?(eval_workspace(context))
    {worktrees, 0} = System.cmd("git", ["worktree", "list"], cd: context.workspace)
    refute worktrees =~ ".rondo_clean_eval"

    result_json = read_result_json!(context)
    assert result_json["schema"] == "rondo.clean_eval/v0"
    assert result_json["status"] == "pass"
    assert result_json["base_ref"] == context.base_ref
    assert result_json["patch_path"] == "artifacts/changes.patch"
    assert result_json["gates"]["status"] == "pass"
    assert result_json["cleanup"]["removed"] == true

    gate_results = context.ledger.run_dir |> Path.join("clean_eval/gates/results.json") |> File.read!() |> Jason.decode!()
    assert gate_results["status"] == "pass"

    assert ledger.manifest["clean_eval"] == %{"status" => "pass", "result_path" => "clean_eval/result.json"}
    assert Enum.any?(ledger.manifest["checkpoints"], &(&1["kind"] == "clean_eval_completed"))
    artifact_kinds = Enum.map(ledger.manifest["artifacts"], & &1["kind"])
    assert "clean_eval_result" in artifact_kinds
    assert "clean_eval_gate_results" in artifact_kinds
  end

  test "uses the configured process provider pre-PR gate selection in the clean worktree" do
    context = setup_run("clean-eval-provider-pre-pr", clean_eval_enabled: true)
    write_patch_artifacts!(context)
    Process.put(:clean_eval_test_parent, self())

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, process_provider: PrePrProcessProvider, source_contract: %{path: Path.join(context.root, "request.json")})
    assert result.status == :pass
    assert [%{"name" => "provider pre-pr", "status" => "pass"}] = read_result_json!(context)["gates"]["results"]

    assert_received {:clean_eval_select_gates, opts}
    assert Keyword.fetch!(opts, :stage) == :pre_pr
    assert Keyword.fetch!(opts, :source_workspace) == context.workspace
    assert Keyword.fetch!(opts, :workspace) == eval_workspace(context)
    assert Keyword.fetch!(opts, :source_contract) == %{path: Path.join(context.root, "request.json")}

    gate_selection = read_result_json!(context)["gates"]["gate_selection"]
    assert gate_selection["metadata"]["provider"] == "test_pre_pr"
    assert gate_selection["metadata"]["stage"] == "pre_pr"
  after
    Process.delete(:clean_eval_test_parent)
  end

  test "falls back to native pre-PR gates when an optional provider gate selection fails" do
    context =
      setup_run("clean-eval-provider-fallback",
        clean_eval_enabled: true,
        clean_eval_gates: [%{name: "native fallback", command: "test -f new.txt", timeout_ms: 10_000}]
      )

    write_patch_artifacts!(context)

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, process_provider: FailingProcessProvider)
    assert result.status == :pass

    gate_selection = read_result_json!(context)["gates"]["gate_selection"]
    assert gate_selection["metadata"]["fallback_from"] == "failing_pre_pr"
    assert gate_selection["metadata"]["fallback_reason"] =~ "provider_unavailable"
    assert gate_selection["metadata"]["action_policy_provider"] == "native"
    assert [%{"message" => message}] = gate_selection["warnings"]
    assert message =~ "fell back to native gates"
  end

  test "returns an error when a Beislið artifact is invalid" do
    artifact_path = beislid_fixture_path("unapproved.json")

    context =
      setup_run("clean-eval-beislid-invalid-artifact",
        clean_eval_enabled: true,
        process_provider_kind: "beislid",
        process_provider_artifact_path: artifact_path
      )

    request_manifest_path = Path.join(context.root, "request.json")
    File.write!(request_manifest_path, Jason.encode!(%{"schema" => "rondo-execution-request-v1"}))
    write_patch_artifacts!(context)

    assert {:ok, _ledger, result} =
             CleanEval.run(context.ledger,
               process_provider: Rondo.ProcessProvider.Beislid,
               source_contract: %{path: request_manifest_path}
             )

    assert result.status == :error
    assert result.reason_code == "process_provider_artifact_not_approved"
    assert result.process_provider_failure.provider_kind == "beislid"
    assert result.process_provider_failure.artifact_source == :config
    assert result.process_provider_failure.artifact_path == artifact_path
    assert result.reason =~ "not approved"
    assert read_result_json!(context)["status"] == "error"
    assert read_result_json!(context)["reason_code"] == "process_provider_artifact_not_approved"
  end

  test "treats changed-file selector empty gate selections as errors" do
    context = setup_run("clean-eval-empty-selector-selection", clean_eval_enabled: true)
    write_patch_artifacts!(context)

    Process.put(
      :clean_eval_select_gates_result,
      {:ok,
       Rondo.ProcessProvider.gate_selection_result([],
         changed_files: ["lib/rondo/example.ex"],
         skipped: [%{name: "runtime", reason: "no pre-pr gates"}],
         warnings: [%{message: "selector matched no pre-pr gates"}],
         metadata: %{selector_mode: "changed_files"}
       )}
    )

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, process_provider: ConfigurableProcessProvider)
    assert result.status == :error
    assert result.reason =~ "gate_selection_empty"
    assert result.reason =~ "lib/rondo/example.ex"
  after
    Process.delete(:clean_eval_select_gates_result)
  end

  test "invalid provider artifacts do not fall back to native gates" do
    for {suffix, reason, expected_reason_code} <- [
          {"field", {:invalid_artifact_field, "gates"}, "process_provider_invalid_artifact_field_gates"},
          {"artifact", :invalid_artifact, "process_provider_invalid_artifact"},
          {"artifact-id", :invalid_artifact_id, "process_provider_invalid_artifact_id"},
          {"schema", {:unsupported_artifact_schema, "future"}, "process_provider_unsupported_artifact_schema"},
          {"json", {:invalid_json, "/tmp/artifact.json", "bad json"}, "process_provider_invalid_json"}
        ] do
      context = setup_run("clean-eval-invalid-artifact-#{suffix}", clean_eval_enabled: true)
      write_patch_artifacts!(context)
      Process.put(:clean_eval_select_gates_result, {:error, reason})

      assert {:ok, _ledger, result} = CleanEval.run(context.ledger, process_provider: ConfigurableProcessProvider)
      assert result.status == :error
      assert result.reason_code == expected_reason_code
      assert result.reason =~ "artifact_path"
    end
  after
    Process.delete(:clean_eval_select_gates_result)
  end

  test "returns an error when provider gate selection is required and fails" do
    context =
      setup_run("clean-eval-provider-required",
        clean_eval_enabled: true,
        process_provider_required: true,
        clean_eval_gates: [%{name: "native fallback", command: "test -f new.txt", timeout_ms: 10_000}]
      )

    write_patch_artifacts!(context)

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, process_provider: FailingProcessProvider)
    assert result.status == :error
    assert result.reason_code == "process_provider_gate_selection_failed"
    assert result.reason =~ "provider_unavailable"
  end

  test "uses Beislið pre-PR gates and action policy when the artifact provides policy" do
    artifact_path = beislid_fixture_path("approved.json")

    context =
      setup_run("clean-eval-beislid-allow",
        clean_eval_enabled: true,
        process_provider_kind: "beislid",
        process_provider_artifact_path: artifact_path
      )

    write_patch_artifacts!(context)

    assert {:ok, _ledger, result} =
             CleanEval.run(context.ledger,
               process_provider: Rondo.ProcessProvider.Beislid,
               source_contract: %{path: Path.join(context.root, "request.json")}
             )

    assert result.status == :pass
    gate_selection = read_result_json!(context)["gates"]["gate_selection"]
    assert gate_selection["metadata"]["provider"] == "beislid"
    assert gate_selection["metadata"]["action_policy_provider"] == "beislid"
    assert gate_selection["metadata"]["stage"] == "pre_pr"
  end

  test "uses native action policy when a Beislið artifact lacks policy" do
    artifact_path = beislid_fixture_path("no_policy.json")

    context =
      setup_run("clean-eval-beislid-native-policy",
        clean_eval_enabled: true,
        process_provider_kind: "beislid",
        process_provider_artifact_path: artifact_path
      )

    write_patch_artifacts!(context)

    assert {:ok, _ledger, result} =
             CleanEval.run(context.ledger,
               process_provider: Rondo.ProcessProvider.Beislid
             )

    assert result.status == :pass
    gate_selection = read_result_json!(context)["gates"]["gate_selection"]
    assert gate_selection["metadata"]["provider"] == "beislid"
    assert gate_selection["metadata"]["action_policy_provider"] == "native"
    assert gate_selection["metadata"]["stage"] == "pre_pr"
  end

  test "returns an error when a required Beislið artifact lacks policy" do
    artifact_path = beislid_fixture_path("no_policy.json")

    context =
      setup_run("clean-eval-beislid-required-policy",
        clean_eval_enabled: true,
        process_provider_required: true,
        process_provider_kind: "beislid",
        process_provider_artifact_path: artifact_path
      )

    write_patch_artifacts!(context)

    assert {:ok, _ledger, result} =
             CleanEval.run(context.ledger,
               process_provider: Rondo.ProcessProvider.Beislid
             )

    assert result.status == :error
    assert result.reason_code == "process_provider_action_policy_unavailable"
    assert result.process_provider_failure.provider_kind == "beislid"
    assert result.process_provider_failure.artifact_path == artifact_path
    assert result.process_provider_failure.phase == "action_policy"
    assert read_result_json!(context)["reason_code"] == "process_provider_action_policy_unavailable"
    assert read_result_json!(context)["process_provider_failure"]["artifact_path"] == artifact_path
  end

  test "returns an error when a required Beislið artifact asks for approval or is denied" do
    for {filename, expected_reason_code, message_fragment} <- [
          {"ask_policy.json", "process_provider_action_policy_requires_approval", "requires approval"},
          {"deny_policy.json", "process_provider_action_policy_denied", "rejected by action policy"}
        ] do
      artifact_path = beislid_fixture_path(filename)

      context =
        setup_run("clean-eval-beislid-required-policy-#{filename}",
          clean_eval_enabled: true,
          process_provider_kind: "beislid",
          process_provider_required: true,
          process_provider_artifact_path: artifact_path
        )

      write_patch_artifacts!(context)

      assert {:ok, _ledger, result} =
               CleanEval.run(context.ledger,
                 process_provider: Rondo.ProcessProvider.Beislid
               )

      assert result.status == :error
      assert result.reason_code == expected_reason_code
      assert result.process_provider_failure.provider_kind == "beislid"
      assert result.process_provider_failure.artifact_path == artifact_path
      assert result.process_provider_failure.phase == "action_policy"
      assert result.process_provider_failure.message =~ message_fragment
      assert read_result_json!(context)["reason_code"] == expected_reason_code
      assert read_result_json!(context)["process_provider_failure"]["artifact_path"] == artifact_path
    end
  end

  test "treats optional Beislið policy-blocked summaries as gate errors" do
    artifact_path = beislid_fixture_path("approved.json")

    context =
      setup_run("clean-eval-beislid-optional-policy-blocked",
        clean_eval_enabled: true,
        process_provider_kind: "beislid",
        process_provider_artifact_path: artifact_path
      )

    write_patch_artifacts!(context)

    gate_runner = fn _gates, workspace, _opts ->
      {:error,
       %{
         status: :policy_blocked,
         results_path: "clean_eval/gates/results.json",
         results: [
           %{
             name: "policy",
             command: "true",
             cwd: workspace,
             stdout_path: nil,
             stderr_path: nil,
             status: :failed,
             exit_status: 1,
             duration_ms: 0,
             retryable: false,
             environment_failure: false
           }
         ]
       }}
    end

    assert {:ok, _ledger, result} =
             CleanEval.run(context.ledger,
               process_provider: Rondo.ProcessProvider.Beislid,
               gate_runner: gate_runner
             )

    assert result.status == :error
    assert result.gates.status == :policy_blocked
    assert Enum.any?(result.gates.results, &(&1.status == :failed))
  end

  test "records policy-blocked and denied summaries without a policy match as required failures" do
    artifact_path = beislid_fixture_path("approved.json")

    for status <- [:policy_blocked, :policy_denied] do
      context =
        setup_run("clean-eval-beislid-required-policy-fallback-#{status}",
          clean_eval_enabled: true,
          process_provider_kind: "beislid",
          process_provider_required: true,
          process_provider_artifact_path: artifact_path
        )

      write_patch_artifacts!(context)

      gate_runner = fn _gates, workspace, _opts ->
        {:error,
         %{
           status: status,
           results_path: "clean_eval/gates/results.json",
           results: [
             %{
               name: "policy",
               command: "true",
               cwd: workspace,
               stdout_path: nil,
               stderr_path: nil,
               status: :failed,
               exit_status: 1,
               duration_ms: 0,
               retryable: false,
               environment_failure: false
             }
           ]
         }}
      end

      assert {:ok, _ledger, result} =
               CleanEval.run(context.ledger,
                 process_provider: Rondo.ProcessProvider.Beislid,
                 gate_runner: gate_runner
               )

      assert result.status == :error
      assert result.reason_code == "process_provider_action_policy_failed"
      assert result.process_provider_failure.provider_kind == "beislid"
      assert result.process_provider_failure.artifact_path == artifact_path
      assert result.process_provider_failure.reason =~ "{:gate_failed,"
      assert read_result_json!(context)["reason_code"] == "process_provider_action_policy_failed"
      assert read_result_json!(context)["process_provider_failure"]["artifact_path"] == artifact_path
    end
  end

  test "passes with apply-only evaluation when no gates are configured" do
    context = setup_run("clean-eval-no-gates")
    write_patch_artifacts!(context)

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger)
    assert result.status == :pass
    assert result.gates == nil
    refute Map.has_key?(read_result_json!(context), "gates")
  end

  test "records apply conflicts as evaluator failures" do
    context = setup_run("clean-eval-conflict")
    conflicting_base = context.base_ref
    commit_change!(context.workspace, "file.txt", "two\n")
    write_patch_artifacts!(context, change: "three\n")

    assert {:ok, ledger, result} = CleanEval.run(context.ledger, base_ref: conflicting_base)
    assert result.status == :fail
    assert result.patch_status == "apply_failed"
    assert result.apply_exit_status > 0
    assert is_binary(result.apply_output)
    assert result.cleanup.removed == true
    refute File.exists?(eval_workspace(context))

    result_json = read_result_json!(context)
    assert result_json["status"] == "fail"
    assert result_json["patch_status"] == "apply_failed"
    assert result_json["base_ref"] == conflicting_base
    assert ledger.manifest["clean_eval"]["status"] == "fail"
  end

  test "records gate failures as evaluator failures and still cleans up" do
    context = setup_run("clean-eval-gate-fail")
    write_patch_artifacts!(context)

    gates = [%{name: "boom", command: "echo nope; exit 7", timeout_ms: 10_000}]

    assert {:ok, ledger, result} = CleanEval.run(context.ledger, gates: gates)
    assert result.status == :fail
    assert result.patch_status == "applied"
    assert result.gates.status == :fail
    assert result.cleanup.removed == true
    refute File.exists?(eval_workspace(context))
    assert ledger.manifest["clean_eval"]["status"] == "fail"
  end

  test "maps gate environment failures to errors" do
    context = setup_run("clean-eval-gate-error")
    write_patch_artifacts!(context)

    gates = [%{name: "missing tool", command: "rondo-no-such-tool-xyz", timeout_ms: 10_000}]

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, gates: gates)
    assert result.status == :error
    assert result.gates.status == :error
    refute File.exists?(eval_workspace(context))
  end

  test "records gate runner infrastructure failures as errors" do
    context = setup_run("clean-eval-runner-error")
    write_patch_artifacts!(context)

    gate_runner = fn _gates, _workspace, _opts -> {:error, :gate_runner_unavailable} end
    gates = [%{name: "any", command: "true", timeout_ms: 10_000}]

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, gates: gates, gate_runner: gate_runner)
    assert result.status == :error
    assert result.reason =~ "gate_runner_failed"
    assert result.reason =~ "gate_runner_unavailable"
    refute File.exists?(eval_workspace(context))
  end

  test "skips when the run has no patch artifact" do
    context = setup_run("clean-eval-skip")

    assert {:ok, ledger, result} = CleanEval.run(context.ledger)
    assert result == %{status: :skipped, reason: "missing_patch_artifact"}
    assert read_result_json!(context)["status"] == "skipped"
    assert ledger.manifest["clean_eval"]["status"] == "skipped"
  end

  test "errors when the source workspace is missing" do
    context = setup_run("clean-eval-no-workspace")
    write_patch_artifacts!(context)

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, workspace: Path.join(context.root, "nope"))
    assert result == %{status: :error, reason: "missing_workspace"}
  end

  test "errors when patch metadata is missing or invalid" do
    context = setup_run("clean-eval-bad-metadata")
    write_patch_artifacts!(context)
    metadata_path = Path.join(context.ledger.run_dir, "artifacts/patch.json")

    File.rm!(metadata_path)
    assert {:ok, _ledger, %{status: :error, reason: "missing_patch_metadata"}} = CleanEval.run(context.ledger)

    File.write!(metadata_path, "not json")
    assert {:ok, _ledger, %{status: :error, reason: "invalid_patch_metadata"}} = CleanEval.run(context.ledger)

    File.write!(metadata_path, Jason.encode!(%{"schema" => "rondo.patch/v0"}))
    assert {:ok, _ledger, %{status: :error, reason: "missing_base_ref"}} = CleanEval.run(context.ledger)
  end

  test "recovers from a stale worktree registration left by an interrupted run" do
    context = setup_run("clean-eval-stale-worktree")
    write_patch_artifacts!(context)

    # Simulate a prior run that crashed between worktree creation and cleanup:
    # the directory is gone but git still has the path registered.
    stale = eval_workspace(context)
    git!(context.workspace, ["worktree", "add", "--detach", stale, context.base_ref])
    File.rm_rf!(stale)

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger)
    assert result.status == :pass
    refute File.exists?(stale)
  end

  test "errors when the manifest lacks a workspace root" do
    context = setup_run("clean-eval-no-workspace-root")
    write_patch_artifacts!(context)
    {_root, manifest} = pop_in(context.ledger.manifest, ["repo", "workspace_root"])
    ledger = %{context.ledger | manifest: manifest}

    assert {:ok, _ledger, %{status: :error, reason: "missing_workspace_root"}} = CleanEval.run(ledger)
  end

  test "errors when the clean worktree cannot be created" do
    context = setup_run("clean-eval-bad-base")
    write_patch_artifacts!(context)

    assert {:ok, ledger, result} = CleanEval.run(context.ledger, base_ref: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
    assert result.status == :error
    assert result.reason =~ "worktree_create_failed"
    refute File.exists?(eval_workspace(context))
    assert ledger.manifest["clean_eval"]["status"] == "error"
  end

  test "falls back to rm_rf cleanup when worktree removal fails" do
    context = setup_run("clean-eval-cleanup-fallback")
    write_patch_artifacts!(context)

    runner = fn
      ["worktree", "remove" | _rest], _cwd -> {"forced removal failure", 1}
      args, cwd -> System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    end

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, runner: runner)
    assert result.status == :pass
    assert result.cleanup == %{removed: true, method: "rm_rf"}
    refute File.exists?(eval_workspace(context))
  end

  test "caps oversized apply output in the result artifact" do
    context = setup_run("clean-eval-apply-output-cap")
    write_patch_artifacts!(context)

    runner = fn
      ["apply" | _rest], _cwd -> {String.duplicate("x", 20_000), 1}
      args, cwd -> System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    end

    assert {:ok, _ledger, result} = CleanEval.run(context.ledger, runner: runner)
    assert result.status == :fail
    assert result.patch_status == "apply_failed"
    assert String.ends_with?(result.apply_output, "... (truncated)")
    assert byte_size(result.apply_output) < 20_000
  end

  test "returns an error when the result artifact cannot be persisted" do
    context = setup_run("clean-eval-persist-error")
    File.write!(Path.join(context.ledger.run_dir, "clean_eval"), "blocking file")

    assert {:error, {:clean_eval_result_dir_failed, _reason}} = CleanEval.run(context.ledger)
  end

  defp setup_run(name, workflow_overrides \\ []) do
    root = tmp_dir(name)
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), [workspace_root: root] ++ workflow_overrides)

    workspace = Path.join(root, "RON-1")
    File.mkdir_p!(workspace)
    git!(workspace, ["init"])
    git!(workspace, ["config", "user.email", "clean-eval@example.com"])
    git!(workspace, ["config", "user.name", "Clean Eval"])
    git!(workspace, ["config", "commit.gpgsign", "false"])
    base_ref = commit_change!(workspace, "file.txt", "one\n")

    {:ok, ledger} =
      RunLedger.create_run(
        %{id: "ron-1", identifier: "RON-1", title: "Clean eval", state: "In Progress"},
        workspace_root: root
      )

    %{root: root, workspace: workspace, base_ref: base_ref, ledger: ledger}
  end

  defp commit_change!(workspace, file, contents) do
    File.write!(Path.join(workspace, file), contents)
    git!(workspace, ["add", "--all"])
    git!(workspace, ["commit", "-m", "change #{file}"])
    workspace |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp write_patch_artifacts!(context, opts \\ []) do
    change = Keyword.get(opts, :change, "one\nadded\n")
    File.write!(Path.join(context.workspace, "file.txt"), change)
    File.write!(Path.join(context.workspace, "new.txt"), "brand new\n")
    git!(context.workspace, ["add", "--all", "--intent-to-add"])
    diff = git!(context.workspace, ["diff", "--binary", "HEAD"])
    git!(context.workspace, ["reset", "-q"])

    base_ref = context.workspace |> git!(["rev-parse", "HEAD"]) |> String.trim()
    File.write!(Path.join(context.ledger.run_dir, "artifacts/changes.patch"), diff)

    metadata = %{
      "schema" => "rondo.patch/v0",
      "format" => "git-diff",
      "base_ref" => base_ref,
      "base_branch" => "main",
      "includes_untracked" => true,
      "patch_path" => "artifacts/changes.patch"
    }

    File.write!(Path.join(context.ledger.run_dir, "artifacts/patch.json"), Jason.encode!(metadata))
  end

  defp read_result_json!(context) do
    context.ledger.run_dir |> Path.join("clean_eval/result.json") |> File.read!() |> Jason.decode!()
  end

  defp eval_workspace(context) do
    Path.join([context.root, ".rondo_clean_eval", context.ledger.run_id])
  end

  defp git!(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    output
  end

  defp beislid_fixture_path(filename) do
    Path.expand(Path.join([__DIR__, "..", "fixtures", "beislid_process_provider", filename]))
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
  end
end
