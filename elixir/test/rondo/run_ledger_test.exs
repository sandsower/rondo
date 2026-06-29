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
      "raw" => %{"method" => "turn/completed", "result" => "private result"}
    }

    assert RunLedger.checkpoint_payload_for_agent_update(update) == %{
             event: "result",
             adapter: "fake",
             run_ref: %{"adapter" => "fake", "provider_ref" => "run-1", "provider_ref_kind" => "thread_id", "resumable?" => true},
             session_id: "session-json",
             usage: %{"input_tokens" => 11},
             capabilities: %{"resume" => "thread_id"},
             final_report: "done",
             raw: %{"method" => "turn/completed", "result" => "[REDACTED]"}
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
        "safe" => "redacted by default"
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
    assert %{"kind" => "final_report", "path" => "artifacts/final-report.json"} in manifest["artifacts"]
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
