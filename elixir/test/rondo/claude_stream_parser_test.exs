defmodule Rondo.Claude.StreamParserTest do
  use ExUnit.Case

  alias Rondo.Claude.StreamParser

  test "normalizes result usage with cache tokens and cost at parity with codex/pi (R2)" do
    line =
      ~s({"type":"result","subtype":"success","session_id":"cache-usage-session","total_cost_usd":0.0123,) <>
        ~s("usage":{"input_tokens":130,"output_tokens":45,"cache_creation_input_tokens":15,"cache_read_input_tokens":5}})

    assert {:ok, event} = StreamParser.parse_line(line)
    assert event.event_type == :result

    assert StreamParser.extract_usage(event) == %{
             input_tokens: 130,
             output_tokens: 45,
             cache_read_tokens: 5,
             cache_write_tokens: 15,
             total_tokens: 195,
             cost: 0.0123
           }
  end

  test "normalizes nested assistant message usage with cache tokens (R2)" do
    line =
      ~s({"type":"assistant","session_id":"cache-usage-session",) <>
        ~s("message":{"type":"message","usage":{"input_tokens":80,"output_tokens":20,) <>
        ~s("cache_creation_input_tokens":10,"cache_read_input_tokens":2}}})

    assert {:ok, event} = StreamParser.parse_line(line)

    assert StreamParser.extract_usage(event) == %{
             input_tokens: 80,
             output_tokens: 20,
             cache_read_tokens: 2,
             cache_write_tokens: 10,
             total_tokens: 112,
             cost: nil
           }
  end

  test "usage without cache tokens or cost still carries the keys at zero/nil (R2)" do
    line = ~s({"type":"result","subtype":"success","session_id":"plain-session","usage":{"input_tokens":100,"output_tokens":50}})

    assert {:ok, event} = StreamParser.parse_line(line)

    assert StreamParser.extract_usage(event) == %{
             input_tokens: 100,
             output_tokens: 50,
             cache_read_tokens: 0,
             cache_write_tokens: 0,
             total_tokens: 150,
             cost: nil
           }
  end
end
