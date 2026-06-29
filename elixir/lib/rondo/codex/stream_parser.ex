defmodule Rondo.Codex.StreamParser do
  @moduledoc """
  Parses newline-delimited JSON events from `codex exec --json`.
  """

  alias Rondo.Agent.Adapter

  @doc """
  Parse a single JSON line from stdout. Returns `{:ok, event_map}` or `{:error, reason}`.
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
  Extract codex's stable thread id from a parsed event, if present.
  """
  @spec extract_thread_id(map()) :: String.t() | nil
  def extract_thread_id(%{"thread_id" => id}) when is_binary(id), do: id
  def extract_thread_id(%{"threadId" => id}) when is_binary(id), do: id
  def extract_thread_id(_event), do: nil

  @doc """
  Backwards-compatible alias for callers that expect a session id helper.
  """
  @spec extract_session_id(map()) :: String.t() | nil
  def extract_session_id(event), do: extract_thread_id(event)

  @doc """
  Extract compact usage data from codex turn-completed payloads.
  """
  @spec extract_usage(map()) :: map() | nil
  def extract_usage(event) do
    event
    |> usage_payload()
    |> normalize_usage()
  end

  @doc """
  Extract assistant text from a codex item payload, if present.
  """
  @spec assistant_text(map()) :: String.t() | nil
  def assistant_text(%{"item" => %{} = item}), do: assistant_text_from_item(item)
  def assistant_text(_payload), do: nil

  defp normalize_event(payload) do
    thread_id = extract_thread_id(payload)
    run_ref = if thread_id, do: Adapter.run_ref("codex", thread_id, "thread_id", true)

    payload
    |> Map.put(:event_type, normalized_event_type(payload))
    |> Map.put(:run_ref, run_ref)
    |> Map.put(:usage, extract_usage(payload))
    |> Map.put(:message, normalized_message(payload))
    |> Map.put(:diff, normalized_diff(payload))
  end

  defp normalized_event_type(%{"type" => "thread.started"}), do: :session_started
  defp normalized_event_type(%{"type" => "turn.started"}), do: :turn_started
  defp normalized_event_type(%{"type" => "turn.completed"}), do: :invocation_completed
  defp normalized_event_type(%{"type" => "turn.failed"}), do: :invocation_failed
  defp normalized_event_type(%{"type" => "error"}), do: :invocation_failed
  defp normalized_event_type(%{"type" => "item.started"} = payload), do: item_event_type(payload, :started)
  defp normalized_event_type(%{"type" => "item.updated"} = payload), do: item_event_type(payload, :updated)
  defp normalized_event_type(%{"type" => "item.completed"} = payload), do: item_event_type(payload, :completed)
  defp normalized_event_type(_payload), do: :warning

  defp item_event_type(payload, phase) do
    case item_type(payload) do
      "agent_message" when phase == :completed -> :assistant_message
      "command_execution" -> tool_event_type(phase)
      "mcp_tool_call" -> tool_event_type(phase)
      "collab_tool_call" -> tool_event_type(phase)
      "file_change" -> :diff_updated
      _ -> :ignore
    end
  end

  defp tool_event_type(:started), do: :tool_started
  defp tool_event_type(:updated), do: :tool_updated
  defp tool_event_type(:completed), do: :tool_completed

  defp normalized_message(%{"type" => "turn.failed"} = payload) do
    error = Map.get(payload, "error") || Map.get(payload, :error) || %{}
    error_message(error)
  end

  defp normalized_message(%{"type" => "error"} = payload), do: error_message(payload)
  defp normalized_message(%{"type" => type} = payload) when type in ["item.started", "item.updated", "item.completed"], do: item_message(item_payload(payload))
  defp normalized_message(_payload), do: nil

  defp normalized_diff(%{"type" => type} = payload) when type in ["item.started", "item.updated", "item.completed"] do
    item = item_payload(payload)

    case item_type(item) do
      "file_change" ->
        %{
          changes: map_get_any(item, ["changes", :changes]) || [],
          status: map_get_any(item, ["status", :status])
        }

      _ ->
        nil
    end
  end

  defp normalized_diff(_payload), do: nil

  defp item_type(%{"item" => %{} = item}), do: item_type(item)
  defp item_type(%{"type" => type}) when is_binary(type), do: type
  defp item_type(_payload), do: nil

  defp item_payload(payload) do
    Map.get(payload, "item") || payload
  end

  defp assistant_text_from_item(%{} = item) do
    case item_type(item) do
      "agent_message" -> blank_to_nil(map_get_any(item, ["text", :text]))
      _ -> nil
    end
  end

  defp usage_payload(%{"usage" => usage}), do: usage
  defp usage_payload(%{usage: usage}), do: usage
  defp usage_payload(_event), do: nil

  defp normalize_usage(%{} = usage) do
    input_tokens = integer_field(usage, ["input_tokens", :input_tokens])
    output_tokens = integer_field(usage, ["output_tokens", :output_tokens])
    cached_input_tokens = integer_field(usage, ["cached_input_tokens", :cached_input_tokens])
    reasoning_output_tokens = integer_field(usage, ["reasoning_output_tokens", :reasoning_output_tokens])
    total_tokens = integer_field(usage, ["total_tokens", :total_tokens])

    usage_present? =
      usage_fields_present?([
        input_tokens,
        output_tokens,
        cached_input_tokens,
        reasoning_output_tokens,
        total_tokens
      ])

    if usage_present? do
      %{
        input_tokens: input_tokens,
        output_tokens: (output_tokens || 0) + (reasoning_output_tokens || 0),
        cache_read_tokens: cached_input_tokens,
        cache_write_tokens: 0,
        total_tokens:
          total_tokens ||
            Enum.sum([
              input_tokens || 0,
              output_tokens || 0,
              cached_input_tokens || 0,
              reasoning_output_tokens || 0
            ]),
        cost: nil
      }
    end
  end

  defp normalize_usage(_usage), do: nil

  defp usage_fields_present?(usage_values) when is_list(usage_values) do
    Enum.any?(usage_values, &(!is_nil(&1)))
  end

  defp integer_field(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _other -> nil
      end
    end)
  end

  defp map_get_any(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn
      key when is_binary(key) -> Map.get(map, key)
      key when is_atom(key) -> Map.get(map, key)
      _other -> nil
    end)
  end

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_text), do: nil

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(_payload), do: "codex error"

  @spec item_message(map()) :: String.t() | nil
  @doc false
  def item_message(%{} = item) do
    case item_type(item) do
      "agent_message" -> blank_to_nil(map_get_any(item, ["text", :text]))
      "command_execution" -> command_execution_message(item)
      "mcp_tool_call" -> mcp_tool_call_message(item)
      "collab_tool_call" -> collab_tool_call_message(item)
      "file_change" -> file_change_message(item)
      _ -> nil
    end
  end

  defp command_execution_message(item) do
    command = map_get_any(item, ["command", :command])
    output = map_get_any(item, ["aggregated_output", :aggregated_output])

    case {blank_to_nil(command), blank_to_nil(output)} do
      {nil, nil} -> nil
      {command, nil} -> command
      {nil, output} -> output
      {command, output} -> "#{command}: #{output}"
    end
  end

  defp mcp_tool_call_message(item) do
    server = blank_to_nil(map_get_any(item, ["server", :server]))
    tool = blank_to_nil(map_get_any(item, ["tool", :tool]))
    args = map_get_any(item, ["arguments", :arguments])

    base = [server, tool] |> Enum.reject(&is_nil/1) |> Enum.join("/")

    case {base, tool_input_summary(args)} do
      {"", nil} -> nil
      {base, nil} -> base
      {"", summary} -> summary
      {base, summary} -> "#{base}: #{summary}"
    end
  end

  defp collab_tool_call_message(item) do
    tool = blank_to_nil(map_get_any(item, ["tool", :tool]))
    prompt = blank_to_nil(map_get_any(item, ["prompt", :prompt]))

    case {tool, prompt} do
      {nil, nil} -> nil
      {tool, nil} -> to_string(tool)
      {nil, prompt} -> prompt
      {tool, prompt} -> "#{tool}: #{prompt}"
    end
  end

  defp file_change_message(item) do
    item
    |> map_get_any(["changes", :changes])
    |> case do
      changes when is_list(changes) ->
        changes
        |> Enum.map(&change_path/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")
        |> blank_to_nil()

      _ ->
        nil
    end
  end

  defp change_path(%{"path" => path}) when is_binary(path), do: path
  defp change_path(%{path: path}) when is_binary(path), do: path
  defp change_path(_change), do: nil

  defp tool_input_summary(%{} = input) do
    case Enum.find(input, fn {_key, value} -> is_binary(value) and value != "" end) do
      {key, value} -> "#{key}=#{truncate(value, 120)}"
      nil -> truncate(inspect(input), 120)
    end
  end

  defp tool_input_summary(_input), do: nil

  defp truncate(value, max_bytes) when is_binary(value) do
    if byte_size(value) <= max_bytes do
      value
    else
      value
      |> String.graphemes()
      |> take_graphemes(max_bytes)
      |> IO.iodata_to_binary()
      |> Kernel.<>("…")
    end
  end

  defp truncate(value, _max_bytes), do: to_string(value)

  defp take_graphemes(graphemes, max_bytes) do
    {_bytes, reversed_graphemes} =
      Enum.reduce_while(graphemes, {0, []}, fn grapheme, {bytes, acc} ->
        grapheme_bytes = byte_size(grapheme)

        if bytes + grapheme_bytes > max_bytes do
          {:halt, {bytes, acc}}
        else
          {:cont, {bytes + grapheme_bytes, [grapheme | acc]}}
        end
      end)

    Enum.reverse(reversed_graphemes)
  end
end
