defmodule Rondo.FinalReportTest do
  use ExUnit.Case, async: true

  alias Rondo.FinalReport

  @valid_report %{
    "schema" => "rondo.final_report/v0",
    "summary" => "Implemented the artifact contract",
    "changed_files" => ["lib/rondo/run_ledger.ex"],
    "gates_run" => [%{"name" => "elixir-ci", "status" => "pass"}],
    "failures" => [],
    "risks" => [%{"severity" => "low", "description" => "schema may evolve"}],
    "next_state" => "ready_for_review"
  }

  test "exposes the schema identifier" do
    assert FinalReport.schema() == "rondo.final_report/v0"
  end

  test "accepts a valid decoded report map" do
    assert {:ok, @valid_report} = FinalReport.extract(@valid_report)
  end

  test "accepts a raw JSON string report" do
    assert {:ok, report} = @valid_report |> Jason.encode!() |> FinalReport.extract()
    assert report["summary"] == "Implemented the artifact contract"
  end

  test "extracts a fenced json block from free-form text" do
    text = """
    All done! Summary below.

    ```json
    #{Jason.encode!(@valid_report)}
    ```

    Let me know if anything else is needed.
    """

    assert {:ok, report} = FinalReport.extract(text)
    assert report["next_state"] == "ready_for_review"
  end

  test "prefers a validating json block over other JSON candidates" do
    other = Map.put(@valid_report, "summary", "valid block wins")

    text = """
    ```json
    {"not": "a report"}
    ```
    ```json
    #{Jason.encode!(other)}
    ```
    """

    assert {:ok, %{"summary" => "valid block wins"}} = FinalReport.extract(text)

    # a trailing unrelated JSON block cannot shadow an earlier valid report
    reversed = """
    ```json
    #{Jason.encode!(other)}
    ```
    ```json
    {"not": "a report"}
    ```
    """

    assert {:ok, %{"summary" => "valid block wins"}} = FinalReport.extract(reversed)
  end

  test "prefers the last fenced json block when several reports validate" do
    first = Map.put(@valid_report, "summary", "first report")
    last = Map.put(@valid_report, "summary", "last report")

    text = """
    ```json
    #{Jason.encode!(first)}
    ```
    ```json
    #{Jason.encode!(last)}
    ```
    """

    assert {:ok, %{"summary" => "last report"}} = FinalReport.extract(text)
  end

  test "reports validation errors when no candidate validates" do
    text = """
    ```json
    {"schema": "rondo.final_report/v0"}
    ```
    ```json
    {"not": "a report"}
    ```
    """

    assert {:error, {:invalid, errors}} = FinalReport.extract(text)
    assert Enum.any?(errors, &(&1 =~ "summary must be a non-empty string"))
  end

  test "classifies prose, nil, and non-string input as missing" do
    assert {:error, :missing} = FinalReport.extract("I finished the work, all gates pass.")
    assert {:error, :missing} = FinalReport.extract(nil)
    assert {:error, :missing} = FinalReport.extract("")
    assert {:error, :missing} = FinalReport.extract(123)
    assert {:error, :missing} = FinalReport.extract("```json\nnot json at all\n```")
  end

  test "rejects reports with the wrong schema" do
    assert {:error, {:invalid, errors}} = FinalReport.extract(Map.put(@valid_report, "schema", "rondo.final_report/v1"))
    assert Enum.any?(errors, &(&1 =~ "schema must be"))
  end

  test "rejects reports with missing or mistyped fields" do
    assert {:error, {:invalid, errors}} = FinalReport.extract(%{"schema" => "rondo.final_report/v0"})

    assert Enum.any?(errors, &(&1 =~ "summary must be a non-empty string"))
    assert Enum.any?(errors, &(&1 =~ "changed_files must be a list of strings"))
    assert Enum.any?(errors, &(&1 =~ "gates_run must be a list"))
    assert Enum.any?(errors, &(&1 =~ "failures must be a list"))
    assert Enum.any?(errors, &(&1 =~ "risks must be a list"))
    assert Enum.any?(errors, &(&1 =~ "next_state must be a non-empty string"))
  end

  test "rejects blank summary and mixed changed_files entries" do
    report =
      @valid_report
      |> Map.put("summary", "   ")
      |> Map.put("changed_files", ["lib/ok.ex", 42])

    assert {:error, {:invalid, errors}} = FinalReport.validate(report)
    assert "summary must be a non-empty string" in errors
    assert "changed_files must be a list of strings" in errors
  end

  test "ignores JSON arrays when looking for a report object" do
    assert {:error, :missing} = FinalReport.extract("[1, 2, 3]")
  end

  test "disposition continues valid reports with active next_state" do
    report = Map.put(@valid_report, "next_state", "In Progress")

    assert %{
             action: :continue,
             status: :valid,
             next_state: "In Progress",
             reason: :active_next_state
           } = FinalReport.disposition(report, active_states: ["Todo", "In Progress"])
  end

  test "disposition stops valid reports with terminal next_state" do
    assert %{
             action: :stop,
             status: :valid,
             next_state: "ready_for_review",
             reason: :terminal_next_state
           } = FinalReport.disposition(@valid_report, active_states: ["Todo", "In Progress"])
  end

  test "disposition pauses obvious textual blocked reports that are not schema json" do
    text = """
    Blocked: .venv/bin/python scripts/claude_sandbox_smoke.py still fails due external auth.
    next_state: blocked
    """

    assert %{
             action: :pause,
             status: :missing,
             inferred_next_state: "blocked",
             reason: :blocked_state_unparsed,
             text: inferred_text
           } = FinalReport.disposition(text, active_states: ["Todo", "In Progress"])

    assert inferred_text =~ "next_state: blocked"

    assert %{action: :pause, status: :missing, inferred_next_state: "blocked"} =
             FinalReport.disposition(~s({"next_state": "blocked"))
  end

  test "disposition stops textual terminal reports that are not schema json" do
    assert %{action: :stop, status: :missing, inferred_next_state: "ready_for_review"} =
             FinalReport.disposition("All done\nnext_state: ready for review")

    assert %{action: :stop, status: :missing, inferred_next_state: "completed"} =
             FinalReport.disposition("next_state: completed")

    assert %{action: :stop, status: :missing, inferred_next_state: "completed"} =
             FinalReport.disposition("next_state: complete")

    assert %{action: :stop, status: :missing, inferred_next_state: "done"} =
             FinalReport.disposition("next_state: done")

    assert %{action: :stop, status: :missing, inferred_next_state: "done"} =
             FinalReport.disposition("Done.")

    assert %{action: :stop, status: :missing, inferred_next_state: "ready_for_review"} =
             FinalReport.disposition("Ready for review.")

    assert %{action: :unknown, status: :missing, reason: :missing_report} =
             FinalReport.disposition("I finished the first checklist.\nDone.\nWaiting on more tracker work.")
  end

  test "disposition preserves invalid-report errors when terminal state is inferred" do
    invalid_text = """
    ```json
    {"schema":"rondo.final_report/v0","summary":""}
    ```
    next_state: ready_for_review
    """

    assert %{
             action: :stop,
             status: :invalid,
             reason: :terminal_state_unparsed,
             inferred_next_state: "ready_for_review",
             errors: errors
           } = FinalReport.disposition(invalid_text)

    assert Enum.any?(errors, &(&1 =~ "summary must be"))

    assert %{action: :pause, status: :invalid, inferred_next_state: "blocked", errors: map_errors} =
             FinalReport.disposition(%{"schema" => "rondo.final_report/v0", "next_state" => "blocked"})

    assert Enum.any?(map_errors, &(&1 =~ "summary must be"))

    assert %{action: :stop, status: :invalid, inferred_next_state: "ready_for_review"} =
             FinalReport.disposition(%{"schema" => "rondo.final_report/v0", "next_state" => "ready_for_review"})
  end

  test "disposition returns unknown for missing or invalid reports without textual state" do
    assert %{action: :unknown, status: :missing, reason: :missing_report} = FinalReport.disposition(nil)
    assert %{action: :unknown, status: :missing, reason: :missing_report} = FinalReport.disposition("plain prose")

    assert %{action: :unknown, status: :invalid, reason: :invalid_report, errors: errors} =
             FinalReport.disposition(%{"schema" => "rondo.final_report/v0"})

    assert Enum.any?(errors, &(&1 =~ "summary must be"))

    assert %{action: :unknown, status: :invalid, reason: :invalid_report} =
             FinalReport.disposition(%{"schema" => "rondo.final_report/v0", "next_state" => "In Progress"})
  end

  test "disposition handles non-list and non-string state inputs conservatively" do
    active_report = Map.put(@valid_report, "next_state", "In Progress")

    assert %{action: :stop, reason: :terminal_next_state} =
             FinalReport.disposition(active_report, active_states: "In Progress")

    assert %{action: :continue, reason: :active_next_state} =
             FinalReport.disposition(active_report, active_states: [:"In Progress"])
  end
end
