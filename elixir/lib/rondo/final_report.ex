defmodule Rondo.FinalReport do
  @moduledoc """
  Extraction and validation for the `rondo.final_report/v0` schema.

  Adapters surface a free-form final report (usually the agent's last message).
  Agent-agnostic automation needs a machine-readable report, so the final
  report is expected to contain a JSON object — either the whole string or a
  fenced ```json block — with this shape:

      {
        "schema": "rondo.final_report/v0",
        "summary": "what was done",
        "changed_files": ["lib/foo.ex"],
        "gates_run": [{"name": "elixir-ci", "status": "pass"}],
        "failures": [],
        "risks": [],
        "next_state": "ready_for_review"
      }

  `extract/1` distinguishes a missing report (`{:error, :missing}`) from a
  malformed one (`{:error, {:invalid, errors}}`) so ledger consumers can tell
  bad reports apart from code failures.
  """

  @schema "rondo.final_report/v0"

  @fenced_json_pattern ~r/```json\s*\n(.*?)```/s

  @type validation_error :: String.t()

  @doc "Returns the final report schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  Extracts and validates a `rondo.final_report/v0` report from adapter output.

  Accepts a decoded map, a raw JSON string, or free-form text containing a
  fenced ```json block.
  """
  @spec extract(term()) :: {:ok, map()} | {:error, :missing} | {:error, {:invalid, [validation_error()]}}
  def extract(report) when is_map(report), do: validate(report)

  def extract(report) when is_binary(report) do
    case decoded_candidates(report) do
      [] -> {:error, :missing}
      candidates -> first_valid_candidate(candidates)
    end
  end

  def extract(_report), do: {:error, :missing}

  @doc "Validates a decoded report map against `rondo.final_report/v0`."
  @spec validate(map()) :: {:ok, map()} | {:error, {:invalid, [validation_error()]}}
  def validate(report) when is_map(report) do
    case validation_errors(report) do
      [] -> {:ok, report}
      errors -> {:error, {:invalid, errors}}
    end
  end

  # Decodes every JSON candidate and prefers the first one that validates as a
  # final report, so unrelated JSON blocks in the agent output cannot shadow a
  # valid report. When none validates, the first decodable map's errors win.
  defp decoded_candidates(report) do
    report
    |> candidate_json_documents()
    |> Enum.flat_map(fn candidate ->
      case Jason.decode(candidate) do
        {:ok, decoded} when is_map(decoded) -> [decoded]
        _other -> []
      end
    end)
  end

  defp first_valid_candidate([first | _rest] = candidates) do
    candidates
    |> Enum.find_value(fn candidate ->
      case validate(candidate) do
        {:ok, report} -> {:ok, report}
        {:error, _reason} -> nil
      end
    end)
    |> case do
      nil -> validate(first)
      result -> result
    end
  end

  defp candidate_json_documents(text) do
    fenced =
      @fenced_json_pattern
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(fn [block] -> String.trim(block) end)
      |> Enum.reverse()

    [String.trim(text) | fenced]
  end

  defp validation_errors(report) do
    []
    |> check_schema(report)
    |> check_non_empty_string(report, "summary")
    |> check_string_list(report, "changed_files")
    |> check_list(report, "gates_run")
    |> check_list(report, "failures")
    |> check_list(report, "risks")
    |> check_non_empty_string(report, "next_state")
    |> Enum.reverse()
  end

  defp check_schema(errors, report) do
    case Map.get(report, "schema") do
      @schema -> errors
      other -> ["schema must be #{inspect(@schema)}, got: #{inspect(other)}" | errors]
    end
  end

  defp check_non_empty_string(errors, report, field) do
    case Map.get(report, field) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          ["#{field} must be a non-empty string" | errors]
        else
          errors
        end

      other ->
        ["#{field} must be a non-empty string, got: #{inspect(other)}" | errors]
    end
  end

  defp check_string_list(errors, report, field) do
    case Map.get(report, field) do
      value when is_list(value) ->
        if Enum.all?(value, &is_binary/1) do
          errors
        else
          ["#{field} must be a list of strings" | errors]
        end

      other ->
        ["#{field} must be a list of strings, got: #{inspect(other)}" | errors]
    end
  end

  defp check_list(errors, report, field) do
    case Map.get(report, field) do
      value when is_list(value) -> errors
      other -> ["#{field} must be a list, got: #{inspect(other)}" | errors]
    end
  end
end
