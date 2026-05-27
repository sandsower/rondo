defmodule Rondo.Pi.StreamParserTest do
  use Rondo.TestSupport

  alias Rondo.Pi.StreamParser

  test "parses session headers and extracts session id" do
    assert {:ok, event} = StreamParser.parse_line(~s({"type":"session","version":3,"id":"pi-session","cwd":"/tmp/work"}))
    assert event.event_type == :session_started
    assert StreamParser.extract_session_id(event) == "pi-session"
  end

  test "normalizes assistant message_end text and usage" do
    line =
      ~s({"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Done"}],"usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":1,"cost":{"total":0.03}}}})

    assert {:ok, event} = StreamParser.parse_line(line)
    assert event.event_type == :assistant_message
    assert StreamParser.assistant_text(event) == "Done"

    assert StreamParser.extract_usage(event) == %{
             input_tokens: 10,
             output_tokens: 5,
             cache_read_tokens: 2,
             cache_write_tokens: 1,
             total_tokens: 18,
             cost: 0.03
           }
  end

  test "extracts final assistant text from agent_end messages" do
    line =
      ~s({"type":"agent_end","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":[{"type":"text","text":"Final report"}]}]})

    assert {:ok, event} = StreamParser.parse_line(line)
    assert event.event_type == :invocation_completed
    assert StreamParser.assistant_text(event) == "Final report"
  end

  test "maps tool execution events" do
    assert {:ok, start} = StreamParser.parse_line(~s({"type":"tool_execution_start","toolCallId":"t1","toolName":"bash","args":{}}))
    assert {:ok, update} = StreamParser.parse_line(~s({"type":"tool_execution_update","toolCallId":"t1","toolName":"bash","partialResult":{}}))
    assert {:ok, stop} = StreamParser.parse_line(~s({"type":"tool_execution_end","toolCallId":"t1","toolName":"bash","isError":false}))

    assert start.event_type == :tool_started
    assert update.event_type == :tool_updated
    assert stop.event_type == :tool_completed
  end
end
