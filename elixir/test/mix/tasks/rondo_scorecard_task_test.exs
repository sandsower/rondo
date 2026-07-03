defmodule Mix.Tasks.Rondo.ScorecardTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Rondo.Scorecard

  setup do
    Mix.Task.reenable("rondo.scorecard")
    :ok
  end

  test "prints a human-readable summary by default" do
    output =
      capture_io(fn ->
        assert :ok = Scorecard.run(["--workspace-root", fixture_path("healthy")])
      end)

    assert output =~ "Rondo run scorecard"
    assert output =~ "runs_total: 2"
    assert output =~ "clean_eval:"
    assert output =~ "pass=2 fail=0 error=0 skipped=0 rate=1.0"
    assert output =~ "unit: pass=2"
    assert output =~ "claude_code: runs=1 completed=1 failed=0"
    assert output =~ "escalations: 0"
  end

  test "prints JSON when --json is given" do
    output =
      capture_io(fn ->
        assert :ok = Scorecard.run(["--workspace-root", fixture_path("gate_failed"), "--json"])
      end)

    decoded = Jason.decode!(output)
    assert decoded["runs_total"] == 1
    assert decoded["escalations"] == 1
  end

  test "prints the empty-run placeholders when there is nothing to report" do
    workspace_root = tmp_dir("scorecard-task-empty")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    output =
      capture_io(fn ->
        assert :ok = Scorecard.run(["--workspace-root", workspace_root])
      end)

    assert output =~ "runs_total: 0"
    assert output =~ "gates:\n  (none)"
    assert output =~ "adapters:\n  (none)"
  end

  test "defaults workspace_root to configuration when the flag is omitted" do
    output =
      capture_io(fn ->
        assert :ok = Scorecard.run([])
      end)

    assert output =~ "Rondo run scorecard"
    assert output =~ "workspace_root: #{Path.expand(Rondo.Config.workspace_root())}"
  end

  defp fixture_path(name), do: Path.join([File.cwd!(), "test", "fixtures", "scorecard", name])

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(path)
    path
  end
end
