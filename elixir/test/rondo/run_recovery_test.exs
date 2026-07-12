defmodule Rondo.RunRecoveryTest do
  use Rondo.TestSupport

  alias Rondo.Core.RunLocator
  alias Rondo.{Orchestrator, RunLedger, RunRecovery, RunSupervisor, Workflow}

  @now ~U[2026-07-09 12:00:00Z]
  @digest String.duplicate("a", 64)

  test "terminalizes accepted Core and tracker orphan ledgers idempotently" do
    root = tmp_dir("run-recovery-all")
    accepted = execution_ledger(root, "accepted", :accepted)
    tracker = tracker_ledger(root)
    terminal = execution_ledger(root, "terminal", :accepted)
    {:ok, terminal} = RunLedger.complete_run(terminal, :completed, %{reason: "done"})

    assert {:ok, results} =
             RunRecovery.reconcile(
               workspace_root: root,
               worker_supervisor_quiescent: true,
               timestamp: @now
             )

    assert Enum.sort(Enum.map(results, & &1.run_id)) ==
             Enum.sort([accepted.run_id, tracker.run_id])

    for ledger <- [accepted, tracker] do
      assert {:ok, manifest} = RunLedger.load_manifest(ledger.run_dir)
      assert manifest["status"] == "terminated"

      recovery =
        manifest["checkpoints"]
        |> Enum.filter(&(&1["kind"] == "terminated"))
        |> List.last()

      checkpoint = ledger.run_dir |> Path.join(recovery["path"]) |> decode_json!()
      assert checkpoint["payload"]["reason"] == "orchestrator_restart"
      assert checkpoint["source"]["recovery"] == "orchestrator_startup"
    end

    assert {:ok, terminal_manifest} = RunLedger.load_manifest(terminal.run_dir)
    assert terminal_manifest["status"] == "completed"

    assert {:ok, []} =
             RunRecovery.reconcile(
               workspace_root: root,
               worker_supervisor_quiescent: true,
               timestamp: @now
             )

    assert {:ok, accepted_manifest} = RunLedger.load_manifest(accepted.run_dir)

    assert Enum.count(
             accepted_manifest["checkpoints"],
             &(&1["kind"] == "terminated")
           ) == 1
  end

  test "rejects an orphaned unaccepted Core attempt so the digest remains retryable" do
    root = tmp_dir("run-recovery-admitting")
    ledger = execution_ledger(root, "admitting", :admitting)

    assert {:ok, [%{run_id: run_id, status: :recovered}]} =
             RunRecovery.reconcile(
               workspace_root: root,
               worker_supervisor_quiescent: true,
               timestamp: @now
             )

    assert run_id == ledger.run_id
    assert {:ok, manifest} = RunLedger.load_manifest(ledger.run_dir)
    assert manifest["status"] == "terminated"
    assert manifest["admission"]["phase"] == "rejected"
    assert manifest["admission"]["reason"] == "orchestrator_restart"

    assert Enum.any?(
             manifest["checkpoints"],
             &(&1["kind"] == "execution_request_rejected")
           )
  end

  test "reclaims only the recovery lock at a declared quiescent boundary" do
    root = tmp_dir("run-recovery-lock")
    ledger = tracker_ledger(root)
    lock_path = Path.join(ledger.run_dir, ".ledger.lock")
    File.write!(lock_path, DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string())

    assert {:error, :worker_supervisor_not_quiescent} =
             RunRecovery.reconcile(workspace_root: root)

    assert File.exists?(lock_path)

    assert {:ok, [%{run_id: run_id, status: :recovered}]} =
             RunRecovery.reconcile(
               workspace_root: root,
               worker_supervisor_quiescent: true,
               timestamp: @now
             )

    assert run_id == ledger.run_id
    refute File.exists?(lock_path)
  end

  test "surfaces persistence failure instead of skipping a running ledger" do
    root = tmp_dir("run-recovery-failure")
    ledger = tracker_ledger(root)

    assert {:error, {:run_recovery_failed, run_dir, :disk_unavailable}} =
             RunRecovery.reconcile(
               workspace_root: root,
               worker_supervisor_quiescent: true,
               recover_fun: fn _ledger, _opts -> {:error, :disk_unavailable} end
             )

    assert canonical_path(run_dir) == canonical_path(ledger.run_dir)
    assert {:ok, manifest} = RunLedger.load_manifest(ledger.run_dir)
    assert manifest["status"] == "running"
  end

  test "fails closed on a corrupt or symlinked manifest but ignores unadmitted debris" do
    root = tmp_dir("run-recovery-strict-ledgers")
    partial_run = Path.join([root, ".rondo_runs", "PARTIAL", "partial-run"])
    File.mkdir_p!(partial_run)

    assert {:ok, []} =
             RunRecovery.reconcile(
               workspace_root: root,
               worker_supervisor_quiescent: true,
               timestamp: @now
             )

    corrupt_run = Path.join([root, ".rondo_runs", "CORRUPT", "corrupt-run"])
    File.mkdir_p!(corrupt_run)
    File.write!(Path.join(corrupt_run, "manifest.json"), "{not json")

    assert {:error, {:invalid_run_ledger, canonical_corrupt_run, :invalid_json}} =
             RunRecovery.reconcile(
               workspace_root: root,
               worker_supervisor_quiescent: true,
               timestamp: @now
             )

    assert canonical_path(canonical_corrupt_run) == canonical_path(corrupt_run)

    File.rm!(Path.join(corrupt_run, "manifest.json"))
    target = Path.join(root, "outside-manifest.json")
    File.write!(target, "{}")
    File.ln_s!(target, Path.join(corrupt_run, "manifest.json"))

    assert {:error, {:invalid_run_ledger, canonical_corrupt_run, {:manifest_not_regular, :symlink}}} =
             RunRecovery.reconcile(
               workspace_root: root,
               worker_supervisor_quiescent: true,
               timestamp: @now
             )

    assert canonical_path(canonical_corrupt_run) == canonical_path(corrupt_run)
  end

  test "fails closed on symlinked identifier and run directories" do
    root = tmp_dir("run-recovery-symlink-directories")
    run_root = Path.join(root, ".rondo_runs")
    outside = tmp_dir("run-recovery-symlink-directories-outside")
    File.mkdir_p!(run_root)

    identifier_link = Path.join(run_root, "LINKED-IDENTIFIER")
    File.ln_s!(outside, identifier_link)

    assert {:error, {:run_ledger_symlink, ^identifier_link}} =
             RunRecovery.reconcile(
               workspace_root: root,
               worker_supervisor_quiescent: true
             )

    File.rm!(identifier_link)
    identifier_dir = Path.join(run_root, "REAL-IDENTIFIER")
    File.mkdir_p!(identifier_dir)
    run_link = Path.join(identifier_dir, "linked-run")
    File.ln_s!(outside, run_link)

    assert {:error, {:run_ledger_symlink, ^run_link}} =
             RunRecovery.reconcile(
               workspace_root: root,
               worker_supervisor_quiescent: true
             )
  end

  test "one-for-all restart stops owned workers before orphan reconciliation" do
    parent = self()
    root = tmp_dir("run-recovery-one-for-all")
    export = approved_export(root, "restart-owned-worker")
    supervisor_name = unique_name(:RunSupervisor)
    task_supervisor_name = unique_name(:TaskSupervisor)
    orchestrator_name = unique_name(:Orchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      poll_interval_ms: 60_000
    )

    runner = fn _issue, _recipient, _opts ->
      send(parent, {:owned_worker_started, self()})

      receive do
        :stop -> :ok
      end
    end

    {:ok, supervisor} =
      RunSupervisor.start_link(
        name: supervisor_name,
        task_supervisor: task_supervisor_name,
        orchestrator: orchestrator_name,
        orchestrator_opts: [execution_request_runner: runner]
      )

    on_exit(fn ->
      if Process.alive?(supervisor) do
        try do
          Supervisor.stop(supervisor)
        catch
          :exit, _reason -> :ok
        end
      end

      File.rm_rf(root)
    end)

    original_orchestrator = Process.whereis(orchestrator_name)
    original_task_supervisor = Process.whereis(task_supervisor_name)

    assert {:ok, submitted} =
             Orchestrator.submit_execution_request(orchestrator_name, %{
               manifest_path: export.manifest_path,
               manifest_sha256: export.digest,
               repo_id: "repo-restart"
             })

    assert_receive {:owned_worker_started, worker}, 1_000
    worker_ref = Process.monitor(worker)
    task_supervisor_ref = Process.monitor(original_task_supervisor)
    Process.exit(original_orchestrator, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    assert_receive {:DOWN, ^task_supervisor_ref, :process, ^original_task_supervisor, _reason},
                   2_000

    replacement_orchestrator =
      eventually(fn ->
        case Process.whereis(orchestrator_name) do
          pid when is_pid(pid) and pid != original_orchestrator -> pid
          _other -> nil
        end
      end)

    replacement_task_supervisor = Process.whereis(task_supervisor_name)
    assert is_pid(replacement_orchestrator)
    assert is_pid(replacement_task_supervisor)
    refute replacement_task_supervisor == original_task_supervisor
    _initialized_state = :sys.get_state(replacement_orchestrator)

    assert {:ok, located} =
             RunLocator.locate(
               "repo-restart",
               submitted.run_id,
               workspace_root: root
             )

    assert located.manifest["status"] == "terminated"

    recovery_checkpoint =
      located.manifest["checkpoints"]
      |> Enum.filter(&(&1["kind"] == "terminated"))
      |> List.last()

    checkpoint =
      located.run_dir
      |> Path.join(recovery_checkpoint["path"])
      |> decode_json!()

    assert checkpoint["payload"]["reason"] == "orchestrator_restart"
  end

  test "task-supervisor sibling crash defers terminalization until quiescent restart recovery" do
    parent = self()
    root = tmp_dir("run-recovery-task-supervisor-crash")
    export = approved_export(root, "restart-task-supervisor")
    supervisor_name = unique_name(:RunSupervisor)
    task_supervisor_name = unique_name(:TaskSupervisor)
    orchestrator_name = unique_name(:Orchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      poll_interval_ms: 60_000
    )

    runner = fn _issue, _recipient, _opts ->
      send(parent, {:sibling_owned_worker_started, self()})

      receive do
        :stop -> :ok
      end
    end

    {:ok, supervisor} =
      RunSupervisor.start_link(
        name: supervisor_name,
        task_supervisor: task_supervisor_name,
        orchestrator: orchestrator_name,
        orchestrator_opts: [execution_request_runner: runner]
      )

    on_exit(fn ->
      if Process.alive?(supervisor) do
        try do
          Supervisor.stop(supervisor)
        catch
          :exit, _reason -> :ok
        end
      end

      File.rm_rf(root)
    end)

    original_orchestrator = Process.whereis(orchestrator_name)
    original_task_supervisor = Process.whereis(task_supervisor_name)
    orchestrator_ref = Process.monitor(original_orchestrator)

    assert {:ok, submitted} =
             Orchestrator.submit_execution_request(orchestrator_name, %{
               manifest_path: export.manifest_path,
               manifest_sha256: export.digest,
               repo_id: "repo-task-supervisor-restart"
             })

    assert_receive {:sibling_owned_worker_started, worker}, 1_000
    worker_ref = Process.monitor(worker)
    Process.exit(original_task_supervisor, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000
    assert_receive {:DOWN, ^orchestrator_ref, :process, ^original_orchestrator, _reason}, 2_000

    replacement_orchestrator =
      eventually(fn ->
        case Process.whereis(orchestrator_name) do
          pid when is_pid(pid) and pid != original_orchestrator -> pid
          _other -> nil
        end
      end)

    replacement_task_supervisor = Process.whereis(task_supervisor_name)
    assert is_pid(replacement_orchestrator)
    assert is_pid(replacement_task_supervisor)
    refute replacement_task_supervisor == original_task_supervisor
    _initialized_state = :sys.get_state(replacement_orchestrator)

    assert {:ok, located} =
             RunLocator.locate(
               "repo-task-supervisor-restart",
               submitted.run_id,
               workspace_root: root
             )

    assert located.manifest["status"] == "terminated"

    terminal_checkpoints =
      Enum.filter(located.manifest["checkpoints"], fn checkpoint ->
        checkpoint["kind"] in ["completed", "failed", "terminated"]
      end)

    assert [terminal_checkpoint] = terminal_checkpoints

    checkpoint =
      located.run_dir
      |> Path.join(terminal_checkpoint["path"])
      |> decode_json!()

    assert terminal_checkpoint["kind"] == "terminated"
    assert checkpoint["payload"]["reason"] == "orchestrator_restart"

    refute Enum.any?(located.manifest["checkpoints"], fn checkpoint ->
             checkpoint["kind"] == "run_decision"
           end)
  end

  test "orchestrator callback crash defers terminalization until quiescent restart recovery" do
    parent = self()
    root = tmp_dir("run-recovery-orchestrator-callback-crash")
    export = approved_export(root, "restart-orchestrator-callback")
    supervisor_name = unique_name(:RunSupervisor)
    task_supervisor_name = unique_name(:TaskSupervisor)
    orchestrator_name = unique_name(:Orchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      poll_interval_ms: 60_000
    )

    runner = fn _issue, _recipient, _opts ->
      send(parent, {:callback_crash_worker_started, self()})

      receive do
        :stop -> :ok
      end
    end

    {:ok, supervisor} =
      RunSupervisor.start_link(
        name: supervisor_name,
        task_supervisor: task_supervisor_name,
        orchestrator: orchestrator_name,
        orchestrator_opts: [execution_request_runner: runner]
      )

    on_exit(fn ->
      if Process.alive?(supervisor) do
        try do
          Supervisor.stop(supervisor)
        catch
          :exit, _reason -> :ok
        end
      end

      File.rm_rf(root)
    end)

    original_orchestrator = Process.whereis(orchestrator_name)
    original_task_supervisor = Process.whereis(task_supervisor_name)

    assert {:ok, submitted} =
             Orchestrator.submit_execution_request(orchestrator_name, %{
               manifest_path: export.manifest_path,
               manifest_sha256: export.digest,
               repo_id: "repo-orchestrator-callback-restart"
             })

    assert_receive {:callback_crash_worker_started, worker}, 1_000
    worker_ref = Process.monitor(worker)
    task_supervisor_ref = Process.monitor(original_task_supervisor)

    assert catch_exit(GenServer.call(orchestrator_name, :unexpected_callback_message))

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    assert_receive {:DOWN, ^task_supervisor_ref, :process, ^original_task_supervisor, _reason},
                   2_000

    replacement_orchestrator =
      eventually(fn ->
        case Process.whereis(orchestrator_name) do
          pid when is_pid(pid) and pid != original_orchestrator -> pid
          _other -> nil
        end
      end)

    assert is_pid(replacement_orchestrator)
    _initialized_state = :sys.get_state(replacement_orchestrator)

    assert {:ok, located} =
             RunLocator.locate(
               "repo-orchestrator-callback-restart",
               submitted.run_id,
               workspace_root: root
             )

    terminal_checkpoints =
      Enum.filter(located.manifest["checkpoints"], fn checkpoint ->
        checkpoint["kind"] in ["completed", "failed", "terminated"]
      end)

    assert [terminal_checkpoint] = terminal_checkpoints
    assert terminal_checkpoint["kind"] == "terminated"

    checkpoint =
      located.run_dir
      |> Path.join(terminal_checkpoint["path"])
      |> decode_json!()

    assert checkpoint["payload"]["reason"] == "orchestrator_restart"

    refute Enum.any?(located.manifest["checkpoints"], fn checkpoint ->
             checkpoint["kind"] == "run_decision"
           end)
  end

  defp execution_ledger(root, suffix, phase) do
    issue = issue("CORE-#{suffix}")

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        now: @now,
        random_suffix: String.pad_trailing(suffix, 8, "0") |> String.slice(0, 8),
        run_source: "execution_request",
        repo_id: "repo-#{suffix}",
        source_contract: %{sha256: @digest},
        execution_request_admission: %{
          repo_id: "repo-#{suffix}",
          manifest_sha256: @digest
        }
      )

    case phase do
      :accepted ->
        {:ok, ledger} =
          RunLedger.accept_execution_request(ledger, %{
            repo_id: "repo-#{suffix}",
            manifest_sha256: @digest
          })

        ledger

      :admitting ->
        ledger
    end
  end

  defp tracker_ledger(root) do
    {:ok, ledger} =
      RunLedger.create_run(issue("TRACKER"),
        workspace_root: root,
        now: @now,
        random_suffix: "tracker0"
      )

    ledger
  end

  defp issue(identifier) do
    %{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Recovery fixture",
      state: "In Progress"
    }
  end

  defp decode_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp canonical_path(path) do
    {:ok, canonical} = Rondo.PathSafety.canonicalize(path)
    canonical
  end

  defp approved_export(root, slice_id) do
    bundle_dir = Path.join(root, "export-#{slice_id}")
    slices_dir = Path.join(bundle_dir, "slices")
    File.mkdir_p!(slices_dir)

    manifest_json =
      Jason.encode!(%{
        schema: "approved-slice-v1",
        slice_id: slice_id,
        prompt: "Implement #{slice_id}.",
        repo: %{
          url: "https://example.test/rondo.git",
          base_ref: "main",
          base_sha: String.duplicate("a", 40)
        }
      })

    manifest_path = Path.join(slices_dir, "#{slice_id}.json")
    File.write!(manifest_path, manifest_json)
    File.write!(Path.join(slices_dir, "#{slice_id}.md"), "# #{slice_id}\n")

    File.write!(
      Path.join(bundle_dir, "bundle.json"),
      Jason.encode!(%{
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
          approved_by: "Rondo Test"
        },
        runner_extensions: %{},
        validation: %{
          schema_version: "approved-slice-plan-export-v0",
          rubric_version: "afk-rubric-v1"
        },
        ownership: %{},
        supersedes: nil
      })
    )

    %{
      manifest_path: manifest_path,
      digest: sha256(manifest_json)
    }
  end

  defp sha256(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
  end

  defp unique_name(suffix),
    do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")

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

  defp tmp_dir(name) do
    {:ok, canonical_tmp} = Rondo.PathSafety.canonicalize(System.tmp_dir!())

    path =
      Path.join(
        canonical_tmp,
        "rondo-#{name}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
