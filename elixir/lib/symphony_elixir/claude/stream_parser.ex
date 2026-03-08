defmodule SymphonyElixir.Claude.StreamParser do
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
  Returns a map with :input_tokens, :output_tokens, :total_tokens or nil.
  """
  @spec extract_usage(map()) :: map() | nil
  def extract_usage(event) do
    # Try top-level usage first (present on "result" events), then fall back
    # to nested message.usage (present on "assistant" events in real CLI output).
    usage =
      Map.get(event, "usage") ||
        Map.get(event, :usage) ||
        nested_message_usage(event)

    normalize_usage(usage)
  end

  defp nested_message_usage(event) do
    msg = Map.get(event, "message") || Map.get(event, :message)
    if is_map(msg), do: Map.get(msg, "usage") || Map.get(msg, :usage)
  end

  defp normalize_usage(%{} = usage) do
    input = integer_field(usage, ["input_tokens", :input_tokens])
    output = integer_field(usage, ["output_tokens", :output_tokens])
    total = integer_field(usage, ["total_tokens", :total_tokens])

    if input || output || total do
      %{
        input_tokens: input || 0,
        output_tokens: output || 0,
        total_tokens: total || (input || 0) + (output || 0)
      }
    end
  end

  defp normalize_usage(_), do: nil

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
end
