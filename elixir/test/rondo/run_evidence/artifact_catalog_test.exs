defmodule Rondo.RunEvidence.ArtifactCatalogTest do
  use Rondo.TestSupport

  alias Rondo.RunEvidence.ArtifactCatalog

  test "validates artifact refs" do
    assert ArtifactCatalog.valid?(%{"kind" => "report", "path" => "artifacts/report.json"})
    assert ArtifactCatalog.valid?(%{kind: "report", path: "artifacts/report.json"})
    refute ArtifactCatalog.valid?(%{"kind" => "report"})
  end

  test "normalizes artifact refs and derives present or missing status" do
    run_dir = tmp_dir("artifact-catalog-status")
    File.mkdir_p!(Path.join(run_dir, "artifacts"))
    File.write!(Path.join(run_dir, "artifacts/present.json"), "{}")

    assert %{
             "kind" => "present_thing",
             "path" => "artifacts/present.json",
             "status" => "present"
           } = ArtifactCatalog.normalize(%{kind: "present_thing", path: "artifacts/present.json"}, run_dir)

    assert %{
             "kind" => "missing_thing",
             "path" => "artifacts/missing.json",
             "status" => "missing"
           } = ArtifactCatalog.normalize(%{"kind" => "missing_thing", "path" => "artifacts/missing.json"}, run_dir)

    assert ArtifactCatalog.status(%{}, run_dir) == "missing"
  end

  test "preserves explicit statuses instead of rechecking the filesystem" do
    run_dir = tmp_dir("artifact-catalog-explicit-status")

    for status <- ~w(tracked skipped failed) do
      assert %{"status" => ^status} =
               ArtifactCatalog.normalize(%{"kind" => "explicit", "path" => "artifacts/missing.json", "status" => status}, run_dir)
    end
  end

  test "looks up artifact refs by kind and reports exportability" do
    refs = [
      %{"kind" => "patch", "path" => "artifacts/changes.patch", "exportable" => false},
      %{"kind" => "final_report", "path" => "artifacts/final-report.json"}
    ]

    atom_refs = [%{kind: "agent_events", path: "artifacts/agent-events.ndjson", exportable: false}]

    assert ArtifactCatalog.path(refs, "final_report") == "artifacts/final-report.json"
    assert ArtifactCatalog.path(%{"artifacts" => refs}, :patch) == "artifacts/changes.patch"
    assert ArtifactCatalog.path(%{artifacts: atom_refs}, :agent_events) == "artifacts/agent-events.ndjson"

    assert ArtifactCatalog.find_all(%{"artifacts" => refs ++ [%{"kind" => "final_report", "path" => "copy.json"}]}, :final_report) == [
             %{"kind" => "final_report", "path" => "artifacts/final-report.json"},
             %{"kind" => "final_report", "path" => "copy.json"}
           ]

    assert ArtifactCatalog.path(:not_a_source, :agent_events) == nil
    assert ArtifactCatalog.path([%{"kind" => "bad"}], :bad) == nil
    refute ArtifactCatalog.exportable?(ArtifactCatalog.find(refs, :patch))
    refute ArtifactCatalog.exportable?(ArtifactCatalog.find(atom_refs, :agent_events))
    assert ArtifactCatalog.exportable?(ArtifactCatalog.find(refs, :final_report))
    assert ArtifactCatalog.find(refs, :missing) == nil
  end

  test "upserts artifacts by kind and path identity" do
    recorded_at = "2026-07-09T12:00:00Z"

    existing = [
      %{
        "kind" => "gate_results",
        "path" => "artifacts/gates/results.json",
        "status" => "missing",
        "recorded_at" => recorded_at,
        "old" => true
      },
      %{"kind" => "gate_results", "path" => "artifacts/gates/results.json", "status" => "failed", "duplicate" => true},
      %{"kind" => "gate_results", "path" => "artifacts/gates/other.json", "status" => "present"}
    ]

    updated =
      ArtifactCatalog.upsert(existing, %{
        "kind" => "gate_results",
        "path" => "artifacts/gates/results.json",
        "status" => "present",
        "new" => true
      })

    assert length(updated) == 2

    assert [%{"new" => true, "status" => "present", "recorded_at" => ^recorded_at}] =
             Enum.filter(updated, &(&1["path"] == "artifacts/gates/results.json"))

    refute Enum.any?(updated, &Map.get(&1, "old"))
    refute Enum.any?(updated, &Map.get(&1, "duplicate"))
    assert Enum.any?(updated, &(&1["path"] == "artifacts/gates/other.json"))
  end

  test "upserts into malformed artifact lists defensively" do
    existing = [%{"kind" => "archive", "path" => "archive.json"}]

    assert [%{"kind" => "archive", "path" => "archive.json", "recorded_at" => recorded_at}] =
             ArtifactCatalog.upsert(:not_a_list, %{
               "kind" => "archive",
               "path" => "archive.json"
             })

    assert {:ok, _, 0} = DateTime.from_iso8601(recorded_at)

    assert existing == ArtifactCatalog.upsert(existing, %{"kind" => "bad"})
    assert existing == ArtifactCatalog.upsert(existing, :not_a_map)

    assert [:not_a_ref, %{"kind" => "report", "path" => "artifacts/report.json", "recorded_at" => report_recorded_at}] =
             ArtifactCatalog.upsert([:not_a_ref], %{
               "kind" => "report",
               "path" => "artifacts/report.json"
             })

    assert {:ok, _, 0} = DateTime.from_iso8601(report_recorded_at)

    assert [] == ArtifactCatalog.upsert(:not_a_list, :not_a_map)
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
