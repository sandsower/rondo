defmodule Rondo.Pi.StreamParser do
  @moduledoc """
  Parses newline-delimited JSON events from `pi --mode json`.
  """

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
  Extract pi's stable session id from a parsed event, if present.
  """
  @spec extract_session_id(map()) :: String.t() | nil
  def extract_session_id(%{"type" => "session", "id" => id}) when is_binary(id), do: id
  def extract_session_id(%{type: "session", id: id}) when is_binary(id), do: id
  def extract_session_id(%{"sessionId" => id}) when is_binary(id), do: id
  def extract_session_id(%{sessionId: id}) when is_binary(id), do: id
  def extract_session_id(%{"session_id" => id}) when is_binary(id), do: id
  def extract_session_id(%{session_id: id}) when is_binary(id), do: id
  def extract_session_id(_event), do: nil

  @doc """
  Extract compact usage data from pi event payloads.
  """
  @spec extract_usage(map()) :: map() | nil
  def extract_usage(event) do
    event
    |> usage_payload()
    |> normalize_usage()
  end

  @doc """
  Extract an explicit final result string from a pi payload, if present.
  """
  @spec explicit_result(map()) :: String.t() | nil
  def explicit_result(%{"result" => result}) when is_binary(result), do: blank_to_nil(result)
  def explicit_result(%{result: result}) when is_binary(result), do: blank_to_nil(result)
  def explicit_result(_payload), do: nil

  @doc """
  Extract assistant text from a completed pi message or agent-end payload.
  """
  @spec assistant_text(map()) :: String.t() | nil
  def assistant_text(%{"message" => %{} = message}), do: assistant_text_from_message(message)
  def assistant_text(%{message: %{} = message}), do: assistant_text_from_message(message)

  def assistant_text(%{"messages" => messages}) when is_list(messages), do: last_assistant_text(messages)
  def assistant_text(%{messages: messages}) when is_list(messages), do: last_assistant_text(messages)
  def assistant_text(%{"content" => content}) when is_binary(content) or is_list(content), do: content_text(content)
  def assistant_text(%{content: content}) when is_binary(content) or is_list(content), do: content_text(content)
  def assistant_text(%{} = message), do: assistant_text_from_message(message)
  def assistant_text(_payload), do: nil

  defp normalize_event(payload) do
    type = Map.get(payload, "type") || Map.get(payload, :type)
    Map.put(payload, :event_type, categorize_type(type, payload))
  end

  defp categorize_type("session", _payload), do: :session_started
  defp categorize_type("agent_start", _payload), do: :invocation_started
  defp categorize_type("agent_end", _payload), do: :invocation_completed
  defp categorize_type("turn_start", _payload), do: :turn_started
  defp categorize_type("message", payload), do: message_type(payload)
  defp categorize_type("message_end", payload), do: message_end_type(payload)
  defp categorize_type("toolCall", _payload), do: :tool_started
  defp categorize_type("toolResult", _payload), do: :tool_completed
  defp categorize_type("tool_execution_start", _payload), do: :tool_started
  defp categorize_type("tool_execution_update", _payload), do: :tool_updated
  defp categorize_type("tool_execution_end", _payload), do: :tool_completed
  defp categorize_type("custom_message", payload), do: custom_message_type(payload)
  defp categorize_type("model_change", _payload), do: :warning
  defp categorize_type("thinking_level_change", _payload), do: :warning
  defp categorize_type("auto_retry_start", _payload), do: :warning
  defp categorize_type("auto_retry_end", _payload), do: :warning
  defp categorize_type("extension_error", _payload), do: :warning
  defp categorize_type(_type, _payload), do: :ignore

  defp message_type(payload) do
    message = Map.get(payload, "message") || Map.get(payload, :message)

    cond do
      tool_result_message?(message) -> :tool_completed
      assistant_tool_call_message?(message) -> :tool_started
      assistant_message?(message) -> :assistant_message
      true -> :ignore
    end
  end

  defp message_end_type(payload) do
    message = Map.get(payload, "message") || Map.get(payload, :message)

    if assistant_message?(message) do
      :assistant_message
    else
      :ignore
    end
  end

  defp custom_message_type(payload) do
    case Map.get(payload, "display", Map.get(payload, :display, true)) do
      false -> :ignore
      _ -> :warning
    end
  end

  defp assistant_message?(%{"role" => "assistant"}), do: true
  defp assistant_message?(%{role: "assistant"}), do: true
  defp assistant_message?(_message), do: false

  defp tool_result_message?(%{"role" => role}) when role in ["tool", "toolResult"], do: true
  defp tool_result_message?(%{role: role}) when role in ["tool", "toolResult", :tool, :toolResult], do: true
  defp tool_result_message?(_message), do: false

  defp assistant_tool_call_message?(%{} = message) do
    assistant_message?(message) and message |> Map.get("content", Map.get(message, :content)) |> content_has_tool_call?()
  end

  defp assistant_tool_call_message?(_message), do: false

  defp content_has_tool_call?(content) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "toolCall"} -> true
      %{type: "toolCall"} -> true
      %{"type" => "tool_use"} -> true
      %{type: "tool_use"} -> true
      _ -> false
    end)
  end

  defp content_has_tool_call?(_content), do: false

  defp usage_payload(event) do
    Map.get(event, "usage") ||
      Map.get(event, :usage) ||
      nested_message_usage(event) ||
      nested_tokens(event)
  end

  defp nested_message_usage(event) do
    message = Map.get(event, "message") || Map.get(event, :message)
    if is_map(message), do: Map.get(message, "usage") || Map.get(message, :usage)
  end

  defp nested_tokens(event) do
    stats = Map.get(event, "stats") || Map.get(event, :stats)
    if is_map(stats), do: Map.get(stats, "tokens") || Map.get(stats, :tokens)
  end

  defp normalize_usage(%{} = usage) do
    usage_fields = %{
      input_tokens: integer_field(usage, ["input", :input, "input_tokens", :input_tokens]),
      output_tokens: integer_field(usage, ["output", :output, "output_tokens", :output_tokens]),
      cache_read_tokens: cache_read_tokens(usage),
      cache_write_tokens: cache_write_tokens(usage),
      total_tokens: integer_field(usage, ["total", :total, "total_tokens", :total_tokens]),
      cost: usage |> number_field(["cost", :cost]) |> normalize_cost()
    }

    if usage_fields_present?(usage_fields), do: usage_summary(usage_fields)
  end

  defp normalize_usage(_usage), do: nil

  defp cache_read_tokens(usage) do
    integer_field(usage, ["cacheRead", :cacheRead, "cache_read", :cache_read, "cache_read_tokens", :cache_read_tokens])
  end

  defp cache_write_tokens(usage) do
    integer_field(usage, ["cacheWrite", :cacheWrite, "cache_write", :cache_write, "cache_write_tokens", :cache_write_tokens])
  end

  defp usage_fields_present?(usage_fields) do
    usage_fields
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

  defp normalize_cost(%{} = cost), do: number_field(cost, ["total", :total])
  defp normalize_cost(cost) when is_number(cost), do: cost
  defp normalize_cost(_cost), do: nil

  defp integer_field(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _other -> nil
      end
    end)
  end

  defp number_field(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_number(value) and value >= 0 -> value
        %{} = value -> normalize_cost(value)
        _other -> nil
      end
    end)
  end

  defp last_assistant_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{} = message -> assistant_text_from_message(message)
      _message -> nil
    end)
  end

  defp assistant_text_from_message(%{} = message) do
    if assistant_message?(message) do
      message
      |> Map.get("content", Map.get(message, :content))
      |> content_text()
    end
  end

  defp content_text(content) when is_binary(content), do: blank_to_nil(content)

  defp content_text(content) when is_list(content) do
    content
    |> Enum.flat_map(&content_block_text/1)
    |> Enum.join(" ")
    |> blank_to_nil()
  end

  defp content_text(_content), do: nil

  defp content_block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: [text]
  defp content_block_text(%{type: "text", text: text}) when is_binary(text), do: [text]
  defp content_block_text(_block), do: []

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
