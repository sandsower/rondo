defmodule Rondo.OrchestratorExecutionRequestTest do
  use Rondo.TestSupport

  alias Rondo.Core.RunLocator
  alias Rondo.Orchestrator
  alias Rondo.RunLedger

  defmodule SnapshotTrackerClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_issue_states_by_ids(issue_ids) do
      if pid = Application.get_env(:rondo, :snapshot_tracker_test_pid) do
        send(pid, {:snapshot_tracker_state_fetch, issue_ids})
      end

      {:ok, []}
    end

    def fetch_issue_contexts_by_ids(_issue_ids), do: {:ok, []}
  end

  test "snapshot bypasses tracker state fetches when there are no tracker-backed paused ids" do
    workspace_root = tmp_dir("core-empty-snapshot-ids")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    previous_client = Application.get_env(:rondo, :linear_client_module)
    previous_pid = Application.get_env(:rondo, :snapshot_tracker_test_pid)
    Application.put_env(:rondo, :linear_client_module, SnapshotTrackerClient)
    Application.put_env(:rondo, :snapshot_tracker_test_pid, self())

    {:ok, pid} = Orchestrator.start_link(name: unique_name(:CoreEmptySnapshotIds))

    on_exit(fn ->
      stop_orchestrator(pid)
      restore_application_env(:linear_client_module, previous_client)
      restore_application_env(:snapshot_tracker_test_pid, previous_pid)
      File.rm_rf(workspace_root)
    end)

    assert Orchestrator.snapshot(pid, 1_000).paused == []
    refute_receive {:snapshot_tracker_state_fetch, []}, 100
  end

  test "submits one approved manifest, deduplicates it, and keeps tracker polling isolated" do
    parent = self()
    workspace_root = tmp_dir("core-submit")
    export = approved_export(workspace_root, "slice-submit")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      max_concurrent_agents: 1,
      poll_interval_ms: 60_000
    )

    runner = blocking_runner(parent)
    {:ok, pid} = Orchestrator.start_link(name: unique_name(:CoreSubmit), execution_request_runner: runner)

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    request = request(export, "repo:opaque/one")

    assert {:ok, submitted} = Orchestrator.submit_execution_request(pid, request)
    assert submitted.surface == "rondo.core/v1"
    assert submitted.service_id == "rondo-core"
    assert submitted.repo_id == "repo:opaque/one"
    assert submitted.status == "running"
    assert submitted.event_cursor == "rondo.core/v1:0"
    refute submitted.deduplicated

    assert_receive {:execution_runner_started, runner_pid, issue, runner_opts}, 1_000
    identity = execution_identity("repo:opaque/one", export.digest)
    assert issue.id == "execution-request:#{identity}"
    assert issue.identifier == "execution-request-#{identity}"
    assert issue.title == "Execution request slice-submit"
    assert runner_opts[:trackerless] == true
    assert runner_opts[:source_contract].sha256 == export.digest

    [%{run_dir: run_dir}] = Orchestrator.snapshot(pid, 1_000).running
    frozen_manifest_path = Path.join(run_dir, "artifacts/execution-request.json")
    frozen_bundle_path = Path.join(run_dir, "artifacts/approval-bundle.json")
    assert {:ok, canonical_source_path} = Rondo.PathSafety.canonicalize(export.manifest_path)
    assert runner_opts[:source_contract].path == frozen_manifest_path
    assert runner_opts[:source_contract].source_path == canonical_source_path
    assert File.read!(frozen_manifest_path) == File.read!(export.manifest_path)
    assert File.read!(frozen_bundle_path) == File.read!(Path.join(Path.dirname(Path.dirname(export.manifest_path)), "bundle.json"))

    assert {:ok, accepted_manifest} = RunLedger.load_manifest(run_dir)
    assert accepted_manifest["admission"]["phase"] == "accepted"
    assert accepted_manifest["status"] == "running"

    assert {:ok, duplicate} = Orchestrator.submit_execution_request(pid, request)
    assert duplicate.run_id == submitted.run_id
    assert duplicate.status == "running"
    assert duplicate.deduplicated
    refute_receive {:execution_runner_started, _pid, _issue, _opts}, 100

    snapshot = Orchestrator.snapshot(pid, 1_000)
    assert [%{run_id: run_id, source: :execution_request, repo_id: "repo:opaque/one"}] = snapshot.running
    assert run_id == submitted.run_id

    # A tracker reconciliation pass must not classify a tracker-less request as
    # missing and terminate it.
    send(pid, :run_poll_cycle)

    assert eventually(fn ->
             case Orchestrator.snapshot(pid, 1_000).running do
               [%{run_id: ^run_id}] -> true
               _other -> false
             end
           end)

    send(runner_pid, :complete)

    archived =
      eventually(fn ->
        Orchestrator.snapshot(pid, 1_000).archived
        |> Enum.find(&(&1.run_id == run_id))
      end)

    assert archived.source == :execution_request
    assert archived.repo_id == "repo:opaque/one"
    assert archived.exit_reason == "completed"

    final_snapshot = Orchestrator.snapshot(pid, 1_000)
    assert final_snapshot.running == []
    assert final_snapshot.retrying == []

    assert {:ok, manifest} = RunLedger.load_manifest(archived.run_dir)
    assert manifest["repo"]["repo_id"] == "repo:opaque/one"
    assert manifest["source_contract"]["sha256"] == export.digest
    assert manifest["source_contract"]["path"] == frozen_manifest_path
    assert manifest["source_contract"]["source_path"] == canonical_source_path

    digest = export.digest

    assert %{
             "kind" => "execution_request",
             "path" => "artifacts/execution-request.json",
             "sha256" => ^digest,
             "status" => "present",
             "recorded_at" => recorded_at
           } = Enum.find(manifest["artifacts"], &(&1["kind"] == "execution_request"))

    assert {:ok, _, 0} = DateTime.from_iso8601(recorded_at)

    assert manifest["status"] == "completed"
  end

  test "trackerless Core admits an approved request without tracker configuration" do
    parent = self()
    workspace_root = tmp_dir("core-trackerless-admission")
    export = approved_export(workspace_root, "slice-trackerless-admission")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: nil,
      workspace_root: workspace_root,
      max_concurrent_agents: 1,
      poll_interval_ms: 60_000
    )

    {:ok, core_pid} =
      Orchestrator.start_link(
        name: unique_name(:TrackerlessAdmission),
        tracker_polling: false,
        execution_request_runner: blocking_runner(parent)
      )

    {:ok, daemon_pid} =
      Orchestrator.start_link(
        name: unique_name(:TrackerDaemonAdmission),
        tracker_polling: true,
        execution_request_runner: blocking_runner(parent)
      )

    on_exit(fn ->
      stop_orchestrator(core_pid)
      stop_orchestrator(daemon_pid)
      File.rm_rf(workspace_root)
    end)

    core_request = request(export, "repo-trackerless-admission")
    assert {:ok, submitted} = Orchestrator.submit_execution_request(core_pid, core_request)
    assert submitted.status == "running"
    assert_receive {:execution_runner_started, runner_pid, _issue, _opts}, 1_000

    assert {:error, {:configuration_invalid, {:invalid_workflow_config, _, errors}}} =
             Orchestrator.submit_execution_request(daemon_pid, core_request)

    assert Enum.any?(errors, &(&1.path == "tracker.repo"))
    send(runner_pid, :complete)
  end

  test "archives a failed execution request without tracker retry and deduplicates the terminal run" do
    parent = self()
    workspace_root = tmp_dir("core-failure")
    export = approved_export(workspace_root, "slice-failure")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    {:ok, pid} =
      Orchestrator.start_link(
        name: unique_name(:CoreFailure),
        execution_request_runner: blocking_runner(parent)
      )

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    request = request(export, "repo-failure")
    assert {:ok, submitted} = Orchestrator.submit_execution_request(pid, request)
    assert_receive {:execution_runner_started, runner_pid, _issue, _opts}, 1_000

    send(runner_pid, {:fail, :mechanical_failure})

    archived =
      eventually(fn ->
        Orchestrator.snapshot(pid, 1_000).archived
        |> Enum.find(&(&1.run_id == submitted.run_id))
      end)

    assert archived.source == :execution_request
    assert archived.repo_id == "repo-failure"
    assert archived.manifest_sha256 == export.digest
    assert archived.exit_reason =~ "mechanical_failure"

    snapshot = Orchestrator.snapshot(pid, 1_000)
    assert snapshot.running == []
    assert snapshot.retrying == []

    assert {:ok, manifest} = RunLedger.load_manifest(archived.run_dir)
    assert manifest["status"] == "failed"
    assert manifest["repo"]["repo_id"] == "repo-failure"
    assert manifest["source_contract"]["sha256"] == export.digest
    assert manifest["source"] == "execution_request"
    refute Enum.any?(manifest["checkpoints"], &(&1["kind"] == "run_decision"))

    assert {:ok, duplicate} = Orchestrator.submit_execution_request(pid, request)
    assert duplicate.run_id == submitted.run_id
    assert duplicate.status == "failed"
    assert duplicate.deduplicated
    refute_receive {:execution_runner_started, _pid, _issue, _opts}, 100

    stop_orchestrator(pid)
    {:ok, restarted_pid} = Orchestrator.start_link(name: unique_name(:CoreFailureRestart))
    on_exit(fn -> stop_orchestrator(restarted_pid) end)

    restarted_archive =
      eventually(fn ->
        Orchestrator.snapshot(restarted_pid, 1_000).archived
        |> Enum.find(&(&1.run_id == submitted.run_id))
      end)

    assert restarted_archive.source == :execution_request
    assert restarted_archive.repo_id == "repo-failure"
    assert restarted_archive.manifest_sha256 == export.digest
  end

  test "atomically deduplicates concurrent submissions by repository and digest" do
    parent = self()
    workspace_root = tmp_dir("core-concurrent-dedupe")
    export = approved_export(workspace_root, "slice-concurrent-dedupe")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      max_concurrent_agents: 2,
      poll_interval_ms: 60_000
    )

    {:ok, pid} =
      Orchestrator.start_link(
        name: unique_name(:CoreConcurrentDedupe),
        execution_request_runner: blocking_runner(parent)
      )

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    request = request(export, "repo-concurrent")

    results =
      1..2
      |> Enum.map(fn _index -> Task.async(fn -> Orchestrator.submit_execution_request(pid, request) end) end)
      |> Task.await_many(5_000)

    assert [
             {:ok, %{deduplicated: false, run_id: run_id}},
             {:ok, %{deduplicated: true, run_id: run_id}}
           ] = Enum.sort_by(results, fn {:ok, result} -> result.deduplicated end)

    assert_receive {:execution_runner_started, runner_pid, _issue, _opts}, 1_000
    refute_receive {:execution_runner_started, _pid, _issue, _opts}, 100

    manifests =
      Path.wildcard(
        Path.join([
          workspace_root,
          ".rondo_runs",
          execution_identifier("repo-concurrent", export.digest),
          "*",
          "manifest.json"
        ])
      )

    assert length(manifests) == 1
    send(runner_pid, :complete)
  end

  test "does not bypass dedupe when the accepted ledger is corrupt" do
    parent = self()
    workspace_root = tmp_dir("core-corrupt-dedupe")
    export = approved_export(workspace_root, "slice-corrupt-dedupe")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      max_concurrent_agents: 2,
      poll_interval_ms: 60_000
    )

    {:ok, pid} =
      Orchestrator.start_link(
        name: unique_name(:CoreCorruptDedupe),
        execution_request_runner: blocking_runner(parent)
      )

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    core_request = request(export, "repo-corrupt-dedupe")
    assert {:ok, submitted} = Orchestrator.submit_execution_request(pid, core_request)
    assert_receive {:execution_runner_started, runner_pid, _issue, _opts}, 1_000

    [%{run_dir: run_dir}] = Orchestrator.snapshot(pid, 1_000).running
    File.write!(Path.join(run_dir, "manifest.json"), "{not json")

    assert {:error, {:invalid_run_ledger, _run_dir, :invalid_json}} =
             Orchestrator.submit_execution_request(pid, core_request)

    refute_receive {:execution_runner_started, _pid, _issue, _opts}, 100

    manifests =
      Path.wildcard(
        Path.join([
          workspace_root,
          ".rondo_runs",
          execution_identifier("repo-corrupt-dedupe", export.digest),
          "*",
          "manifest.json"
        ])
      )

    assert length(manifests) == 1
    assert Path.basename(Path.dirname(List.first(manifests))) == submitted.run_id
    send(runner_pid, :complete)
  end

  test "same-slice submissions use distinct namespaced workspaces and run-specific archives" do
    parent = self()
    workspace_root = tmp_dir("core-same-slice-isolation")
    export = approved_export(workspace_root, "shared-display-slice")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      max_concurrent_agents: 2,
      poll_interval_ms: 60_000
    )

    {:ok, pid} =
      Orchestrator.start_link(
        name: unique_name(:CoreSameSliceIsolation),
        execution_request_runner: blocking_runner(parent)
      )

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    assert {:ok, first} =
             Orchestrator.submit_execution_request(pid, request(export, "repo-shared-a"))

    assert {:ok, second} =
             Orchestrator.submit_execution_request(pid, request(export, "repo-shared-b"))

    assert_receive {:execution_runner_started, first_runner, first_issue, _opts}, 1_000
    assert_receive {:execution_runner_started, second_runner, second_issue, _opts}, 1_000
    refute first_issue.id == second_issue.id
    refute first_issue.identifier == second_issue.identifier
    assert first_issue.title == second_issue.title

    running_by_id = Map.new(Orchestrator.snapshot(pid, 1_000).running, &{&1.run_id, &1})
    first_running = Map.fetch!(running_by_id, first.run_id)
    second_running = Map.fetch!(running_by_id, second.run_id)
    refute first_running.run_dir == second_running.run_dir

    assert {:ok, first_manifest} = RunLedger.load_manifest(first_running.run_dir)
    assert {:ok, second_manifest} = RunLedger.load_manifest(second_running.run_dir)
    first_workspace = get_in(first_manifest, ["repo", "workspace"])
    second_workspace = get_in(second_manifest, ["repo", "workspace"])
    refute first_workspace == second_workspace
    assert strict_descendant?(first_workspace, workspace_root)
    assert strict_descendant?(second_workspace, workspace_root)

    send(first_runner, :complete)
    send(second_runner, :complete)

    archived_by_id =
      eventually(fn ->
        archived = Orchestrator.snapshot(pid, 1_000).archived

        if Enum.any?(archived, &(&1.run_id == first.run_id)) and
             Enum.any?(archived, &(&1.run_id == second.run_id)) do
          Map.new(archived, &{&1.run_id, &1})
        end
      end)

    archive_paths =
      for run_id <- [first.run_id, second.run_id] do
        archived = Map.fetch!(archived_by_id, run_id)
        assert {:ok, manifest} = RunLedger.load_manifest(archived.run_dir)
        archive = Enum.find(manifest["artifacts"], &(&1["kind"] == "archive"))
        assert archive["status"] == "present"
        assert String.contains?(Path.basename(archive["path"]), run_id)
        assert strict_descendant?(archive["path"], Path.join(workspace_root, ".rondo_archive"))
        archive["path"]
      end

    assert Enum.uniq(archive_paths) == archive_paths
  end

  test "archive persistence refuses an identifier symlink outside the archive root" do
    parent = self()
    workspace_root = tmp_dir("core-archive-symlink")
    outside_root = Path.join(workspace_root, "outside-archive")
    export = approved_export(workspace_root, "archive-symlink")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    {:ok, pid} =
      Orchestrator.start_link(
        name: unique_name(:CoreArchiveSymlink),
        execution_request_runner: blocking_runner(parent)
      )

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    assert {:ok, submitted} =
             Orchestrator.submit_execution_request(pid, request(export, "repo-archive-symlink"))

    assert_receive {:execution_runner_started, runner_pid, issue, _opts}, 1_000
    archive_root = Path.join(workspace_root, ".rondo_archive")
    File.mkdir_p!(archive_root)
    File.mkdir_p!(outside_root)
    File.ln_s!(outside_root, Path.join(archive_root, issue.identifier))
    send(runner_pid, :complete)

    archived =
      eventually(fn ->
        Enum.find(Orchestrator.snapshot(pid, 1_000).archived, &(&1.run_id == submitted.run_id))
      end)

    assert File.ls!(outside_root) == []
    assert {:ok, manifest} = RunLedger.load_manifest(archived.run_dir)
    refute Enum.any?(manifest["artifacts"], &(&1["kind"] == "archive"))
  end

  test "persists paused execution requests across restart and rejects Core guidance" do
    parent = self()
    workspace_root = tmp_dir("core-pause")
    export = approved_export(workspace_root, "slice-pause")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    {:ok, pid} =
      Orchestrator.start_link(
        name: unique_name(:CorePause),
        execution_request_runner: blocking_runner(parent)
      )

    request = request(export, "repo-pause")
    assert {:ok, submitted} = Orchestrator.submit_execution_request(pid, request)
    assert_receive {:execution_runner_started, runner_pid, issue, _opts}, 1_000

    interrupt = %{
      "reason" => "action_policy_guidance_required",
      "question" => "Operator guidance required",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    send(runner_pid, {:fail, {:action_policy_guidance_required, interrupt}})

    paused =
      eventually(fn ->
        Orchestrator.snapshot(pid, 1_000).paused
        |> Enum.find(&(&1.run_id == submitted.run_id))
      end)

    assert paused.issue_id == issue.id
    assert paused.source == :execution_request
    assert paused.repo_id == "repo-pause"
    assert paused.manifest_sha256 == export.digest
    assert paused.tracker_visibility == "not_applicable"
    assert paused.blocks_dispatch

    assert {:error, :execution_request_guidance_unsupported} =
             Orchestrator.submit_guidance(pid, issue.id, "abort_run")

    assert {:ok, paused_manifest} = RunLedger.load_manifest(paused.run_dir)
    assert paused_manifest["status"] == "paused"

    send(pid, :run_poll_cycle)

    assert eventually(fn ->
             Enum.any?(Orchestrator.snapshot(pid, 1_000).paused, &(&1.run_id == submitted.run_id))
           end)

    stop_orchestrator(pid)

    {:ok, restarted_pid} = Orchestrator.start_link(name: unique_name(:CorePauseRestart))

    on_exit(fn ->
      stop_orchestrator(restarted_pid)
      File.rm_rf(workspace_root)
    end)

    restarted_paused =
      eventually(fn ->
        Orchestrator.snapshot(restarted_pid, 1_000).paused
        |> Enum.find(&(&1.run_id == submitted.run_id))
      end)

    assert restarted_paused.source == :execution_request
    assert restarted_paused.repo_id == "repo-pause"
    assert restarted_paused.manifest_sha256 == export.digest
    assert restarted_paused.tracker_visibility == "not_applicable"

    assert {:ok, duplicate} = Orchestrator.submit_execution_request(restarted_pid, request)
    assert duplicate.run_id == submitted.run_id
    assert duplicate.status == "paused"
    assert duplicate.deduplicated
  end

  test "terminates a stalled execution request without scheduling tracker retry" do
    parent = self()
    workspace_root = tmp_dir("core-stalled")
    export = approved_export(workspace_root, "slice-stalled")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      claude_stall_timeout_ms: 1,
      poll_interval_ms: 60_000
    )

    {:ok, pid} =
      Orchestrator.start_link(
        name: unique_name(:CoreStalled),
        execution_request_runner: blocking_runner(parent)
      )

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    assert {:ok, submitted} =
             Orchestrator.submit_execution_request(pid, request(export, "repo-stalled"))

    assert_receive {:execution_runner_started, _runner_pid, _issue, _opts}, 1_000
    Process.sleep(10)
    send(pid, :run_poll_cycle)

    archived =
      eventually(fn ->
        Orchestrator.snapshot(pid, 1_000).archived
        |> Enum.find(&(&1.run_id == submitted.run_id))
      end)

    assert archived.source == :execution_request
    assert archived.exit_reason =~ "execution_request_stalled"
    assert Orchestrator.snapshot(pid, 1_000).retrying == []
    assert {:ok, manifest} = RunLedger.load_manifest(archived.run_dir)
    assert manifest["status"] == "failed"
  end

  test "rejects a second request at capacity without creating its ledger" do
    parent = self()
    workspace_root = tmp_dir("core-capacity")
    first = approved_export(workspace_root, "slice-first")
    second = approved_export(workspace_root, "slice-second")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      max_concurrent_agents: 1,
      poll_interval_ms: 60_000
    )

    {:ok, pid} =
      Orchestrator.start_link(
        name: unique_name(:CoreCapacity),
        execution_request_runner: blocking_runner(parent)
      )

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    assert {:ok, %{deduplicated: false}} =
             Orchestrator.submit_execution_request(pid, request(first, "repo-capacity"))

    assert_receive {:execution_runner_started, runner_pid, _issue, _opts}, 1_000

    assert {:error, :capacity_exhausted} =
             Orchestrator.submit_execution_request(pid, request(second, "repo-capacity"))

    second_ledger_glob =
      Path.join([
        workspace_root,
        ".rondo_runs",
        execution_identifier("repo-capacity", second.digest),
        "*",
        "manifest.json"
      ])

    assert Path.wildcard(second_ledger_glob) == []
    refute_receive {:execution_runner_started, _pid, _issue, _opts}, 100

    send(runner_pid, :complete)
  end

  test "does not acknowledge when durable ledger creation fails" do
    workspace_root = tmp_dir("core-ledger-failure")
    export = approved_export(workspace_root, "slice-ledger-failure")

    occupied_identifier =
      Path.join([
        workspace_root,
        ".rondo_runs",
        execution_identifier("repo-ledger-failure", export.digest)
      ])

    File.mkdir_p!(Path.dirname(occupied_identifier))
    File.write!(occupied_identifier, "occupied")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    {:ok, pid} = Orchestrator.start_link(name: unique_name(:CoreLedgerFailure))

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    assert {:error, {:ledger_create_failed, _reason}} =
             Orchestrator.submit_execution_request(pid, request(export, "repo-ledger-failure"))

    assert Orchestrator.snapshot(pid, 1_000).running == []
  end

  test "sanitizes unsafe and unapproved export validation failures" do
    workspace_root = tmp_dir("core-validation-errors")
    export = approved_export(workspace_root, "slice-validation-errors")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    {:ok, pid} = Orchestrator.start_link(name: unique_name(:CoreValidationErrors))

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    assert {:error, :invalid_request} =
             Orchestrator.submit_execution_request(pid, %{
               manifest_path: "relative/slices/slice-validation-errors.json",
               manifest_sha256: export.digest,
               repo_id: "repo-validation-errors"
             })

    bundle_path =
      export.manifest_path
      |> Path.dirname()
      |> Path.dirname()
      |> Path.join("bundle.json")

    bundle = bundle_path |> File.read!() |> Jason.decode!()
    File.write!(bundle_path, Jason.encode!(Map.put(bundle, "status", "draft")))

    assert {:error, :unapproved_manifest} =
             Orchestrator.submit_execution_request(
               pid,
               request(export, "repo-validation-errors")
             )
  end

  test "keeps the worker gated until its ledger is accepted" do
    parent = self()
    workspace_root = tmp_dir("core-accepted-gate")
    export = approved_export(workspace_root, "slice-accepted-gate")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    after_accept = fn submission ->
      send(parent, {:execution_request_accepted, submission})

      receive do
        :release_after_accept -> :ok
      end
    end

    {:ok, pid} =
      Orchestrator.start_link(
        name: unique_name(:CoreAcceptedGate),
        execution_request_runner: blocking_runner(parent),
        execution_request_after_accept: after_accept
      )

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    submitter =
      Task.async(fn ->
        Orchestrator.submit_execution_request(
          pid,
          request(export, "repo-accepted-gate")
        )
      end)

    assert_receive {:execution_request_accepted, accepted}, 1_000
    refute_receive {:execution_runner_started, _pid, _issue, _opts}, 100

    assert {:ok, located} =
             RunLocator.locate(
               "repo-accepted-gate",
               accepted.run_id,
               workspace_root: workspace_root
             )

    assert located.manifest["admission"]["phase"] == "accepted"

    assert File.read!(Path.join(located.run_dir, "artifacts/execution-request.json")) ==
             File.read!(export.manifest_path)

    send(pid, :release_after_accept)
    assert {:ok, submitted} = Task.await(submitter, 2_000)
    assert submitted.run_id == accepted.run_id
    assert_receive {:execution_runner_started, runner_pid, _issue, _opts}, 1_000
    send(runner_pid, :complete)
  end

  test "rejects spawn failures so the same digest can be retried" do
    workspace_root = tmp_dir("core-spawn-retry")
    export = approved_export(workspace_root, "slice-spawn-retry")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    failing_starter = fn _task_supervisor, _task -> {:error, :worker_unavailable} end

    {:ok, pid} =
      Orchestrator.start_link(
        name: unique_name(:CoreSpawnRetry),
        execution_request_task_starter: failing_starter
      )

    on_exit(fn ->
      stop_orchestrator(pid)
      File.rm_rf(workspace_root)
    end)

    core_request = request(export, "repo-spawn-retry")

    for _attempt <- 1..2 do
      assert {:error, {:agent_spawn_failed, :worker_unavailable}} =
               Orchestrator.submit_execution_request(pid, core_request)
    end

    identifier = execution_identifier("repo-spawn-retry", export.digest)

    manifests =
      Path.wildcard(
        Path.join([
          workspace_root,
          ".rondo_runs",
          identifier,
          "*",
          "manifest.json"
        ])
      )

    assert length(manifests) == 2

    for path <- manifests do
      manifest = path |> File.read!() |> Jason.decode!()
      assert manifest["status"] == "failed"
      assert manifest["admission"]["phase"] == "rejected"
      assert manifest["admission"]["reason"] == "spawn_failed"
    end
  end

  defp blocking_runner(parent) do
    fn issue, _recipient, opts ->
      send(parent, {:execution_runner_started, self(), issue, opts})

      receive do
        :complete -> :ok
        {:fail, reason} -> exit(reason)
      end
    end
  end

  defp approved_export(root, slice_id) do
    bundle_dir = Path.join(root, "export-#{slice_id}")
    slices_dir = Path.join(bundle_dir, "slices")
    File.mkdir_p!(slices_dir)

    manifest = %{
      schema: "approved-slice-v1",
      slice_id: slice_id,
      prompt: "Implement #{slice_id}.",
      repo: %{
        url: "https://example.test/rondo.git",
        base_ref: "main",
        base_sha: String.duplicate("a", 40)
      }
    }

    manifest_json = Jason.encode!(manifest)
    manifest_path = Path.join(slices_dir, "#{slice_id}.json")
    File.write!(manifest_path, manifest_json)
    File.write!(Path.join(slices_dir, "#{slice_id}.md"), "# #{slice_id}\n")

    bundle = %{
      kind: "approved-slice-plan-export-v0",
      version: 1,
      status: "approved",
      generated_from: "test",
      source_work_contract: "test",
      slice_plan: %{},
      children: [%{id: slice_id}],
      dependency_graph: %{slice_id => []},
      proof_requirements: [],
      guides_and_gates: %{},
      approval: %{
        approved_at: "2026-07-09T12:00:00Z",
        approved_by: "Rondo Test",
        verdicts: %{slice_id => "approve"}
      },
      runner_extensions: %{},
      validation: %{
        schema_version: "approved-slice-plan-export-v0",
        rubric_version: "afk-rubric-v1"
      },
      ownership: %{},
      supersedes: nil
    }

    File.write!(Path.join(bundle_dir, "bundle.json"), Jason.encode!(bundle))

    %{
      manifest_path: manifest_path,
      digest: sha256(manifest_json)
    }
  end

  defp request(export, repo_id) do
    %{
      manifest_path: export.manifest_path,
      manifest_sha256: export.digest,
      repo_id: repo_id
    }
  end

  defp sha256(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
  end

  defp execution_identity(repo_id, digest), do: sha256(repo_id <> <<0>> <> digest)

  defp execution_identifier(repo_id, digest),
    do: "execution-request-#{execution_identity(repo_id, digest)}"

  defp strict_descendant?(path, root) do
    {:ok, canonical_path} = Rondo.PathSafety.canonicalize(path)
    {:ok, canonical_root} = Rondo.PathSafety.canonicalize(root)
    canonical_path != canonical_root and String.starts_with?(canonical_path, canonical_root <> "/")
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:rondo, key)
  defp restore_application_env(key, value), do: Application.put_env(:rondo, key, value)

  defp stop_orchestrator(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  defp unique_name(suffix), do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")

  defp tmp_dir(name) do
    {:ok, canonical_tmp} = Rondo.PathSafety.canonicalize(System.tmp_dir!())

    path =
      Path.join(
        canonical_tmp,
        "rondo-#{name}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      nil -> retry_eventually(fun, attempts)
      false -> retry_eventually(fun, attempts)
      value -> value
    end
  end

  defp eventually(_fun, 0), do: flunk("timed out waiting for condition")

  defp retry_eventually(fun, attempts) do
    Process.sleep(25)
    eventually(fun, attempts - 1)
  end
end
