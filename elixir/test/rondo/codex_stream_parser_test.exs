defmodule Rondo.Codex.StreamParserTest do
  use ExUnit.Case

  alias Rondo.Codex.StreamParser

  test "parses thread headers and extracts thread ids" do
    assert {:ok, event} = StreamParser.parse_line(~s({"type":"thread.started","thread_id":"codex-thread-1"}))
    assert event.event_type == :session_started
    assert StreamParser.extract_thread_id(event) == "codex-thread-1"

    assert {:ok, event_with_thread_id} =
             StreamParser.parse_line(~s({"type":"thread.started","threadId":"codex-thread-2"}))

    assert event_with_thread_id.event_type == :session_started
    assert StreamParser.extract_thread_id(event_with_thread_id) == "codex-thread-2"
    assert StreamParser.extract_session_id(event_with_thread_id) == "codex-thread-2"
  end

  test "normalizes turn completion usage from Codex totals" do
    line =
      ~s({"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":4}})

    assert {:ok, event} = StreamParser.parse_line(line)
    assert event.event_type == :invocation_completed

    assert StreamParser.extract_usage(event) == %{
             input_tokens: 10,
             output_tokens: 7,
             cache_read_tokens: 2,
             cache_write_tokens: 0,
             total_tokens: 19,
             cost: nil
           }
  end

  test "normalizes assistant messages, tool calls, and file changes" do
    assistant_line =
      ~s({"type":"item.completed","item":{"id":"msg-1","type":"agent_message","text":"Codex final"}})

    assert {:ok, assistant} = StreamParser.parse_line(assistant_line)
    assert assistant.event_type == :assistant_message
    assert StreamParser.assistant_text(assistant) == "Codex final"

    tool_line =
      ~s({"type":"item.started","item":{"id":"tool-1","type":"command_execution","command":"mix test","aggregated_output":"","exit_code":null,"status":"in_progress"}})

    assert {:ok, tool_event} = StreamParser.parse_line(tool_line)
    assert tool_event.event_type == :tool_started
    assert StreamParser.item_message(Map.get(tool_event, "item")) == "mix test"

    diff_line =
      ~s({"type":"item.completed","item":{"id":"patch-1","type":"file_change","changes":[{"path":"lib/rondo.ex","kind":"update"}],"status":"completed"}})

    assert {:ok, diff_event} = StreamParser.parse_line(diff_line)
    assert diff_event.event_type == :diff_updated

    assert diff_event.diff == %{
             changes: [%{"kind" => "update", "path" => "lib/rondo.ex"}],
             status: "completed"
           }
  end

  test "turn failures, updates, and unknown lines normalize to the expected events" do
    assert {:ok, turn_failed} = StreamParser.parse_line(~s({"type":"turn.failed","error":{"message":"boom"}}))
    assert turn_failed.event_type == :invocation_failed
    assert turn_failed.message == "boom"

    assert {:ok, error_event} = StreamParser.parse_line(~s({"type":"error","message":"hard failure"}))
    assert error_event.event_type == :invocation_failed
    assert error_event.message == "hard failure"

    assert {:ok, updated_tool} =
             StreamParser.parse_line(~s({"type":"item.updated","item":{"id":"tool-2","type":"command_execution","command":"mix test","aggregated_output":"all green","status":"running"}}))

    assert updated_tool.event_type == :tool_updated
    assert updated_tool.message == "mix test: all green"

    assert {:ok, completed_tool} =
             StreamParser.parse_line(~s({"type":"item.completed","item":{"id":"tool-3","type":"mcp_tool_call","server":"mcp","tool":"search","arguments":{"query":"codex"}}}))

    assert completed_tool.event_type == :tool_completed
    assert completed_tool.message == "mcp/search: query=codex"

    assert {:ok, collab_tool} =
             StreamParser.parse_line(~s({"type":"item.updated","item":{"id":"tool-4","type":"collab_tool_call","tool":"review","prompt":"please check"}}))

    assert collab_tool.event_type == :tool_updated
    assert collab_tool.message == "review: please check"

    assert {:ok, ignored_item} =
             StreamParser.parse_line(~s({"type":"item.started","item":{"id":"mystery","type":"weird_type"}}))

    assert ignored_item.event_type == :ignore
    assert ignored_item.message == nil

    assert {:ok, warning_event} = StreamParser.parse_line(~s({"type":"mystery"}))
    assert warning_event.event_type == :warning

    assert {:error, {:not_a_map, "[]"}} = StreamParser.parse_line("[]")
    assert match?({:error, {:json_parse_error, _, "{not-json}"}}, StreamParser.parse_line("{not-json}"))
  end

  test "covers helper fallbacks for item message and usage extraction" do
    assert StreamParser.item_message(%{}) == nil
    assert StreamParser.item_message(%{"type" => "command_execution", "command" => "", "aggregated_output" => "out"}) == "out"
    assert StreamParser.item_message(%{"type" => "command_execution", "aggregated_output" => "only output"}) == "only output"
    assert StreamParser.item_message(%{"type" => "command_execution", "command" => "", "aggregated_output" => ""}) == nil
    assert StreamParser.item_message(%{"type" => "mcp_tool_call"}) == nil
    assert StreamParser.item_message(%{"type" => "mcp_tool_call", "tool" => "search"}) == "search"
    assert StreamParser.item_message(%{"type" => "mcp_tool_call", "server" => "mcp", "tool" => "search"}) == "mcp/search"
    assert StreamParser.item_message(%{"type" => "mcp_tool_call", "server" => "", "tool" => "", "arguments" => %{"query" => "codex"}}) == "query=codex"
    assert StreamParser.item_message(%{"type" => "mcp_tool_call", "server" => "", "tool" => "", "arguments" => %{}}) == "%{}"
    assert StreamParser.item_message(%{"type" => "mcp_tool_call", "server" => "", "tool" => "", "arguments" => nil}) == nil
    assert StreamParser.item_message(%{"type" => "collab_tool_call"}) == nil
    assert StreamParser.item_message(%{"type" => "collab_tool_call", "tool" => "review"}) == "review"
    assert StreamParser.item_message(%{"type" => "collab_tool_call", "prompt" => "please"}) == "please"
    assert StreamParser.item_message(%{"type" => "agent_message", "text" => 123}) == nil
    assert StreamParser.item_message(%{"type" => "file_change", "changes" => [%{"kind" => "update"}]}) == nil
    assert StreamParser.item_message(%{"type" => "file_change", "changes" => [%{path: "lib/rondo.ex"}]}) == "lib/rondo.ex"

    atom_keyed_summary =
      StreamParser.item_message(%{
        "type" => "mcp_tool_call",
        server: "mcp",
        tool: "search",
        arguments: %{query: "codex"}
      })

    assert atom_keyed_summary == "mcp/search: query=codex"

    long_query = String.duplicate("é", 80)

    long_message =
      StreamParser.item_message(%{
        "type" => "mcp_tool_call",
        "server" => "mcp",
        "tool" => "search",
        "arguments" => %{query: long_query}
      })

    assert String.valid?(long_message)
    assert String.ends_with?(long_message, "…")

    assert StreamParser.extract_usage(%{usage: %{}}) == nil

    empty_usage = %{
      input_tokens: nil,
      output_tokens: nil,
      cached_input_tokens: nil,
      total_tokens: nil,
      reasoning_output_tokens: nil
    }

    assert StreamParser.extract_usage(%{usage: empty_usage}) == nil

    usage = %{
      input_tokens: 1,
      output_tokens: 2,
      cached_input_tokens: 3,
      total_tokens: 4
    }

    assert StreamParser.extract_usage(%{usage: usage}) == %{
             input_tokens: 1,
             output_tokens: 2,
             cache_read_tokens: 3,
             cache_write_tokens: 0,
             total_tokens: 4,
             cost: nil
           }
  end
end
