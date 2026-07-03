defmodule Rondo.RunScorecardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Rondo.RunScorecard

  @generated_at ~U[2026-06-05 00:00:00Z]

  test "aggregates a healthy workspace across two adapters with all-pass outcomes" do
    scorecard = RunScorecard.build(workspace_root: fixture_path("healthy"), now: @generated_at)

    assert scorecard.generated_at == "2026-06-05T00:00:00Z"
    assert scorecard.workspace_root == Path.expand(fixture_path("healthy"))
    assert scorecard.runs_total == 2
    assert scorecard.runs_skipped_unreadable == 0
    assert scorecard.clean_eval == %{pass: 2, fail: 0, error: 0, skipped: 0, rate: 1.0}

    assert scorecard.gates == [
             %{name: "lint", pass: 2, fail: 0, error: 0, timeout: 0, rate: 1.0},
             %{name: "unit", pass: 2, fail: 0, error: 0, timeout: 0, rate: 1.0}
           ]

    assert scorecard.adapters == [
             %{name: "claude_code", runs: 1, completed: 1, failed: 0},
             %{name: "codex", runs: 1, completed: 1, failed: 0}
           ]

    assert scorecard.final_report == %{valid: 2, invalid: 0, missing: 0}
    assert scorecard.escalations == 0
  end

  test "surfaces gate failures, a fresh gate status, a malformed gate entry, and an escalation" do
    scorecard = RunScorecard.build(workspace_root: fixture_path("gate_failed"))

    assert scorecard.runs_total == 1
    assert scorecard.runs_skipped_unreadable == 0
    assert scorecard.clean_eval == %{pass: 0, fail: 1, error: 0, skipped: 0, rate: 0.0}

    assert scorecard.gates == [
             %{name: "format", pass: 0, fail: 0, error: 0, timeout: 0, rate: 0.0},
             %{name: "lint", pass: 1, fail: 0, error: 0, timeout: 0, rate: 1.0},
             %{name: "unit", pass: 0, fail: 1, error: 0, timeout: 0, rate: 0.0}
           ]

    assert scorecard.adapters == [%{name: "claude_code", runs: 1, completed: 0, failed: 1}]
    assert scorecard.final_report == %{valid: 0, invalid: 1, missing: 0}
    assert scorecard.escalations == 1
  end

  test "counts a skipped clean eval and tolerates dangling and pathless gate-results artifact links" do
    scorecard = RunScorecard.build(workspace_root: fixture_path("clean_eval_skipped"))

    assert scorecard.runs_total == 1
    assert scorecard.runs_skipped_unreadable == 0
    assert scorecard.clean_eval == %{pass: 0, fail: 0, error: 0, skipped: 1, rate: 0.0}
    assert scorecard.gates == []
    assert scorecard.adapters == [%{name: "claude_code", runs: 1, completed: 1, failed: 0}]
    assert scorecard.final_report == %{valid: 0, invalid: 0, missing: 0}
    assert scorecard.escalations == 0
  end

  test "skips unreadable manifests (invalid JSON and invalid schema shape) but keeps the readable run" do
    log =
      capture_log(fn ->
        scorecard = RunScorecard.build(workspace_root: fixture_path("unreadable_manifest"))

        assert scorecard.runs_total == 3
        assert scorecard.runs_skipped_unreadable == 2
        assert scorecard.adapters == [%{name: "claude_code", runs: 1, completed: 1, failed: 0}]
        assert scorecard.final_report == %{valid: 1, invalid: 0, missing: 0}
        assert scorecard.escalations == 0

        assert scorecard.gates == [
                 %{name: "unit", pass: 1, fail: 0, error: 0, timeout: 0, rate: 1.0}
               ]
      end)

    assert log =~ "rondo.scorecard: skipping unreadable ledger"
  end

  test "returns a zeroed scorecard for a workspace root with no runs" do
    workspace_root = tmp_dir("scorecard-empty")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    scorecard = RunScorecard.build(workspace_root: workspace_root)

    assert scorecard.runs_total == 0
    assert scorecard.runs_skipped_unreadable == 0
    assert scorecard.clean_eval == %{pass: 0, fail: 0, error: 0, skipped: 0, rate: 0.0}
    assert scorecard.gates == []
    assert scorecard.adapters == []
    assert scorecard.final_report == %{valid: 0, invalid: 0, missing: 0}
    assert scorecard.escalations == 0
  end

  test "build/1 defaults workspace_root to Rondo.Config.workspace_root/0" do
    scorecard = RunScorecard.build()
    assert scorecard.workspace_root == Path.expand(Rondo.Config.workspace_root())
  end

  test "to_json/1 encodes the scorecard with string keys" do
    scorecard = RunScorecard.build(workspace_root: fixture_path("healthy"), now: @generated_at)
    decoded = scorecard |> RunScorecard.to_json() |> Jason.decode!()

    assert decoded["runs_total"] == 2
    assert decoded["generated_at"] == "2026-06-05T00:00:00Z"
    assert decoded["clean_eval"]["pass"] == 2
    assert Enum.map(decoded["gates"], & &1["name"]) == ["lint", "unit"]
  end

  defp fixture_path(name), do: Path.join([File.cwd!(), "test", "fixtures", "scorecard", name])

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(path)
    path
  end
end
