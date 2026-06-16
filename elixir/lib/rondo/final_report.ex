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
  @type disposition :: %{
          required(:action) => :continue | :stop | :pause | :unknown,
          required(:status) => :valid | :invalid | :missing,
          required(:reason) => atom(),
          optional(:next_state) => String.t(),
          optional(:inferred_next_state) => String.t(),
          optional(:text) => String.t(),
          optional(:report) => map(),
          optional(:errors) => [validation_error()]
        }

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

  @doc "Classifies a report for continuation decisions without hiding validation errors."
  @spec disposition(term(), keyword()) :: disposition()
  def disposition(source, opts \\ []) do
    active_states = Keyword.get(opts, :active_states, [])

    case extract(source) do
      {:ok, report} -> valid_disposition(report, active_states)
      {:error, :missing} -> invalid_disposition(source, :missing, [], :missing_report)
      {:error, {:invalid, errors}} -> invalid_disposition(source, :invalid, errors, :invalid_report)
    end
  end

  defp valid_disposition(report, active_states) do
    next_state = Map.get(report, "next_state")

    if active_next_state?(next_state, active_states) do
      %{action: :continue, status: :valid, reason: :active_next_state, next_state: next_state, report: report}
    else
      %{action: :stop, status: :valid, reason: :terminal_next_state, next_state: next_state, report: report}
    end
  end

  defp invalid_disposition(source, status, errors, fallback_reason) do
    case textual_next_state(source) do
      {:ok, "blocked", text} ->
        %{
          action: :pause,
          status: status,
          reason: :blocked_state_unparsed,
          inferred_next_state: "blocked",
          text: text,
          errors: errors
        }

      {:ok, inferred_next_state, text} ->
        %{
          action: :stop,
          status: status,
          reason: :terminal_state_unparsed,
          inferred_next_state: inferred_next_state,
          text: text,
          errors: errors
        }

      :error ->
        %{action: :unknown, status: status, reason: fallback_reason, errors: errors}
    end
    |> drop_empty_errors()
  end

  defp active_next_state?(next_state, active_states) when is_binary(next_state) and is_list(active_states) do
    normalized_next_state = normalize_state(next_state)

    Enum.any?(active_states, fn state -> normalize_state(state) == normalized_next_state end)
  end

  defp active_next_state?(_next_state, _active_states), do: false

  defp textual_next_state(text) when is_binary(text) do
    normalized = String.downcase(text)

    cond do
      Regex.match?(~r/\b"?next_state"?\s*:\s*"?blocked"?\b/i, text) or Regex.match?(~r/^\s*blocked\b/im, text) ->
        {:ok, "blocked", String.trim(text)}

      Regex.match?(~r/\b"?next_state"?\s*:\s*"?(done|complete|completed|ready_for_review|ready for review)"?\b/i, text) ->
        {:ok, terminal_state_from_text(normalized), String.trim(text)}

      Regex.match?(~r/\A\s*(done|complete|completed|ready_for_review|ready for review)[.!]?\s*\z/i, text) ->
        {:ok, terminal_state_from_text(normalized), String.trim(text)}

      true ->
        :error
    end
  end

  defp textual_next_state(source) when is_map(source) do
    source
    |> next_state_value()
    |> textual_next_state_from_value(source)
  end

  defp textual_next_state(_source), do: :error

  defp textual_next_state_from_value(next_state, source) when is_binary(next_state) do
    normalized = normalize_state(next_state)

    cond do
      normalized == "blocked" -> {:ok, "blocked", inspect(source)}
      terminal_state?(normalized) -> {:ok, terminal_state_from_text(normalized), inspect(source)}
      true -> :error
    end
  end

  defp textual_next_state_from_value(_next_state, _source), do: :error

  defp next_state_value(source), do: Map.get(source, "next_state") || Map.get(source, :next_state)

  defp terminal_state?(state), do: state in ["done", "complete", "completed", "ready_for_review", "ready for review"]

  defp terminal_state_from_text(text) do
    cond do
      String.contains?(text, "ready_for_review") or String.contains?(text, "ready for review") -> "ready_for_review"
      String.contains?(text, "complete") or String.contains?(text, "completed") -> "completed"
      true -> "done"
    end
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(state), do: state |> to_string() |> normalize_state()

  defp drop_empty_errors(%{errors: []} = disposition), do: Map.delete(disposition, :errors)
  defp drop_empty_errors(disposition), do: disposition

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
