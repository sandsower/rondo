defmodule Rondo.Core.RunLocatorTest do
  use Rondo.TestSupport

  alias Rondo.Core.RunLocator
  alias Rondo.PathSafety
  alias Rondo.RunLedger

  @now ~U[2026-05-10 15:30:00Z]
  @source_sha String.duplicate("a", 64)

  test "locates an exact repository and run from the durable ledger manifest" do
    root = tmp_dir("run-locator-exact")
    ledger = build_run(root, "repo-a", source_sha: @source_sha)

    assert {:ok, located} = RunLocator.locate("repo-a", ledger.run_id, workspace_root: root)
    assert canonical_path(located.run_dir) == canonical_path(ledger.run_dir)
    assert located.manifest["run_id"] == ledger.run_id
    assert located.manifest["repo"]["repo_id"] == "repo-a"
  end

  test "requires the stored repository id to match the requested namespace" do
    root = tmp_dir("run-locator-repo")
    ledger = build_run(root, "repo-a")

    assert {:error, :run_not_found} =
             RunLocator.locate("repo-b", ledger.run_id, workspace_root: root)
  end

  test "rejects malformed identifiers while treating reserved characters as opaque" do
    root = tmp_dir("run-locator-identifiers")
    ledger = build_run(root, "repo-*?[opaque]")

    assert {:error, :missing_repo_id} = RunLocator.locate(nil, "run-1", workspace_root: root)
    assert {:error, :invalid_repo_id} = RunLocator.locate("  ", "run-1", workspace_root: root)

    assert {:error, :invalid_repo_id} =
             RunLocator.locate(String.duplicate("r", 513), "run-1", workspace_root: root)

    assert {:error, :missing_run_id} = RunLocator.locate("repo-a", nil, workspace_root: root)
    assert {:error, :invalid_run_id} = RunLocator.locate("repo-a", "", workspace_root: root)

    assert {:error, :invalid_run_id} =
             RunLocator.locate("repo-a", String.duplicate("r", 513), workspace_root: root)

    assert {:ok, located} =
             RunLocator.locate("repo-*?[opaque]", ledger.run_id, workspace_root: root)

    assert located.manifest["run_id"] == ledger.run_id
  end

  test "does not accept a matching path whose manifest identity disagrees" do
    root = tmp_dir("run-locator-manifest-identity")
    ledger = build_run(root, "repo-a")
    rewrite_manifest(ledger, &put_in(&1, ["run_id"], "different-run"))

    assert {:error, :run_not_found} =
             RunLocator.locate("repo-a", ledger.run_id, workspace_root: root)
  end

  test "does not follow run-directory symlinks outside the configured ledger root" do
    root = tmp_dir("run-locator-symlink-root")
    outside_root = tmp_dir("run-locator-symlink-outside")
    outside = build_run(outside_root, "repo-a")
    identifier_dir = Path.join([root, ".rondo_runs", "ATTACK"])
    File.mkdir_p!(identifier_dir)
    File.ln_s!(outside.run_dir, Path.join(identifier_dir, outside.run_id))

    assert {:error, :run_not_found} =
             RunLocator.locate("repo-a", outside.run_id, workspace_root: root)
  end

  test "does not relabel a relocated manifest's physical event directory" do
    root = tmp_dir("run-locator-relocated-root")
    outside_root = tmp_dir("run-locator-relocated-source")
    outside = build_run(outside_root, "repo-a")
    relocated = Path.join([root, ".rondo_runs", "RELOCATED", outside.run_id])

    File.mkdir_p!(Path.join(relocated, "artifacts"))
    File.cp!(outside.manifest_path, Path.join(relocated, "manifest.json"))

    File.write!(
      Path.join(relocated, "artifacts/agent-events.ndjson"),
      Jason.encode!(%{
        "schema" => "rondo.events/v0",
        "timestamp" => "2026-05-10T15:30:01Z",
        "raw" => %{
          "artifacts" => [
            %{"kind" => "relocated", "path" => "artifacts/relocated.json"}
          ]
        }
      }) <> "\n"
    )

    assert {:error, :run_not_found} =
             RunLocator.locate("repo-a", outside.run_id, workspace_root: root)
  end

  test "finds only accepted execution-request runs by repository and source contract sha256" do
    root = tmp_dir("run-locator-source")
    accepted = build_run(root, "repo-a", source_sha: @source_sha, admission: :accepted)
    _rejected = build_run(root, "repo-b", source_sha: @source_sha, admission: :rejected)
    _tracker = build_run(root, "repo-c", source_sha: @source_sha)

    assert {:ok, located} =
             RunLocator.find_accepted_by_source_sha256("repo-a", @source_sha, workspace_root: root)

    assert canonical_path(located.run_dir) == canonical_path(accepted.run_dir)
    assert located.manifest["source_contract"]["sha256"] == @source_sha

    assert {:ok, nil} =
             RunLocator.find_accepted_by_source_sha256("repo-b", @source_sha, workspace_root: root)

    assert {:ok, nil} =
             RunLocator.find_accepted_by_source_sha256("repo-c", @source_sha, workspace_root: root)
  end

  test "finds accepted execution requests only in the exact Plot namespace" do
    root = tmp_dir("run-locator-plot-source")
    legacy = build_run(root, "repo-a", source_sha: @source_sha, admission: :accepted)

    plot_a =
      build_run(root, "repo-a",
        source_sha: @source_sha,
        admission: :accepted,
        plot_id: "OLI-52"
      )

    plot_b =
      build_run(root, "repo-a",
        source_sha: @source_sha,
        admission: :accepted,
        plot_id: "OLI-foreign"
      )

    assert {:ok, legacy_match} =
             RunLocator.find_accepted_by_source_sha256(
               "repo-a",
               @source_sha,
               workspace_root: root
             )

    assert canonical_path(legacy_match.run_dir) == canonical_path(legacy.run_dir)

    assert {:ok, plot_a_match} =
             RunLocator.find_accepted_by_source_sha256(
               "repo-a",
               @source_sha,
               workspace_root: root,
               plot_id: "OLI-52"
             )

    assert canonical_path(plot_a_match.run_dir) == canonical_path(plot_a.run_dir)

    assert {:ok, plot_b_match} =
             RunLocator.find_accepted_by_source_sha256(
               "repo-a",
               @source_sha,
               workspace_root: root,
               plot_id: "OLI-foreign"
             )

    assert canonical_path(plot_b_match.run_dir) == canonical_path(plot_b.run_dir)

    assert {:ok, nil} =
             RunLocator.find_accepted_by_source_sha256(
               "repo-a",
               @source_sha,
               workspace_root: root,
               plot_id: "OLI-missing"
             )
  end

  test "accepted-source dedupe fails closed on a corrupt durable ledger" do
    root = tmp_dir("run-locator-corrupt-dedupe")
    accepted = build_run(root, "repo-a", source_sha: @source_sha, admission: :accepted)
    File.write!(accepted.manifest_path, "{not json")

    assert {:error, {:invalid_run_ledger, canonical_run_dir, :invalid_json}} =
             RunLocator.find_accepted_by_source_sha256(
               "repo-a",
               @source_sha,
               workspace_root: root
             )

    assert canonical_path(canonical_run_dir) == canonical_path(accepted.run_dir)
  end

  test "validates source contract sha256 before scanning the ledger" do
    root = tmp_dir("run-locator-source-validation")

    assert {:error, :missing_source_contract_sha256} =
             RunLocator.find_accepted_by_source_sha256("repo-a", nil, workspace_root: root)

    assert {:error, :invalid_source_contract_sha256} =
             RunLocator.find_accepted_by_source_sha256("repo-a", "*", workspace_root: root)

    assert {:error, :invalid_source_contract_sha256} =
             RunLocator.find_accepted_by_source_sha256(
               "repo-a",
               String.duplicate("A", 64),
               workspace_root: root
             )
  end

  defp build_run(root, repo_id, opts \\ []) do
    issue = %{
      id: "issue-#{repo_id}",
      identifier: "RON-#{System.unique_integer([:positive])}",
      title: "Locator fixture",
      state: "In Progress"
    }

    source_contract =
      case Keyword.get(opts, :source_sha) do
        nil -> nil
        sha256 -> %{schema: "approved-slice-v1", slice_id: "slice-a", sha256: sha256}
      end

    ledger_opts = [
      workspace_root: root,
      repo_id: repo_id,
      now: @now,
      random_suffix: random_suffix(),
      source_contract: source_contract
    ]

    ledger_opts =
      case Keyword.get(opts, :admission) do
        phase when phase in [:accepted, :rejected] ->
          ledger_opts ++
            [
              run_source: "execution_request",
              execution_request_admission: %{
                repo_id: repo_id,
                manifest_sha256: Keyword.fetch!(opts, :source_sha),
                plot_id: Keyword.get(opts, :plot_id)
              }
            ]

        _other ->
          ledger_opts
      end

    {:ok, ledger} = RunLedger.create_run(issue, ledger_opts)

    ledger =
      case Keyword.get(opts, :admission) do
        :accepted ->
          {:ok, accepted} =
            RunLedger.accept_execution_request(ledger, %{
              repo_id: repo_id,
              manifest_sha256: Keyword.fetch!(opts, :source_sha),
              plot_id: Keyword.get(opts, :plot_id)
            })

          accepted

        :rejected ->
          {:ok, rejected} =
            RunLedger.reject_execution_request(ledger, "test_rejection")

          rejected

        _other ->
          ledger
      end

    ledger
  end

  defp rewrite_manifest(ledger, update) do
    {:ok, manifest} = RunLedger.load_manifest(ledger.run_dir)
    File.write!(ledger.manifest_path, Jason.encode!(update.(manifest)))
  end

  defp random_suffix do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string(16)
    |> String.pad_leading(8, "0")
    |> String.slice(-8, 8)
  end

  defp canonical_path(path) do
    {:ok, canonical} = PathSafety.canonicalize(path)
    canonical
  end

  defp tmp_dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "rondo-#{name}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
