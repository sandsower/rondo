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

  test "prefers the last fenced json block" do
    other = Map.put(@valid_report, "summary", "second block wins")

    text = """
    ```json
    {"not": "a report"}
    ```
    ```json
    #{Jason.encode!(other)}
    ```
    """

    assert {:ok, %{"summary" => "second block wins"}} = FinalReport.extract(text)

    reversed = """
    ```json
    #{Jason.encode!(other)}
    ```
    ```json
    {"not": "a report"}
    ```
    """

    assert {:error, {:invalid, _errors}} = FinalReport.extract(reversed)
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
end
