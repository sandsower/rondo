defmodule Rondo.DeliveryArtifactTest do
  use Rondo.TestSupport

  alias Rondo.{DeliveryArtifact, RunLedger}

  @now ~U[2026-06-11 09:00:00Z]

  test "writes a completed-run delivery artifact with redacted shape and proof links" do
    workspace_root = tmp_dir("delivery-shape")

    source_contract = %{
      schema: "rondo-execution-request-v1",
      slice_id: "slice-123",
      path: "/tmp/request.json",
      sha256: String.duplicate("a", 64),
      envelope: %{schema: "execution-envelope-v0", id: "ron-10-delivery-artifact-v0", sha256: String.duplicate("b", 64)},
      parent_contract: %{"id" => "parent-1"}
    }

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "decafbad",
               source_contract: source_contract
             )

    assert DeliveryArtifact.schema() == "rondo-delivery-artifact-v0"
    assert DeliveryArtifact.relative_path() == "artifacts/delivery-artifact.json"

    gate_results_path = Path.join(ledger.run_dir, "artifacts/gates/turn-0001/results.json")
    File.mkdir_p!(Path.dirname(gate_results_path))

    File.write!(
      gate_results_path,
      Jason.encode!(%{
        "status" => "pass",
        "results" => [
          %{
            "name" => "unit",
            "status" => "pass",
            "stdout_path" => "artifacts/gates/turn-0001/0001-unit-stdout.log",
            "stderr_path" => "artifacts/gates/turn-0001/0001-unit-stderr.log"
          }
        ]
      })
    )

    assert {:ok, ledger} =
             RunLedger.link_artifacts(ledger, [
               %{"kind" => "gate_results", "path" => "artifacts/gates/turn-0001/results.json"}
             ])

    assert {:ok, ledger} =
             RunLedger.write_checkpoint(ledger, :interrupt_created, %{reason: "operator", question: "Continue?"}, timestamp: @now)

    decision = %{
      "action" => "git.push",
      "classes" => ["git-remote"],
      "decision" => "allow",
      "token" => "ghp_abcdefghijklmnopqrst123456"
    }

    assert {:ok, ledger} =
             RunLedger.record_action_policy_decision(ledger, decision,
               human_outcome: "auto-allowed",
               side_effect_status: "not_started"
             )

    assert {:ok, ledger} =
             RunLedger.write_checkpoint(ledger, :clean_eval_completed, %{status: "pass"},
               manifest_update: fn manifest -> Map.put(manifest, "clean_eval", %{"status" => "pass", "result_path" => "clean_eval/result.json"}) end
             )

    final_report = %{
      "schema" => "rondo.final_report/v0",
      "summary" => "Implemented delivery artifact with API_KEY=supersecretvalue",
      "changed_files" => ["lib/rondo/delivery_artifact.ex"],
      "gates_run" => [%{"name" => "unit", "status" => "pass"}],
      "failures" => [],
      "risks" => [%{"id" => "r1", "severity" => "low", "description" => "Watch export consumers"}],
      "next_state" => "ready_for_review",
      "deferred_work" => [%{"description" => "Future exporter can copy referenced files"}],
      "memory_lesson_candidates" => [%{"title" => "Delivery artifacts link proof"}]
    }

    assert {:ok, ledger, :valid} = RunLedger.record_final_report(ledger, Jason.encode!(final_report))
    assert {:ok, ledger} = RunLedger.record_patch_secret_scan(ledger, :pass, %{"scanner" => "rondo.redaction/v0"})
    assert {:ok, ledger} = RunLedger.complete_run(ledger, :completed, %{mode: "test"}, timestamp: @now)

    assert DeliveryArtifact.build(ledger)["schema"] == "rondo-delivery-artifact-v0"

    delivery_path = Path.join(ledger.run_dir, "artifacts/delivery-artifact.json")
    assert File.exists?(delivery_path)

    manifest = decode_json!(ledger.manifest_path)

    assert %{
             "kind" => "delivery_artifact",
             "path" => "artifacts/delivery-artifact.json",
             "recorded_at" => recorded_at,
             "status" => "present"
           } = Enum.find(manifest["artifacts"], &(&1["kind"] == "delivery_artifact"))

    assert {:ok, _datetime, 0} = DateTime.from_iso8601(recorded_at)

    artifact = decode_json!(delivery_path)
    assert artifact["schema"] == "rondo-delivery-artifact-v0"
    assert artifact["run"]["run_id"] == ledger.run_id
    assert artifact["run"]["status"] == "completed"

    assert artifact["run"]["issue"] == %{
             "id" => "issue-delivery",
             "identifier" => "MT-601",
             "labels" => ["P1"],
             "title" => "Delivery artifact",
             "url" => "https://example.org/issues/MT-601"
           }

    assert artifact["source"]["contract_schema"] == "rondo-execution-request-v1"
    assert artifact["source"]["contract_id"] == "slice-123"
    assert artifact["source"]["contract_sha256"] == String.duplicate("a", 64)
    assert artifact["source"]["envelope_id"] == "ron-10-delivery-artifact-v0"
    assert artifact["source"]["parent_contract"] == %{"id" => "parent-1"}

    assert artifact["summary"]["status"] == "completed"
    assert artifact["summary"]["changed_files"] == ["lib/rondo/delivery_artifact.ex"]
    refute artifact["summary"]["final_report"] =~ "supersecretvalue"
    assert artifact["summary"]["final_report"] =~ "[REDACTED]"

    assert artifact["outputs"]["run_ledger_manifest"] == "manifest.json"
    assert artifact["outputs"]["agent_events"] == "artifacts/agent-events.ndjson"
    assert artifact["outputs"]["archive"] == nil

    assert artifact["proof"]["status"] == "pass"
    assert [gate] = artifact["proof"]["gate_results"]
    assert gate["name"] == "unit"
    assert gate["results_path"] == "artifacts/gates/turn-0001/results.json"
    assert gate["stdout_path"] == "artifacts/gates/turn-0001/0001-unit-stdout.log"
    assert artifact["proof"]["review"]["clean_eval"] == %{"status" => "pass", "result_path" => "clean_eval/result.json"}

    assert [%{"question" => "Continue?", "reason" => "operator"}] = artifact["interrupts"]
    assert [%{"action" => "git.push", "token" => "[REDACTED]"} = decision] = artifact["human_decisions"]
    assert decision["human_outcome"] == "auto-allowed"
    assert [%{"id" => "r1"}] = artifact["risks"]
    assert [%{"description" => "Future exporter can copy referenced files"}] = artifact["deferred_work"]
    assert [%{"title" => "Delivery artifacts link proof"}] = artifact["memory_lesson_candidates"]
    refute artifact |> Jason.encode!() |> String.contains?("stdout contents")

    assert artifact["redaction"] == %{
             "content_fields_summarized" => true,
             "notes" => "Raw logs, prompts, and diffs are linked by artifact path rather than embedded.",
             "policy" => "rondo-delivery-artifact-v0-default",
             "raw_logs_embedded" => false,
             "secret_fields_redacted" => true
           }

    assert artifact["portability"]["uses_relative_paths"] == true
    assert artifact["portability"]["requires_local_workspace"] == false
    assert artifact["portability"]["external_links"] == ["https://example.org/issues/MT-601"]

    assert {:ok, ledger} = RunLedger.link_archive(ledger, "/tmp/rondo/archive.json")
    refreshed = decode_json!(Path.join(ledger.run_dir, "artifacts/delivery-artifact.json"))
    assert refreshed["outputs"]["archive"] == nil
    assert refreshed["portability"]["requires_local_workspace"] == true
    refute refreshed |> Jason.encode!() |> String.contains?("/tmp/rondo/archive.json")
  end

  test "skips incomplete ledgers and blocks delivery when a patch contains a secret" do
    workspace_root = tmp_dir("delivery-blocks")

    assert {:ok, running_ledger} =
             RunLedger.create_run(issue_fixture(), workspace_root: workspace_root, now: @now, random_suffix: "00000001")

    assert {:ok, _ledger, :skipped_not_completed} = DeliveryArtifact.write(running_ledger)
    refute File.exists?(Path.join(running_ledger.run_dir, "artifacts/delivery-artifact.json"))

    assert {:ok, blocked_ledger} =
             RunLedger.create_run(issue_fixture(), workspace_root: workspace_root, now: @now, random_suffix: "00000002")

    assert {:ok, blocked_ledger} =
             RunLedger.record_patch_secret_scan(blocked_ledger, :fail, %{
               "scanner" => "rondo.redaction/v0",
               "failure_classification" => "patch_contains_secret",
               "patch_path" => "artifacts/changes.patch"
             })

    assert {:ok, blocked_ledger} = RunLedger.complete_run(blocked_ledger, :completed, %{mode: "test"}, timestamp: @now)
    assert {:ok, _blocked_ledger, :blocked_patch_contains_secret} = DeliveryArtifact.write(blocked_ledger)

    manifest = decode_json!(blocked_ledger.manifest_path)
    assert manifest["failure_classification"] == "patch_contains_secret"
    refute Enum.any?(manifest["artifacts"], &(&1["kind"] == "delivery_artifact"))
    refute File.exists?(Path.join(blocked_ledger.run_dir, "artifacts/delivery-artifact.json"))
  end

  defp issue_fixture do
    %Issue{
      id: "issue-delivery",
      identifier: "MT-601",
      title: "Delivery artifact",
      description: "Emit a completed-run bundle",
      state: "In Progress",
      url: "https://example.org/issues/MT-601",
      labels: ["P1"],
      priority: 1
    }
  end

  defp decode_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
