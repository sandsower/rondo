defmodule Rondo.RunLedgerTest do
  use Rondo.TestSupport

  alias Rondo.RunLedger

  @now ~U[2026-05-10 15:30:12Z]

  test "create_run writes a stable manifest and incremental checkpoint index" do
    workspace_root = tmp_dir("ledger-create")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "a1b2c3d4",
               agent_session_id: "session-abc",
               model_routing: %{status: :honored, resolved: %{adapter: "claude_code", model: "sonnet"}},
               started_at: "2026-05-10T15:30:01Z"
             )

    assert ledger.run_id == "MT-401-20260510T153012Z-a1b2c3d4"
    assert ledger.next_seq == 1
    assert File.exists?(ledger.manifest_path)

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["schema_version"] == 1
    assert manifest["run_id"] == ledger.run_id
    assert manifest["status"] == "running"
    assert manifest["issue"]["identifier"] == "MT-401"
    assert manifest["issue"]["title"] == "Durable ledger"
    assert manifest["repo"]["workspace_root"] == Path.expand(workspace_root)
    assert manifest["agent"]["session_id"] == "session-abc"
    assert manifest["agent"]["model_routing"] == %{"status" => "honored", "resolved" => %{"adapter" => "claude_code", "model" => "sonnet"}}
    assert manifest["process_provider"]["kind"] == "native"
    assert manifest["process_provider"]["capabilities"]["gate_selection"] == "native_flat_gates"
    assert manifest["process_provider"]["probe"]["checks"]["guide_selection"] == "unsupported"
    assert manifest["timestamps"]["started_at"] == "2026-05-10T15:30:01Z"
    assert manifest["checkpoints"] == []

    assert {:ok, ledger} =
             RunLedger.write_checkpoint(ledger, :dispatch, %{attempt: 1}, timestamp: @now)

    checkpoint_path = Path.join(ledger.run_dir, "checkpoints/0001-dispatch.json")
    assert File.exists?(checkpoint_path)

    checkpoint = decode_json!(checkpoint_path)
    assert checkpoint["seq"] == 1
    assert checkpoint["kind"] == "dispatch"
    assert checkpoint["payload"] == %{"attempt" => 1}

    manifest = decode_json!(ledger.manifest_path)
    assert [%{"seq" => 1, "kind" => "dispatch", "path" => "checkpoints/0001-dispatch.json"}] = manifest["checkpoints"]
    assert ledger.next_seq == 2
  end

  test "record_model_routing_decision preserves fallback metadata in the manifest and checkpoint" do
    workspace_root = tmp_dir("ledger-model-routing-fallback")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "f1f2f3f4"
             )

    routing = %{
      status: :fallback,
      mode: :prefer,
      requested_tier: "standard",
      candidates: [%{model: "openai-codex/gpt-5.4-mini"}, %{model: "openrouter/deepseek/deepseek-v4-pro"}],
      resolved: %{model: "openrouter/deepseek/deepseek-v4-pro"},
      reason: "fallback from openai-codex/gpt-5.4-mini to openrouter/deepseek/deepseek-v4-pro",
      fallback: %{
        failed_candidate: %{model: "openai-codex/gpt-5.4-mini"},
        next_candidate: %{model: "openrouter/deepseek/deepseek-v4-pro"},
        failed_attempt_number: 1,
        attempt_number: 2,
        failure_class: "usage_limit",
        failure_reason: "Codex error: The usage limit has been reached",
        turn_number: 1,
        exhausted: false
      }
    }

    assert {:ok, ledger} = RunLedger.record_model_routing_decision(ledger, routing, source: %{event: "test"})

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["agent"]["model_routing"]["fallback"]["failure_class"] == "usage_limit"
    assert manifest["agent"]["model_routing"]["fallback"]["next_candidate"]["model"] == "openrouter/deepseek/deepseek-v4-pro"

    checkpoint = decode_json!(Path.join(ledger.run_dir, "checkpoints/0001-model_routing_decision.json"))
    assert checkpoint["payload"]["fallback"]["failed_candidate"]["model"] == "openai-codex/gpt-5.4-mini"
    assert checkpoint["payload"]["fallback"]["exhausted"] == false
  end

  test "create_run records the run-start base commit and branch for git workspaces" do
    workspace_root = tmp_dir("ledger-git-base")
    workspace = Path.join(workspace_root, "MT-401")
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "--quiet", "--initial-branch", "main"])
    git!(workspace, ["config", "user.email", "test@example.org"])
    git!(workspace, ["config", "user.name", "Rondo Test"])
    File.write!(Path.join(workspace, "tracked.txt"), "original\n")
    git!(workspace, ["add", "tracked.txt"])
    git!(workspace, ["commit", "--quiet", "-m", "initial"])
    base_commit = git!(workspace, ["rev-parse", "HEAD"])

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(), workspace_root: workspace_root, now: @now, random_suffix: "ba5e1234")

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["repo"]["workspace"] == Path.expand(workspace)
    assert manifest["repo"]["base_commit"] == base_commit
    assert manifest["repo"]["base_branch"] == "main"
  end

  test "create_run records nil base commit when the workspace is missing or git fails" do
    workspace_root = tmp_dir("ledger-no-git-base")

    assert {:ok, missing_ledger} =
             RunLedger.create_run(issue_fixture(), workspace_root: workspace_root, now: @now, random_suffix: "00000001")

    manifest = decode_json!(missing_ledger.manifest_path)
    assert manifest["repo"]["base_commit"] == nil
    assert manifest["repo"]["base_branch"] == nil

    workspace = Path.join(workspace_root, "MT-401")
    File.mkdir_p!(workspace)
    failing_runner = fn _args, ^workspace -> {"fatal: not a git repository\n", 128} end

    assert {:ok, failed_ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "00000002",
               git_runner: failing_runner
             )

    manifest = decode_json!(failed_ledger.manifest_path)
    assert manifest["repo"]["base_commit"] == nil
    assert manifest["repo"]["base_branch"] == nil
  end

  test "create_run accepts string-keyed issue maps" do
    workspace_root = tmp_dir("ledger-string-map")

    issue = %{
      "id" => "issue-string",
      "identifier" => "MT-STRING",
      "title" => "String issue",
      "description" => "Loaded from JSON",
      "state" => "In Progress",
      "url" => "https://example.org/issues/MT-STRING",
      "labels" => ["json"],
      "priority" => 2
    }

    assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root, now: @now, random_suffix: "12345678")
    assert ledger.run_id == "MT-STRING-20260510T153012Z-12345678"

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["issue"]["id"] == "issue-string"
    assert manifest["issue"]["identifier"] == "MT-STRING"
    assert manifest["issue"]["title"] == "String issue"
    assert manifest["issue"]["description"] == "Loaded from JSON"
    assert manifest["issue"]["state"] == "In Progress"
    assert manifest["issue"]["url"] == "https://example.org/issues/MT-STRING"
    assert manifest["issue"]["labels"] == ["json"]
    assert manifest["issue"]["priority"] == 2
  end

  test "create_run records source contract metadata when provided" do
    workspace_root = tmp_dir("ledger-source-contract")

    source_contract = %{
      schema: "rondo-execution-request-v1",
      slice_id: "slice-123",
      path: "/tmp/request.json",
      sha256: String.duplicate("a", 64),
      parent_contract: %{"id" => "plan-1", "source" => "beislid"},
      repo: %{"base_ref" => "main"},
      allowed_actions: %{"run_mode" => "supervised-auto"},
      process_provider: %{"name" => "pi"},
      memory_provider: %{"name" => "memento"},
      output_expectations: %{"final_report" => true}
    }

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "5eedc0de",
               source_contract: source_contract
             )

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["source_contract"]["schema"] == "rondo-execution-request-v1"
    assert manifest["source_contract"]["slice_id"] == "slice-123"
    assert manifest["source_contract"]["path"] == "/tmp/request.json"
    assert manifest["source_contract"]["sha256"] == String.duplicate("a", 64)
    assert manifest["source_contract"]["parent_contract"] == %{"id" => "plan-1", "source" => "beislid"}
    assert manifest["source_contract"]["repo"] == %{"base_ref" => "main"}
    assert manifest["source_contract"]["allowed_actions"] == %{"run_mode" => "supervised-auto"}
    assert manifest["source_contract"]["process_provider"] == %{"name" => "pi"}
    assert manifest["source_contract"]["memory_provider"] == %{"name" => "memento"}
    assert manifest["source_contract"]["output_expectations"] == %{"final_report" => true}

    assert {:ok, invalid_source_ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "badc0ffe",
               source_contract: "invalid"
             )

    invalid_source_manifest = decode_json!(invalid_source_ledger.manifest_path)
    refute Map.has_key?(invalid_source_manifest, "source_contract")
  end

  test "create_run generates unique run IDs across attempts" do
    workspace_root = tmp_dir("ledger-unique")
    issue = issue_fixture()

    assert {:ok, first} = RunLedger.create_run(issue, workspace_root: workspace_root)
    assert {:ok, second} = RunLedger.create_run(issue, workspace_root: workspace_root)

    assert first.run_id != second.run_id
    assert File.dir?(first.run_dir)
    assert File.dir?(second.run_dir)
    assert {:ok, _ledger} = RunLedger.write_checkpoint(first, :default_opts, %{})
  end

  test "load_manifest returns safe errors for missing or corrupted files" do
    root = tmp_dir("ledger-load")

    assert {:error, :missing} = RunLedger.load_manifest(Path.join(root, "missing/manifest.json"))

    invalid_json_path = Path.join(root, "invalid/manifest.json")
    File.mkdir_p!(Path.dirname(invalid_json_path))
    File.write!(invalid_json_path, "not json")
    assert {:error, :invalid_json} = RunLedger.load_manifest(invalid_json_path)

    invalid_manifest_path = Path.join(root, "malformed/manifest.json")
    File.mkdir_p!(Path.dirname(invalid_manifest_path))
    File.write!(invalid_manifest_path, Jason.encode!(%{"schema_version" => 1}))
    assert {:error, :invalid_manifest} = RunLedger.load_manifest(invalid_manifest_path)
  end

  test "complete_run updates terminal status and archive links" do
    workspace_root = tmp_dir("ledger-complete")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "facefeed"
             )

    assert {:ok, ledger} = RunLedger.complete_run(ledger, :terminated, %{reason: "operator"}, timestamp: @now)
    assert {:ok, ledger} = RunLedger.link_archive(ledger, nil)
    assert {:ok, ledger} = RunLedger.link_archive(ledger, "/tmp/rondo/archive.json")
    assert {:ok, ledger} = RunLedger.link_archive(ledger, "/tmp/rondo/archive.json")

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["status"] == "terminated"
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "terminated"))
    assert Enum.count(manifest["artifacts"], &(&1["kind"] == "archive")) == 1

    assert {:ok, ledger} =
             RunLedger.link_artifacts(ledger, [
               %{kind: "gate_results", path: "artifacts/gates/results.json"},
               %{"kind" => "gate_stdout", "path" => "artifacts/gates/unit-stdout.log"},
               %{kind: "invalid"},
               %{"path" => "missing-kind"}
             ])

    artifact_manifest = decode_json!(ledger.manifest_path)
    assert Enum.any?(artifact_manifest["artifacts"], &(&1["kind"] == "gate_results"))
    assert Enum.any?(artifact_manifest["artifacts"], &(&1["kind"] == "gate_stdout"))

    assert {:ok, ledger} = RunLedger.link_artifacts(ledger, [%{kind: "invalid"}])
    assert ledger.manifest == artifact_manifest

    assert {:ok, failed_ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "badc0de"
             )

    assert {:ok, failed_ledger} = RunLedger.complete_run(failed_ledger, :failed, %{reason: "boom"}, timestamp: @now)
    failed_manifest = decode_json!(failed_ledger.manifest_path)
    assert failed_manifest["status"] == "failed"
    assert Enum.any?(failed_manifest["checkpoints"], &(&1["kind"] == "failed"))
  end

  test "complete_run(:handed_off) records handoff status and checkpoint" do
    workspace_root = tmp_dir("ledger-handoff")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "cafe02"
             )

    assert {:ok, ledger} =
             RunLedger.complete_run(
               ledger,
               :handed_off,
               %{
                 exit_reason: "handed_off",
                 non_active_state: "In Review",
                 session_id: "sess-1",
                 turn_count: 3
               },
               timestamp: @now
             )

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["status"] == "handed_off"
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "handed_off"))
  end

  test "pause_run writes interrupt checkpoint and paused manifest state" do
    workspace_root = tmp_dir("ledger-pause")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "cafed00d"
             )

    interrupt = %{
      "reason" => "repeated_gate_failure",
      "state" => "paused",
      "question" => "Configured gates failed repeatedly. How should Rondo proceed?",
      "options" => [%{"id" => "resume"}],
      "gate" => %{"status" => "fail"},
      "resume" => %{"run_id" => ledger.run_id, "session_id" => "session-pause"}
    }

    assert {:ok, ledger} = RunLedger.pause_run(ledger, interrupt, timestamp: @now)

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["status"] == "paused"
    assert manifest["interrupt"] == interrupt
    assert manifest["timestamps"]["paused_at"] == "2026-05-10T15:30:12Z"
    assert manifest["timestamps"]["finished_at"] == nil
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "interrupt_created"))

    checkpoint_index = Enum.find(manifest["checkpoints"], &(&1["kind"] == "interrupt_created"))
    checkpoint = decode_json!(Path.join(ledger.run_dir, checkpoint_index["path"]))
    assert checkpoint["payload"] == interrupt
    assert checkpoint["source"] == %{"interrupt" => "human"}
  end

  test "checkpoint_kind_for_agent_update maps Claude and MCP lifecycle events" do
    assert RunLedger.checkpoint_kind_for_agent_update(%{raw: %{"method" => "turn/started"}}) == "turn_started"
    assert RunLedger.checkpoint_kind_for_agent_update(%{raw: %{"method" => "turn/failed"}}) == "turn_failed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{raw: %{"method" => "turn/cancelled"}}) == "turn_cancelled"
    assert RunLedger.checkpoint_kind_for_agent_update(%{raw: %{"method" => "turn/diff/updated"}}) == "edit_batch"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"raw" => %{"method" => "turn/completed"}}) == "turn_completed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{raw: %{method: "turn/completed"}}) == "turn_completed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "claude_starting"}) == "workspace_ready"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "session_started"}) == "turn_started"
    assert RunLedger.checkpoint_kind_for_agent_update(%{event: :session_started}) == "turn_started"
    assert RunLedger.checkpoint_kind_for_agent_update(%{event: :result}) == "turn_completed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "result"}) == "turn_completed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{event: :invocation_completed}) == "turn_completed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "invocation_completed"}) == "turn_completed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{event: :invocation_failed}) == "turn_failed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "invocation_failed"}) == "turn_failed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "gates_completed"}) == "gates_completed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "gates_reused"}) == "gates_reused"
    assert RunLedger.checkpoint_kind_for_agent_update(%{event: :tracker_update_detected}) == "tracker_update_detected"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "tracker_update_detected"}) == "tracker_update_detected"
    assert RunLedger.checkpoint_kind_for_agent_update(%{event: :model_routing_decision}) == "model_routing_decision"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "model_routing_decision"}) == "model_routing_decision"
    assert RunLedger.checkpoint_kind_for_agent_update(%{raw: %{"method" => "run_decision"}}) == "run_decision"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "run_decision"}) == "run_decision"
    assert RunLedger.checkpoint_kind_for_agent_update(%{event: :run_decision}) == "run_decision"
    assert RunLedger.checkpoint_kind_for_agent_update(%{event: :unknown}) == nil
  end

  test "agent update checkpoint helpers accept string-keyed maps" do
    update = %{
      "event" => "result",
      "adapter" => "fake",
      "run_ref" => %{"adapter" => "fake", "provider_ref" => "run-1", "provider_ref_kind" => "thread_id", "resumable?" => true},
      "session_id" => "session-json",
      "usage" => %{"input_tokens" => 11},
      "capabilities" => %{"resume" => "thread_id"},
      "final_report" => "done",
      "raw" => %{"method" => "turn/completed", "result" => "private result", "turn_number" => 4, "retry_attempt" => 1}
    }

    payload = RunLedger.checkpoint_payload_for_agent_update(update)

    assert payload == %{
             event: "result",
             adapter: "fake",
             run_ref: %{"adapter" => "fake", "provider_ref" => "run-1", "provider_ref_kind" => "thread_id", "resumable?" => true},
             session_id: "session-json",
             usage: %{"input_tokens" => 11},
             capabilities: %{"resume" => "thread_id"},
             final_report: "done",
             turn_number: 4,
             retry_attempt: 1,
             raw: %{"method" => "turn/completed", "result" => "[REDACTED]", "turn_number" => 4, "retry_attempt" => 1}
           }

    assert RunLedger.checkpoint_source_for_agent_update(%{"event" => "run_decision", "raw" => %{"method" => "run_decision"}}) == %{
             adapter: "claude_code",
             event: "run_decision"
           }

    assert RunLedger.checkpoint_source_for_agent_update(update) == %{
             adapter: "fake",
             event: "turn/completed"
           }

    assert RunLedger.agent_metadata_for_agent_update(update) == %{
             "adapter" => "fake",
             "run_ref" => %{"adapter" => "fake", "provider_ref" => "run-1", "provider_ref_kind" => "thread_id", "resumable?" => true},
             "session_id" => "session-json",
             "usage" => %{"input_tokens" => 11},
             "capabilities" => %{"resume" => "thread_id"},
             "final_report" => "done"
           }

    assert RunLedger.agent_metadata_for_agent_update(%{adapter: "atom-key-adapter"}) == %{"adapter" => "atom-key-adapter"}
  end

  test "record_attempt_chain persists escalation chain checkpoints" do
    workspace_root = tmp_dir("ledger-attempt-chain")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "chain001"
             )

    chain = [
      %{
        run_id: "run-1",
        tier: "light",
        reason: :initial,
        status: :failed,
        failure_classification: nil,
        gate_summary: %{"status" => "fail"},
        final_report_status: "missing",
        token_spend: %{input_tokens: 5, output_tokens: 3, total_tokens: 8},
        started_at: "2026-05-10T15:30:00Z",
        finished_at: "2026-05-10T15:31:00Z",
        run_dir: "/tmp/run-1"
      }
    ]

    assert {:ok, ledger} = RunLedger.record_attempt_chain(ledger, chain)

    manifest = decode_json!(ledger.manifest_path)

    assert [attempt] = manifest["escalation"]["attempt_chain"]
    assert attempt["run_id"] == "run-1"
    assert attempt["tier"] == "light"
    assert attempt["reason"] == "initial"
    assert attempt["status"] == "failed"
    assert attempt["gate_summary"] == %{"status" => "fail"}
    assert attempt["final_report_status"] == "missing"
    assert attempt["token_spend"] == "[REDACTED]"
    assert attempt["started_at"] == "2026-05-10T15:30:00Z"
    assert attempt["finished_at"] == "2026-05-10T15:31:00Z"
    assert attempt["run_dir"] == "/tmp/run-1"

    checkpoint_index = Enum.find(manifest["checkpoints"], &(&1["kind"] == "escalation_chain"))
    assert checkpoint_index

    checkpoint = decode_json!(Path.join(ledger.run_dir, checkpoint_index["path"]))
    assert [checkpoint_attempt] = checkpoint["payload"]["attempt_chain"]
    assert checkpoint_attempt["run_id"] == "run-1"
    assert checkpoint_attempt["token_spend"] == "[REDACTED]"
  end

  test "records Beislið action policy decisions as checkpoints" do
    workspace_root = tmp_dir("ledger-action-policy")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "dec1510n",
               action_policy_run_mode: "unattended-auto"
             )

    envelope = %{
      "decision" => "deny",
      "mode" => "unattended-auto",
      "action" => "git.push",
      "classes" => ["git-remote"],
      "matched_rules" => [%{"type" => "class", "decision" => "deny"}],
      "sandbox_status" => %{"baseline" => "separate-worktree"},
      "requires_human" => false,
      "log_level" => "error",
      "reason" => "classes=git-remote",
      "remediation" => ["Do not run this action"]
    }

    assert {:ok, ledger} = RunLedger.record_action_policy_decision(ledger, envelope)
    assert {:ok, ledger} = RunLedger.record_action_policy_decision(ledger, envelope, side_effect_status: "blocked")

    manifest = decode_json!(ledger.manifest_path)

    assert manifest["action_policy"] == %{
             "provider" => "beislid",
             "run_mode" => "unattended-auto",
             "policy_file" => nil,
             "policy_file_source" => nil,
             "policy_file_sha256" => nil
           }

    assert [_, %{"kind" => "action_policy_decision", "path" => checkpoint_path}] = manifest["checkpoints"]

    checkpoint = decode_json!(Path.join(ledger.run_dir, checkpoint_path))
    assert checkpoint["payload"]["decision"] == "deny"
    assert checkpoint["payload"]["side_effect_status"] == "blocked"
    assert checkpoint["source"] == %{"policy" => "beislid_action_policy"}
  end

  test "freezes the policy file into the run dir and records frozen path, source, and content hash" do
    workspace_root = tmp_dir("ledger-policy-file")
    policy_file = Path.join(tmp_dir("ledger-policy-file-src"), "policy.json")
    File.mkdir_p!(Path.dirname(policy_file))
    policy_contents = ~s({"modes": {"unattended-auto": {}}})
    File.write!(policy_file, policy_contents)

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "p0l1cyf1",
               action_policy_run_mode: "unattended-auto",
               action_policy_policy_file: policy_file
             )

    expected_sha256 = :crypto.hash(:sha256, policy_contents) |> Base.encode16(case: :lower)
    frozen_path = Path.join(ledger.run_dir, "artifacts/action-policy.json")

    assert ledger.policy_file == frozen_path
    assert File.read!(frozen_path) == policy_contents

    manifest = decode_json!(ledger.manifest_path)

    assert manifest["action_policy"] == %{
             "provider" => "beislid",
             "run_mode" => "unattended-auto",
             "policy_file" => frozen_path,
             "policy_file_source" => Path.expand(policy_file),
             "policy_file_sha256" => expected_sha256
           }

    # Mutating the source after ledger creation must not affect the frozen
    # artifact the run is governed by.
    File.write!(policy_file, ~s({"modes": {"unattended-auto": {"actions": {"git.push": "allow"}}}}))
    assert File.read!(frozen_path) == policy_contents
    assert :crypto.hash(:sha256, File.read!(frozen_path)) |> Base.encode16(case: :lower) == expected_sha256
  end

  test "fails ledger creation closed when the policy file cannot be frozen" do
    workspace_root = tmp_dir("ledger-policy-file-vanished")
    vanished_policy_file = Path.join(tmp_dir("ledger-policy-file-gone"), "policy.json")

    assert {:error, {:policy_file_freeze_failed, source, :enoent}} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "g0nef1le",
               action_policy_policy_file: vanished_policy_file
             )

    assert source == Path.expand(vanished_policy_file)
  end

  test "update_agent_metadata records adapter run ref capabilities and final report in manifest" do
    workspace_root = tmp_dir("ledger-agent-metadata")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "ca11ab1e"
             )

    metadata = %{
      "adapter" => "fake",
      "run_ref" => %{adapter: "fake", provider_ref: "run-1", provider_ref_kind: "thread_id", resumable?: true},
      "capabilities" => %{resume: :thread_id, usage: :final},
      "final_report" => "finished",
      "diff_source" => :fallback_git_diff
    }

    assert {:ok, ledger} = RunLedger.update_agent_metadata(ledger, metadata)

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["agent"]["adapter"] == "fake"
    assert manifest["agent"]["run_ref"] == %{"adapter" => "fake", "provider_ref" => "run-1", "provider_ref_kind" => "thread_id", "resumable?" => true}
    assert manifest["agent"]["capabilities"] == %{"resume" => "thread_id", "usage" => "final"}
    assert manifest["agent"]["final_report"] == "finished"
    assert manifest["agent"]["diff_source"] == "fallback_git_diff"

    bad_agent_ledger = %{ledger | manifest: Map.put(ledger.manifest, "agent", "not-a-map")}
    File.write!(bad_agent_ledger.manifest_path, Jason.encode!(bad_agent_ledger.manifest))
    assert {:ok, bad_agent_ledger} = RunLedger.update_agent_metadata(bad_agent_ledger, %{"adapter" => "fake"})
    assert bad_agent_ledger.manifest["agent"] == %{"adapter" => "fake"}

    assert RunLedger.agent_metadata_for_agent_update(%{raw: "not-a-map"}) == %{}
  end

  test "update_agent_metadata preserves model routing written by another ledger copy" do
    workspace_root = tmp_dir("ledger-agent-metadata-stale")
    issue = issue_fixture()

    assert {:ok, stale_ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "57a1e000"
             )

    assert {:ok, _current_ledger} =
             RunLedger.update_agent_metadata(stale_ledger, %{
               "model_routing" => %{status: :honored, resolved: %{adapter: :pi, model: "openai-codex/gpt-5.4-mini"}}
             })

    assert {:ok, updated_from_stale} =
             RunLedger.update_agent_metadata(stale_ledger, %{
               "session_id" => "session-after-routing",
               "run_ref" => %{adapter: "pi", provider_ref: "session-after-routing", provider_ref_kind: "session_id", resumable?: true}
             })

    manifest = decode_json!(updated_from_stale.manifest_path)
    assert manifest["agent"]["session_id"] == "session-after-routing"

    assert manifest["agent"]["model_routing"] == %{
             "status" => "honored",
             "resolved" => %{"adapter" => "pi", "model" => "openai-codex/gpt-5.4-mini"}
           }
  end

  test "record_model_routing_decision writes a checkpoint and agent metadata" do
    workspace_root = tmp_dir("ledger-model-routing-decision")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "57a1e002"
             )

    routing = %{
      status: :honored,
      mode: :prefer,
      requested_tier: "heavy",
      candidates: [%{adapter: "pi", model: "heavy-model"}],
      resolved: %{adapter: "pi", model: "heavy-model"},
      reason: "resolved turn/implementation tier heavy to pi/heavy-model",
      context: %{stage: "turn", phase: "implementation"}
    }

    assert {:ok, ledger} =
             RunLedger.record_model_routing_decision(ledger, routing)

    manifest = decode_json!(ledger.manifest_path)

    assert manifest["agent"]["model_routing"] == %{
             "status" => "honored",
             "mode" => "prefer",
             "requested_tier" => "heavy",
             "candidates" => [%{"adapter" => "pi", "model" => "heavy-model"}],
             "resolved" => %{"adapter" => "pi", "model" => "heavy-model"},
             "reason" => "resolved turn/implementation tier heavy to pi/heavy-model",
             "context" => %{"stage" => "turn", "phase" => "implementation"}
           }

    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "model_routing_decision"))
  end

  test "record_model_routing_decision replaces a non-map agent manifest entry" do
    workspace_root = tmp_dir("ledger-model-routing-decision-agent-string")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "57a1e003"
             )

    source = %{provider: "fake", stage: "turn", turn_number: 3}
    routing = %{status: :blocked, resolved: nil, reason: "blocked", context: %{stage: "turn"}}
    corrupted_ledger = %{ledger | manifest: Map.put(ledger.manifest, "agent", "legacy-agent")}

    assert {:ok, updated_ledger} =
             RunLedger.record_model_routing_decision(corrupted_ledger, routing, source: source)

    manifest = decode_json!(updated_ledger.manifest_path)

    assert manifest["agent"]["model_routing"] == %{
             "status" => "blocked",
             "resolved" => nil,
             "reason" => "blocked",
             "context" => %{"stage" => "turn"}
           }
  end

  test "record_model_routing_decision rejects non-map routing input" do
    workspace_root = tmp_dir("ledger-model-routing-decision-invalid")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "57a1e004"
             )

    assert {:error, {:invalid_model_routing, nil}} =
             RunLedger.record_model_routing_decision(ledger, nil, source: %{provider: "fake"})
  end

  test "update_agent_metadata falls back to in-memory manifest when on-disk manifest is unreadable" do
    workspace_root = tmp_dir("ledger-agent-metadata-unreadable")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "57a1e001"
             )

    File.write!(ledger.manifest_path, "not json")

    assert {:ok, updated_ledger} = RunLedger.update_agent_metadata(ledger, %{"adapter" => "pi"})
    assert updated_ledger.manifest["agent"]["adapter"] == "pi"

    manifest = decode_json!(updated_ledger.manifest_path)
    assert manifest["agent"]["adapter"] == "pi"
  end

  test "load_manifest accepts either run directory or manifest path" do
    workspace_root = tmp_dir("ledger-load-dir")
    assert {:ok, ledger} = RunLedger.create_run(issue_fixture(), workspace_root: workspace_root)

    assert {:ok, by_file} = RunLedger.load_manifest(ledger.manifest_path)
    assert {:ok, by_dir} = RunLedger.load_manifest(ledger.run_dir)
    assert by_file == by_dir
  end

  test "record_model_routing_decision preserves routing profile" do
    workspace_root = tmp_dir("ledger-model-routing-profile")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "57a1e005"
             )

    routing = %{
      status: :honored,
      mode: :prefer,
      profile: "bulk_implementation",
      requested_tier: "light",
      candidates: [%{adapter: "pi", model: "openrouter/deepseek/deepseek-chat"}],
      resolved: %{adapter: "pi", model: "openrouter/deepseek/deepseek-chat"},
      reason: "resolved tier light to pi/openrouter/deepseek/deepseek-chat"
    }

    assert {:ok, ledger} = RunLedger.record_model_routing_decision(ledger, routing)
    manifest = decode_json!(ledger.manifest_path)

    assert manifest["agent"]["model_routing"]["profile"] == "bulk_implementation"
  end

  test "edge-case inputs remain safe and serializable" do
    workspace_root = tmp_dir("ledger-edges")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "0ddba11"
             )

    assert {:ok, ledger} =
             RunLedger.write_checkpoint(
               ledger,
               {:custom, :kind},
               %{ok: true, at: @now, tuple: {:x}, list: [@now], long: String.duplicate("z", 5_000)},
               timestamp: "2026-05-10T15:30:12Z",
               source: %{adapter: "test", input_tokens: 1, output_tokens: 2, total_tokens: 3}
             )

    checkpoint = decode_json!(Path.join(ledger.run_dir, "checkpoints/0001-__custom___kind_.json"))
    assert checkpoint["kind"] =~ "custom"
    assert checkpoint["timestamp"] == "2026-05-10T15:30:12Z"
    assert checkpoint["payload"]["at"] == DateTime.to_iso8601(@now)
    assert checkpoint["payload"]["tuple"] =~ "x"
    assert checkpoint["payload"]["list"] == [DateTime.to_iso8601(@now)]
    assert checkpoint["payload"]["long"] =~ "truncated"
    assert checkpoint["source"] == %{"adapter" => "test", "input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3}

    assert :ok =
             RunLedger.append_agent_event(
               ledger,
               %{
                 event: nil,
                 timestamp: :not_a_datetime,
                 raw: %{
                   "adapter" => "claude_code",
                   "id" => "event-1",
                   "kind" => "event",
                   "method" => "item/commandExecution/outputDelta",
                   "model" => "claude",
                   "name" => "Bash",
                   "role" => "assistant",
                   "session_id" => "claude-session-1",
                   "subtype" => "success",
                   "timestamp" => "2026-05-10T15:30:12Z",
                   "tool" => "bash",
                   "type" => "result",
                   "status" => "completed",
                   "when" => @now,
                   "tuple" => {:not, "json"},
                   "notes" => ["private list text", %{"status" => "kept"}],
                   "input_tokens" => 1,
                   "output_tokens" => 2,
                   "total_tokens" => 3,
                   "cache_creation_input_tokens" => 4,
                   "cache_read_input_tokens" => 5,
                   "prompt" => "do secret work",
                   "old_string" => "private source",
                   "new_string" => "private source changed",
                   "delta" => "private assistant stream",
                   "summaryText" => "private reasoning summary",
                   "textDelta" => "private text stream",
                   "outputDelta" => "private command output",
                   "output" => "private bare output",
                   "stdout" => "private stdout",
                   "stderr" => "private stderr",
                   "result" => "private final result"
                 }
               },
               timestamp: :not_a_datetime
             )

    artifact_path = Path.join(ledger.run_dir, "artifacts/agent-events.ndjson")
    [line] = artifact_path |> File.read!() |> String.split("\n", trim: true)
    decoded = Jason.decode!(line)
    assert decoded["event"] == "unknown"
    assert decoded["raw"]["adapter"] == "claude_code"
    assert decoded["raw"]["id"] == "event-1"
    assert decoded["raw"]["kind"] == "event"
    assert decoded["raw"]["method"] == "item/commandExecution/outputDelta"
    assert decoded["raw"]["model"] == "claude"
    assert decoded["raw"]["name"] == "Bash"
    assert decoded["raw"]["role"] == "assistant"
    assert decoded["raw"]["session_id"] == "claude-session-1"
    assert decoded["raw"]["subtype"] == "success"
    assert decoded["raw"]["timestamp"] == "2026-05-10T15:30:12Z"
    assert decoded["raw"]["tool"] == "bash"
    assert decoded["raw"]["type"] == "result"
    assert decoded["raw"]["status"] == "completed"
    assert decoded["raw"]["when"] == DateTime.to_iso8601(@now)
    assert decoded["raw"]["tuple"] =~ "not"
    assert decoded["raw"]["notes"] == ["[REDACTED]", %{"status" => "kept"}]
    assert decoded["raw"]["input_tokens"] == 1
    assert decoded["raw"]["output_tokens"] == 2
    assert decoded["raw"]["total_tokens"] == 3
    assert decoded["raw"]["cache_creation_input_tokens"] == 4
    assert decoded["raw"]["cache_read_input_tokens"] == 5

    assert :ok = RunLedger.append_agent_event(ledger, %{event: :assistant, raw: [:tool, "safe"]}, timestamp: @now)
    [_first, second_line] = artifact_path |> File.read!() |> String.split("\n", trim: true)
    assert Jason.decode!(second_line)["raw"] == ["tool", "[REDACTED]"]
    assert decoded["raw"]["prompt"] == "[REDACTED]"
    assert decoded["raw"]["old_string"] == "[REDACTED]"
    assert decoded["raw"]["new_string"] == "[REDACTED]"
    assert decoded["raw"]["delta"] == "[REDACTED]"
    assert decoded["raw"]["summaryText"] == "[REDACTED]"
    assert decoded["raw"]["textDelta"] == "[REDACTED]"
    assert decoded["raw"]["outputDelta"] == "[REDACTED]"
    assert decoded["raw"]["output"] == "[REDACTED]"
    assert decoded["raw"]["stdout"] == "[REDACTED]"
    assert decoded["raw"]["stderr"] == "[REDACTED]"
    assert decoded["raw"]["result"] == "[REDACTED]"
    refute line =~ "do secret work"
    refute line =~ "private source"
    refute line =~ "private list text"
    refute line =~ "private assistant stream"
    refute line =~ "private reasoning summary"
    refute line =~ "private text stream"
    refute line =~ "private command output"
    refute line =~ "private bare output"
    refute line =~ "private stdout"
    refute line =~ "private stderr"
    refute line =~ "private final result"

    bad_artifacts_ledger = %{ledger | manifest: Map.put(ledger.manifest, "artifacts", "not-a-list")}
    assert {:ok, _ledger} = RunLedger.link_archive(bad_artifacts_ledger, "/tmp/archive.json")

    unreadable_path = Path.join(workspace_root, "unreadable/manifest.json")
    File.mkdir_p!(unreadable_path)
    assert {:error, :eisdir} = RunLedger.load_manifest(unreadable_path)
  end

  test "append_agent_event writes sanitized capped NDJSON artifacts" do
    workspace_root = tmp_dir("ledger-events")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "deadbeef"
             )

    event = %{
      event: :assistant,
      session_id: "session-1",
      timestamp: @now,
      usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
      raw: %{
        "api_key" => "super-secret-token",
        "message" => %{"content" => "prompt and file contents"},
        "params" => %{"diff" => "sensitive diff", "turn" => %{"status" => "completed"}},
        "result" => "private result text",
        "safe" => "redacted by default",
        "turn_number" => 4,
        "retry_attempt" => 1
      }
    }

    assert :ok = RunLedger.append_agent_event(ledger, event, timestamp: @now)

    artifact_path = Path.join(ledger.run_dir, "artifacts/agent-events.ndjson")
    assert [line] = artifact_path |> File.read!() |> String.split("\n", trim: true)
    decoded = Jason.decode!(line)

    assert decoded["event"] == "assistant"
    assert decoded["session_id"] == "session-1"
    assert decoded["usage"] == %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
    assert decoded["raw"]["api_key"] == "[REDACTED]"
    assert decoded["raw"]["message"] == "[REDACTED]"
    assert decoded["raw"]["params"]["diff"] == "[REDACTED]"
    assert decoded["raw"]["params"]["turn"]["status"] == "completed"
    assert decoded["raw"]["result"] == "[REDACTED]"
    assert decoded["raw"]["safe"] == "[REDACTED]"
    assert decoded["raw"]["turn_number"] == 4
    assert decoded["raw"]["retry_attempt"] == 1
    refute line =~ "super-secret-token"
    refute line =~ "prompt and file contents"
    refute line =~ "sensitive diff"
    refute line =~ "private result text"
    refute line =~ "redacted by default"
  end

  test "append_agent_event writes rondo.events/v0 JSONL lines with adapter and run_ref" do
    workspace_root = tmp_dir("ledger-events-schema")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "0eef0eef"
             )

    events = [
      %{
        event: :invocation_completed,
        adapter: "claude_code",
        run_ref: %{adapter: "claude_code", provider_ref: "session-9", provider_ref_kind: :session_id, resumable?: true},
        session_id: "session-9",
        usage: %{input_tokens: 1},
        raw: %{"type" => "result"}
      },
      %{event: :claude_starting, raw: %{}},
      %{"event" => "gates_completed", "adapter" => "claude_code", "raw" => %{"status" => "pass"}}
    ]

    Enum.each(events, fn event ->
      assert :ok = RunLedger.append_agent_event(ledger, event, timestamp: @now)
    end)

    artifact_path = Path.join(ledger.run_dir, "artifacts/agent-events.ndjson")
    lines = artifact_path |> File.read!() |> String.split("\n", trim: true)
    decoded_lines = Enum.map(lines, &Jason.decode!/1)

    assert length(decoded_lines) == 3
    assert Enum.all?(decoded_lines, &(&1["schema"] == RunLedger.events_schema()))
    assert RunLedger.events_schema() == "rondo.events/v0"

    [first, second, third] = decoded_lines
    assert first["event"] == "invocation_completed"
    assert first["adapter"] == "claude_code"
    assert first["run_ref"] == %{"adapter" => "claude_code", "provider_ref" => "session-9", "provider_ref_kind" => "session_id", "resumable?" => true}
    assert first["session_id"] == "session-9"

    assert second["event"] == "claude_starting"
    assert second["adapter"] == nil
    assert second["run_ref"] == nil

    assert third["event"] == "gates_completed"
    assert third["adapter"] == "claude_code"

    # every line shares the same stable key set
    assert Enum.all?(decoded_lines, fn line ->
             Map.keys(line) |> Enum.sort() == ["adapter", "event", "raw", "run_ref", "schema", "session_id", "timestamp", "usage"]
           end)
  end

  test "persisted strings are redacted with the secret deny-list before writing" do
    workspace_root = tmp_dir("ledger-redaction")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "5ec5ec00"
             )

    event = %{
      event: :warning,
      raw: %{"status" => "used key sk-ant-api03-abcdef1234567890abcdef and Bearer abcdefghijklmnop1234"},
      usage: %{"note" => "ghp_abcdefghijklmnopqrst123456"}
    }

    assert :ok = RunLedger.append_agent_event(ledger, event, timestamp: @now)

    line = ledger.run_dir |> Path.join("artifacts/agent-events.ndjson") |> File.read!()
    refute line =~ "sk-ant-api03"
    refute line =~ "ghp_abcdefghijklmnopqrst123456"
    assert line =~ "[REDACTED]"

    assert {:ok, ledger} = RunLedger.write_checkpoint(ledger, :dispatch, %{note: "AKIAIOSFODNN7EXAMPLE in payload"}, timestamp: @now)
    checkpoint = decode_json!(Path.join(ledger.run_dir, "checkpoints/0001-dispatch.json"))
    assert checkpoint["payload"]["note"] == "[REDACTED] in payload"
  end

  test "concurrent checkpoint writes from stale ledger copies produce unique monotonic sequences" do
    workspace_root = tmp_dir("ledger-concurrent")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "c0nc0001"
             )

    stale = ledger

    tasks =
      for i <- 1..8 do
        Task.async(fn ->
          kind = if rem(i, 2) == 0, do: :orchestrator_event, else: :worker_event
          RunLedger.write_checkpoint(stale, kind, %{n: i}, timestamp: @now)
        end)
      end

    results = Enum.map(tasks, &Task.await/1)

    assert Enum.all?(results, fn
             {:ok, _} -> true
             _ -> false
           end)

    manifest = decode_json!(ledger.manifest_path)
    seqs = Enum.map(manifest["checkpoints"], & &1["seq"])
    assert length(seqs) == 8
    assert seqs == Enum.uniq(seqs)
    assert seqs == Enum.sort(seqs)

    index_files = manifest["checkpoints"] |> Enum.map(&Path.basename(&1["path"])) |> Enum.sort()

    disk_files =
      ledger.run_dir
      |> Path.join("checkpoints")
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort()

    assert index_files == disk_files
  end

  test "regression: action_policy_decision and spawned do not collide on stale next_seq" do
    workspace_root = tmp_dir("ledger-dogfood-dup")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "d0gf00d"
             )

    envelope = %{
      "decision" => "deny",
      "mode" => "unattended-auto",
      "action" => "git.push",
      "classes" => ["git-remote"],
      "matched_rules" => [%{"type" => "class", "decision" => "deny"}],
      "sandbox_status" => %{"baseline" => "separate-worktree"},
      "requires_human" => false,
      "log_level" => "error",
      "reason" => "classes=git-remote",
      "remediation" => ["Do not run this action"]
    }

    [spawned_task, policy_task] =
      [
        Task.async(fn -> RunLedger.write_checkpoint(ledger, :spawned, %{pid: "pid-1"}, timestamp: @now) end),
        Task.async(fn -> RunLedger.record_action_policy_decision(ledger, envelope) end)
      ]

    results = Enum.map([spawned_task, policy_task], &Task.await/1)

    assert Enum.all?(results, fn
             {:ok, _} -> true
             _ -> false
           end)

    manifest = decode_json!(ledger.manifest_path)

    seqs_and_kinds =
      manifest["checkpoints"]
      |> Enum.map(&{&1["seq"], &1["kind"]})
      |> Enum.sort()

    seqs = Enum.map(seqs_and_kinds, &elem(&1, 0))
    assert length(seqs) == 2
    assert seqs == Enum.uniq(seqs)
    assert Enum.sort(seqs) == seqs

    kinds = Enum.map(seqs_and_kinds, &elem(&1, 1))
    assert "spawned" in kinds
    assert "action_policy_decision" in kinds

    index_files = manifest["checkpoints"] |> Enum.map(&Path.basename(&1["path"])) |> Enum.sort()

    disk_files =
      ledger.run_dir
      |> Path.join("checkpoints")
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort()

    assert index_files == disk_files
  end

  test "link_artifacts records present, missing, skipped, and failed statuses" do
    workspace_root = tmp_dir("ledger-artifact-status")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "a7t5t4t"
             )

    File.write!(Path.join(ledger.run_dir, "artifacts/exists.txt"), "x")

    assert {:ok, ledger} =
             RunLedger.link_artifacts(ledger, [
               %{"kind" => "present_thing", "path" => "artifacts/exists.txt"},
               %{"kind" => "missing_thing", "path" => "artifacts/nope.txt"},
               %{"kind" => "skipped_thing", "path" => "artifacts/nope.txt", "status" => "skipped"},
               %{"kind" => "failed_thing", "path" => "artifacts/nope.txt", "status" => "failed"}
             ])

    manifest = decode_json!(ledger.manifest_path)

    assert %{
             "kind" => "present_thing",
             "path" => "artifacts/exists.txt",
             "status" => "present"
           } in manifest["artifacts"]

    assert %{
             "kind" => "missing_thing",
             "path" => "artifacts/nope.txt",
             "status" => "missing"
           } in manifest["artifacts"]

    assert %{
             "kind" => "skipped_thing",
             "path" => "artifacts/nope.txt",
             "status" => "skipped"
           } in manifest["artifacts"]

    assert %{
             "kind" => "failed_thing",
             "path" => "artifacts/nope.txt",
             "status" => "failed"
           } in manifest["artifacts"]
  end

  test "manifest checkpoint index is reconciled against checkpoint files on disk" do
    workspace_root = tmp_dir("ledger-reconcile")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "reconc1e"
             )

    # Simulate a partial write: a checkpoint file exists but the manifest
    # index has not been updated yet. A subsequent write must observe the file
    # and derive the next sequence from it, then repair the manifest index.
    orphan_path = Path.join(ledger.run_dir, "checkpoints/0005-orphan.json")

    orphan_checkpoint = %{
      "seq" => 5,
      "kind" => "orphan",
      "timestamp" => "2026-05-10T15:30:12Z",
      "source" => %{},
      "payload" => %{}
    }

    File.write!(orphan_path, Jason.encode!(orphan_checkpoint))

    assert {:ok, ledger} = RunLedger.write_checkpoint(ledger, :dispatch, %{}, timestamp: @now)

    manifest = decode_json!(ledger.manifest_path)

    seqs = Enum.map(manifest["checkpoints"], & &1["seq"])
    assert 5 in seqs
    assert 6 in seqs
    assert seqs == Enum.uniq(seqs)
    assert seqs == Enum.sort(seqs)

    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "orphan"))

    index_files = manifest["checkpoints"] |> Enum.map(&Path.basename(&1["path"])) |> Enum.sort()

    disk_files =
      ledger.run_dir
      |> Path.join("checkpoints")
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort()

    assert index_files == disk_files
  end

  test "reconciled_manifest deduplicates orphaned checkpoints that share seq numbers with the index" do
    workspace_root = tmp_dir("ledger-reconcile-dedup")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "dedup001"
             )

    assert {:ok, ledger} = RunLedger.write_checkpoint(ledger, :dispatch, %{attempt: 1}, timestamp: @now)

    # Plant an orphaned checkpoint file on disk with the same seq=1 as the
    # existing dispatch checkpoint but a different kind.  Without deduplication
    # the manifest would end up with two entries at seq=1.
    orphan_path = Path.join(ledger.run_dir, "checkpoints/0001-orphan.json")

    orphan_checkpoint = %{
      "seq" => 1,
      "kind" => "orphan",
      "timestamp" => "2026-05-10T15:30:12Z",
      "source" => %{},
      "payload" => %{}
    }

    File.write!(orphan_path, Jason.encode!(orphan_checkpoint))

    # A new write forces reconciliation and must NOT include the orphan with
    # duplicate seq.
    assert {:ok, ledger} = RunLedger.write_checkpoint(ledger, :spawned, %{pid: "pid-1"}, timestamp: @now)

    manifest = decode_json!(ledger.manifest_path)
    seqs = Enum.map(manifest["checkpoints"], & &1["seq"])
    assert seqs == Enum.uniq(seqs)
    assert seqs == Enum.sort(seqs)

    # The orphaned file must still be present on disk; it is just excluded
    # from the manifest checkpoint index.
    assert File.exists?(orphan_path)
  end

  test "reconciled_manifest deduplicates duplicate-seq orphaned checkpoint files" do
    workspace_root = tmp_dir("ledger-reconcile-duplicate-orphans")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "duporph1"
             )

    action_policy_path = Path.join(ledger.run_dir, "checkpoints/0003-action_policy_decision.json")
    spawned_path = Path.join(ledger.run_dir, "checkpoints/0003-spawned.json")

    File.write!(
      action_policy_path,
      Jason.encode!(%{
        "seq" => 3,
        "kind" => "action_policy_decision",
        "timestamp" => "2026-05-10T15:30:12Z",
        "source" => %{},
        "payload" => %{}
      })
    )

    File.write!(
      spawned_path,
      Jason.encode!(%{
        "seq" => 3,
        "kind" => "spawned",
        "timestamp" => "2026-05-10T15:30:13Z",
        "source" => %{},
        "payload" => %{}
      })
    )

    assert {:ok, ledger} = RunLedger.write_checkpoint(ledger, :dispatch, %{attempt: 1}, timestamp: @now)

    manifest = decode_json!(ledger.manifest_path)
    seqs = Enum.map(manifest["checkpoints"], & &1["seq"])

    assert seqs == Enum.uniq(seqs)
    assert seqs == [3, 4]
    assert Enum.count(manifest["checkpoints"], &(&1["seq"] == 3)) == 1
    assert File.exists?(action_policy_path)
    assert File.exists?(spawned_path)
  end

  test "record_final_report persists and links valid rondo.final_report/v0 reports" do
    workspace_root = tmp_dir("ledger-final-report-valid")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "0fada7a1"
             )

    report = %{
      "schema" => "rondo.final_report/v0",
      "summary" => "Did the work",
      "changed_files" => ["lib/a.ex"],
      "gates_run" => [%{"name" => "elixir-ci", "status" => "pass"}],
      "failures" => [],
      "risks" => [],
      "next_state" => "ready_for_review"
    }

    final_report_text = "All done.\n```json\n#{Jason.encode!(report)}\n```\n"

    assert {:ok, ledger, :valid} = RunLedger.record_final_report(ledger, final_report_text)
    assert RunLedger.final_report_relative_path() == "artifacts/final-report.json"

    persisted = decode_json!(Path.join(ledger.run_dir, "artifacts/final-report.json"))
    assert persisted == report

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["final_report"] == %{"status" => "valid", "errors" => [], "path" => "artifacts/final-report.json"}
    refute Map.has_key?(manifest, "failure_classification")

    assert %{
             "kind" => "final_report",
             "path" => "artifacts/final-report.json",
             "status" => "present"
           } in manifest["artifacts"]

    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "final_report_validated"))
  end

  test "record_final_report classifies missing and invalid reports distinctly" do
    workspace_root = tmp_dir("ledger-final-report-bad")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "baddad00"
             )

    assert {:ok, ledger, :missing} = RunLedger.record_final_report(ledger, "plain prose, no JSON report")

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["final_report"]["status"] == "missing"
    assert manifest["failure_classification"] == "final_report_missing"
    refute File.exists?(Path.join(ledger.run_dir, "artifacts/final-report.json"))

    assert {:ok, ledger, :invalid} = RunLedger.record_final_report(ledger, ~s({"schema": "rondo.final_report/v0"}))

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["final_report"]["status"] == "invalid"
    assert Enum.any?(manifest["final_report"]["errors"], &(&1 =~ "summary must be"))
    assert manifest["failure_classification"] == "final_report_invalid"

    checkpoint_kinds = Enum.map(manifest["checkpoints"], & &1["kind"])
    assert Enum.count(checkpoint_kinds, &(&1 == "final_report_validated")) == 2
  end

  test "record_final_report clears stale missing/invalid classifications on a later valid report" do
    workspace_root = tmp_dir("ledger-final-report-recovered")

    report = %{
      "schema" => "rondo.final_report/v0",
      "summary" => "Did the work",
      "changed_files" => ["lib/a.ex"],
      "gates_run" => [%{"name" => "elixir-ci", "status" => "pass"}],
      "failures" => [],
      "risks" => [],
      "next_state" => "ready_for_review"
    }

    valid_report_text = "All done.\n```json\n#{Jason.encode!(report)}\n```\n"

    for {bad_report_text, classification, suffix} <- [
          {"plain prose, no JSON report", "final_report_missing", "c1ea4a01"},
          {~s({"schema": "rondo.final_report/v0"}), "final_report_invalid", "c1ea4a02"}
        ] do
      assert {:ok, ledger} =
               RunLedger.create_run(issue_fixture(),
                 workspace_root: workspace_root,
                 now: @now,
                 random_suffix: suffix
               )

      assert {:ok, ledger, _status} = RunLedger.record_final_report(ledger, bad_report_text)
      assert decode_json!(ledger.manifest_path)["failure_classification"] == classification

      assert {:ok, ledger, :valid} = RunLedger.record_final_report(ledger, valid_report_text)

      manifest = decode_json!(ledger.manifest_path)
      assert manifest["final_report"]["status"] == "valid"
      refute Map.has_key?(manifest, "failure_classification")
    end
  end

  test "record_final_report surfaces ledger write failures" do
    workspace_root = tmp_dir("ledger-final-report-error")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "e1e1e1e1"
             )

    File.rm!(ledger.manifest_path)
    File.mkdir_p!(ledger.manifest_path)

    assert {:error, reason} = RunLedger.record_final_report(ledger, nil)
    assert reason in [:eisdir, :eacces]
  end

  test "checkpoint collision triggers retry and recovers with re-derived sequence" do
    workspace_root = tmp_dir("ledger-collision-retry")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "c011151n"
             )

    run_dir = ledger.run_dir

    # The manifest_update callback writes a file at the expected checkpoint
    # path to simulate a TOCTOU race.  This forces do_write_checkpoint into
    # the retry_on_collision path which re-derives the next seq from the
    # on-disk manifest and reconciled checkpoint files.
    # Note: the callback is invoked twice (once in do_write_checkpoint and
    # once in retry_on_collision), so we only plant the collision on the
    # first invocation.
    collision_cb = fn manifest ->
      checkpoints = Map.get(manifest, "checkpoints", [])

      if length(checkpoints) == 1 do
        [%{"path" => rel_path}] = checkpoints
        File.write!(Path.join(run_dir, rel_path), Jason.encode!(%{"collision" => true}))
      end

      manifest
    end

    assert {:ok, ledger} =
             RunLedger.write_checkpoint(ledger, :dispatch, %{attempt: 1},
               timestamp: @now,
               manifest_update: collision_cb
             )

    manifest = decode_json!(ledger.manifest_path)
    seqs = Enum.map(manifest["checkpoints"], & &1["seq"])
    assert seqs == [1, 2]
    assert seqs == Enum.uniq(seqs)
    assert seqs == Enum.sort(seqs)

    kinds = Enum.map(manifest["checkpoints"], & &1["kind"])
    assert "unknown" in kinds
    assert "dispatch" in kinds

    # The collision file (orphan) is still on disk.
    assert File.exists?(Path.join(ledger.run_dir, "checkpoints/0001-dispatch.json"))
    # The retry wrote the actual checkpoint with a bumped seq.
    assert File.exists?(Path.join(ledger.run_dir, "checkpoints/0002-dispatch.json"))

    retry_checkpoint = decode_json!(Path.join(ledger.run_dir, "checkpoints/0002-dispatch.json"))
    assert retry_checkpoint["seq"] == 2
    assert retry_checkpoint["kind"] == "dispatch"
    assert retry_checkpoint["payload"] == %{"attempt" => 1}
  end

  test "lock timeout returns :lock_timeout when the lock cannot be acquired" do
    workspace_root = tmp_dir("ledger-lock-timeout")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "10ckt0ut"
             )

    # Hold an exclusive lock on the ledger lock file.
    lock_path = Path.join(ledger.run_dir, ".ledger.lock")
    File.mkdir_p!(ledger.run_dir)
    {:ok, _held_lock} = File.open(lock_path, [:write, :exclusive, :binary])

    task =
      Task.async(fn ->
        RunLedger.write_checkpoint(ledger, :dispatch, %{attempt: 1}, timestamp: @now)
      end)

    result = Task.await(task, 5_000)
    assert {:error, {:lock_failed, :lock_timeout}} = result
  end

  test "stale lock is detected and removed before acquisition" do
    workspace_root = tmp_dir("ledger-stale-lock")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "57a1e10c"
             )

    # Write a lock file with a timestamp far in the past so it is considered stale.
    lock_path = Path.join(ledger.run_dir, ".ledger.lock")
    File.mkdir_p!(ledger.run_dir)
    File.write!(lock_path, "0")

    assert File.exists?(lock_path)
    assert {:ok, _ledger} = RunLedger.write_checkpoint(ledger, :dispatch, %{attempt: 1}, timestamp: @now)
    refute File.exists?(lock_path)
  end

  test "orchestrator/worker update paths produce unique monotonic sequences — stale write source" do
    workspace_root = tmp_dir("ledger-stale-source")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "5ta1e5rc"
             )

    # Simulate the dogfood shape: a worker and orchestrator write at
    # overlapping times via a stale ledger copy.  After the lock serialises
    # them, there must be exactly two distinct seqs.
    stale = %{ledger | next_seq: ledger.next_seq, manifest: ledger.manifest}

    [worker_task, orch_task] =
      [
        Task.async(fn -> RunLedger.write_checkpoint(stale, :spawned, %{pid: "pid-1"}, timestamp: @now) end),
        Task.async(fn ->
          RunLedger.record_action_policy_decision(stale, %{
            "decision" => "deny",
            "mode" => "unattended-auto",
            "action" => "git.push"
          })
        end)
      ]

    results = Enum.map([worker_task, orch_task], &Task.await/1)

    assert Enum.all?(results, fn
             {:ok, _} -> true
             _ -> false
           end)

    manifest = decode_json!(ledger.manifest_path)
    seqs = Enum.map(manifest["checkpoints"], & &1["seq"])
    assert length(seqs) == 2
    assert seqs == Enum.uniq(seqs)
    assert seqs == Enum.sort(seqs)

    index_files = manifest["checkpoints"] |> Enum.map(&Path.basename(&1["path"])) |> Enum.sort()

    disk_files =
      ledger.run_dir
      |> Path.join("checkpoints")
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort()

    assert index_files == disk_files
  end

  test "reconciled_manifest handles unreadable checkpoints directory gracefully" do
    workspace_root = tmp_dir("ledger-reconcile-dir-error")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "d1r3rr0r"
             )

    # Remove the checkpoints directory so File.ls returns an error.
    File.rm_rf!(Path.join(ledger.run_dir, "checkpoints"))

    assert {:ok, ledger} = RunLedger.write_checkpoint(ledger, :dispatch, %{attempt: 1}, timestamp: @now)

    manifest = decode_json!(ledger.manifest_path)
    assert [%{"seq" => 1, "kind" => "dispatch"}] = manifest["checkpoints"]
  end

  test "reconciled_manifest handles malformed and non-digit-named checkpoint files on disk" do
    workspace_root = tmp_dir("ledger-reconcile-malformed")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "ma1f0rme"
             )

    checkpoints_dir = Path.join(ledger.run_dir, "checkpoints")

    # Plant a .json file whose name does not start with digits.
    # Its content does NOT contain valid seq/kind/timestamp so
    # parse_checkpoint_index falls through to synthesize_checkpoint_index,
    # which returns nil because checkpoint_seq_from_filename fails.
    # The nil entry is then rejected by orphan_index_eligible? (non-map clause).
    non_digit_path = Path.join(checkpoints_dir, "orphan.json")
    File.write!(non_digit_path, Jason.encode!(%{"note" => "no seq"}))

    # Plant a file with a digit prefix but unparseable JSON body.
    bad_json_path = Path.join(checkpoints_dir, "0007-malformed.json")
    File.write!(bad_json_path, "not json at all")

    assert {:ok, ledger} = RunLedger.write_checkpoint(ledger, :dispatch, %{attempt: 1}, timestamp: @now)

    manifest = decode_json!(ledger.manifest_path)
    seqs = Enum.map(manifest["checkpoints"], & &1["seq"])

    # The 0007-malformed file is synthesised from filename → kind=unknown, seq=7.
    # The orphan.json produces nil and is skipped.
    # Then the dispatch checkpoint gets the next available seq (8).
    assert 7 in seqs
    assert 8 in seqs
    assert seqs == Enum.uniq(seqs)
    assert seqs == Enum.sort(seqs)

    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "unknown" and &1["seq"] == 7))
    assert File.exists?(non_digit_path)
    assert File.exists?(bad_json_path)
  end

  test "link_artifacts handles non-list artifacts in the on-disk manifest" do
    workspace_root = tmp_dir("ledger-artifacts-nonlist")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "n0n115t"
             )

    # Corrupt the on-disk manifest so artifacts is a string, not a list.
    manifest = decode_json!(ledger.manifest_path)
    manifest = Map.put(manifest, "artifacts", "corrupted")
    File.write!(ledger.manifest_path, Jason.encode!(manifest))

    File.write!(Path.join(ledger.run_dir, "artifacts/present.txt"), "content")

    assert {:ok, ledger} =
             RunLedger.link_artifacts(ledger, [
               %{"kind" => "resolved_thing", "path" => "artifacts/present.txt"}
             ])

    updated_manifest = decode_json!(ledger.manifest_path)

    assert %{
             "kind" => "resolved_thing",
             "path" => "artifacts/present.txt",
             "status" => "present"
           } in updated_manifest["artifacts"]
  end

  test "agent metadata update replaces non-map agent in on-disk manifest" do
    workspace_root = tmp_dir("ledger-agent-nonmap")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "a6entnm"
             )

    # Write valid manifest to disk with agent set to a string.
    manifest = decode_json!(ledger.manifest_path)
    manifest = Map.put(manifest, "agent", "legacy-string-agent")
    File.write!(ledger.manifest_path, Jason.encode!(manifest))

    assert {:ok, updated_ledger} =
             RunLedger.update_agent_metadata(ledger, %{
               "adapter" => "pi",
               "session_id" => "session-after-repair"
             })

    final_manifest = decode_json!(updated_ledger.manifest_path)
    assert final_manifest["agent"]["adapter"] == "pi"
    assert final_manifest["agent"]["session_id"] == "session-after-repair"
  end

  test "model_routing_decision replaces non-map agent in on-disk manifest" do
    workspace_root = tmp_dir("ledger-mr-nonmap")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "mrn0nm4p"
             )

    # Write valid manifest to disk with agent set to a string.
    manifest = decode_json!(ledger.manifest_path)
    manifest = Map.put(manifest, "agent", "legacy-string-agent")
    File.write!(ledger.manifest_path, Jason.encode!(manifest))

    routing = %{
      status: :honored,
      mode: :prefer,
      requested_tier: "heavy",
      resolved: %{adapter: "pi", model: "heavy-model"},
      reason: "resolved",
      context: %{stage: "turn"}
    }

    assert {:ok, updated_ledger} =
             RunLedger.record_model_routing_decision(ledger, routing, source: %{provider: "fake"})

    final_manifest = decode_json!(updated_ledger.manifest_path)

    assert final_manifest["agent"]["model_routing"] == %{
             "status" => "honored",
             "mode" => "prefer",
             "requested_tier" => "heavy",
             "resolved" => %{"adapter" => "pi", "model" => "heavy-model"},
             "reason" => "resolved",
             "context" => %{"stage" => "turn"}
           }
  end

  test "complete_run records task_failure classification distinct from final report classifications" do
    workspace_root = tmp_dir("ledger-classification")

    assert {:ok, failed_ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "fa11fa11"
             )

    assert {:ok, failed_ledger} = RunLedger.complete_run(failed_ledger, :failed, %{reason: "boom"}, timestamp: @now)
    failed_manifest = decode_json!(failed_ledger.manifest_path)
    assert failed_manifest["failure_classification"] == "task_failure"

    assert {:ok, completed_ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "c0ffee00"
             )

    assert {:ok, completed_ledger, :missing} = RunLedger.record_final_report(completed_ledger, nil)
    assert {:ok, completed_ledger} = RunLedger.complete_run(completed_ledger, :completed, %{mode: "run_once"}, timestamp: @now)

    completed_manifest = decode_json!(completed_ledger.manifest_path)
    assert completed_manifest["status"] == "completed"
    assert completed_manifest["failure_classification"] == "final_report_missing"

    assert {:ok, override_ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "0dd0dd00"
             )

    override_opts = [timestamp: @now, failure_classification: "task_failure"]
    assert {:ok, override_ledger} = RunLedger.complete_run(override_ledger, :failed, %{reason: "boom"}, override_opts)

    assert decode_json!(override_ledger.manifest_path)["failure_classification"] == "task_failure"

    assert {:ok, scan_ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "5ca55ca5"
             )

    assert {:ok, scan_ledger} = RunLedger.record_patch_secret_scan(scan_ledger, :pass)
    assert decode_json!(scan_ledger.manifest_path)["patch_secret_scan"]["status"] == "pass"
  end

  test "complete_run remains consistent when stale worker checkpoint writes overlap" do
    workspace_root = tmp_dir("ledger-complete-concurrent")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "compconc"
             )

    stale = %{ledger | next_seq: ledger.next_seq, manifest: ledger.manifest}

    tasks = [
      Task.async(fn -> RunLedger.complete_run(stale, :completed, %{mode: "run_once"}, timestamp: @now) end),
      Task.async(fn -> RunLedger.write_checkpoint(stale, :spawned, %{pid: "pid-1"}, timestamp: @now) end)
    ]

    assert Enum.all?(Task.await_many(tasks, 5_000), &match?({:ok, %RunLedger{}}, &1))

    manifest = decode_json!(ledger.manifest_path)
    seqs = Enum.map(manifest["checkpoints"], & &1["seq"])

    assert manifest["status"] == "completed"
    assert seqs == Enum.uniq(seqs)
    assert seqs == Enum.sort(seqs)
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "completed"))
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "spawned"))

    index_files = manifest["checkpoints"] |> Enum.map(&Path.basename(&1["path"])) |> Enum.sort()

    disk_files =
      ledger.run_dir
      |> Path.join("checkpoints")
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort()

    assert index_files == disk_files
  end

  test "link_artifacts refreshes completed-run delivery artifact without reentrant lock timeout" do
    workspace_root = tmp_dir("ledger-delivery-refresh")

    assert {:ok, ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "de1e0k00"
             )

    assert {:ok, ledger} = RunLedger.complete_run(ledger, :completed, %{mode: "test"}, timestamp: @now)

    archive_relative_path = "artifacts/archive/run.json"
    File.mkdir_p!(Path.dirname(Path.join(ledger.run_dir, archive_relative_path)))
    File.write!(Path.join(ledger.run_dir, archive_relative_path), Jason.encode!(%{"ok" => true}))

    assert {:ok, ledger} = RunLedger.link_archive(ledger, archive_relative_path)

    manifest = decode_json!(ledger.manifest_path)

    assert %{"kind" => "archive", "path" => archive_relative_path, "status" => "present"} in manifest["artifacts"]
    assert %{"kind" => "delivery_artifact", "path" => "artifacts/delivery-artifact.json", "status" => "present"} in manifest["artifacts"]

    delivery_artifact = decode_json!(Path.join(ledger.run_dir, "artifacts/delivery-artifact.json"))
    assert delivery_artifact["outputs"]["archive"] == archive_relative_path
  end

  test "delivery artifact write failures surface from completed ledgers" do
    workspace_root = tmp_dir("ledger-delivery-errors")

    assert {:ok, blocked_artifact_dir_ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "de1e0001"
             )

    File.rm_rf!(Path.join(blocked_artifact_dir_ledger.run_dir, "artifacts"))
    File.write!(Path.join(blocked_artifact_dir_ledger.run_dir, "artifacts"), "blocking file")

    assert {:error, _reason} =
             RunLedger.complete_run(blocked_artifact_dir_ledger, :completed, %{mode: "test"}, timestamp: @now)

    assert {:ok, refresh_ledger} =
             RunLedger.create_run(issue_fixture(),
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "de1e0002"
             )

    assert {:ok, refresh_ledger} = RunLedger.complete_run(refresh_ledger, :completed, %{mode: "test"}, timestamp: @now)
    File.rm_rf!(Path.join(refresh_ledger.run_dir, "artifacts"))
    File.write!(Path.join(refresh_ledger.run_dir, "artifacts"), "blocking file")

    assert {:error, _reason} = RunLedger.link_archive(refresh_ledger, "artifacts/archive/run.json")
  end

  defp issue_fixture do
    %Issue{
      id: "issue-401",
      identifier: "MT-401",
      title: "Durable ledger",
      description: "Persist the run lifecycle",
      state: "In Progress",
      url: "https://example.org/issues/MT-401",
      labels: ["P0"],
      priority: 1
    }
  end

  defp decode_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp git!(cd, args) do
    {output, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(output)
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
