defmodule Rondo.Claude.StreamParser do
  @moduledoc """
  Parses newline-delimited JSON events from Claude Code's stream-json output.
  """

  require Logger

  @doc """
  Parse a single JSON line from stdout. Returns {:ok, event_map} or {:error, reason}.
  """
  @spec parse_line(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = payload} -> {:ok, normalize_event(payload)}
      {:ok, _other} -> {:error, {:not_a_map, line}}
      {:error, reason} -> {:error, {:json_parse_error, reason, line}}
    end
  end

  @doc """
  Extract session_id from a parsed event, if present.
  """
  @spec extract_session_id(map()) :: String.t() | nil
  def extract_session_id(%{"session_id" => id}) when is_binary(id), do: id
  def extract_session_id(%{session_id: id}) when is_binary(id), do: id
  def extract_session_id(_event), do: nil

  @doc """
  Extract usage data from a parsed event.
  Returns a map with :input_tokens, :output_tokens, :cache_read_tokens,
  :cache_write_tokens, :total_tokens, :cost (normalized at parity with the
  Codex and Pi stream parsers) or nil.
  """
  @spec extract_usage(map()) :: map() | nil
  def extract_usage(event) do
    # Try top-level usage first (present on "result" events), then fall back
    # to nested message.usage (present on "assistant" events in real CLI output).
    usage =
      Map.get(event, "usage") ||
        Map.get(event, :usage) ||
        nested_message_usage(event)

    # total_cost_usd is a sibling of usage on the top-level "result" event,
    # not nested inside it, so it's extracted from the full event separately.
    normalize_usage(usage, extract_cost(event))
  end

  defp nested_message_usage(event) do
    msg = Map.get(event, "message") || Map.get(event, :message)
    if is_map(msg), do: Map.get(msg, "usage") || Map.get(msg, :usage)
  end

  defp extract_cost(event) do
    number_field(event, ["total_cost_usd", :total_cost_usd])
  end

  defp normalize_usage(%{} = usage, cost) do
    usage_fields = %{
      input_tokens: integer_field(usage, ["input_tokens", :input_tokens]),
      output_tokens: integer_field(usage, ["output_tokens", :output_tokens]),
      cache_read_tokens: integer_field(usage, ["cache_read_input_tokens", :cache_read_input_tokens]),
      cache_write_tokens: integer_field(usage, ["cache_creation_input_tokens", :cache_creation_input_tokens]),
      total_tokens: integer_field(usage, ["total_tokens", :total_tokens]),
      cost: cost
    }

    if usage_fields_present?(usage_fields), do: usage_summary(usage_fields)
  end

  defp normalize_usage(_usage, _cost), do: nil

  defp usage_fields_present?(usage_fields) do
    usage_fields
    |> Map.drop([:cost])
    |> Map.values()
    |> Enum.any?(&(!is_nil(&1)))
  end

  defp usage_summary(usage_fields) do
    input = usage_fields.input_tokens || 0
    output = usage_fields.output_tokens || 0
    cache_read = usage_fields.cache_read_tokens || 0
    cache_write = usage_fields.cache_write_tokens || 0

    %{
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: cache_read,
      cache_write_tokens: cache_write,
      total_tokens: usage_fields.total_tokens || input + output + cache_read + cache_write,
      cost: usage_fields.cost
    }
  end

  defp normalize_event(payload) do
    type = Map.get(payload, "type") || Map.get(payload, :type)
    Map.put(payload, :event_type, categorize_type(type, payload))
  end

  # Only the "init" system event signals the actual start of a session.
  # Hook events also carry session_id but shouldn't count as session starts.
  defp categorize_type("system", payload) do
    subtype = Map.get(payload, "subtype") || Map.get(payload, :subtype)

    if subtype == "init" do
      :session_started
    else
      :system
    end
  end

  defp categorize_type("assistant", _payload), do: :assistant
  defp categorize_type("tool", _payload), do: :tool_use
  defp categorize_type("result", _payload), do: :result
  defp categorize_type("rate_limit_event", _payload), do: :rate_limit
  defp categorize_type(_, _payload), do: :unknown

  defp integer_field(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        v when is_integer(v) and v >= 0 -> v
        _ -> nil
      end
    end)
  end

  defp number_field(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_number(value) and value >= 0 -> value
        _other -> nil
      end
    end)
  end

  defp number_field(_map, _keys), do: nil
end
