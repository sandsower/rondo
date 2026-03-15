defmodule Rondo.TimeSeriesTest do
  use ExUnit.Case, async: true

  alias Rondo.TimeSeries

  setup do
    table = :"test_ts_#{System.unique_integer([:positive])}"
    TimeSeries.init(table)
    on_exit(fn ->
      try do
        :ets.delete(table)
      rescue
        _ -> :ok
      end
    end)
    %{table: table}
  end

  test "read returns empty list on fresh table", %{table: table} do
    assert TimeSeries.read(table) == []
  end

  test "record and read a snapshot", %{table: table} do
    snapshot = %{
      running: [%{id: "a"}, %{id: "b"}],
      retrying: [%{id: "c"}],
      claude_totals: %{input_tokens: 10, output_tokens: 20, total_tokens: 30}
    }

    assert :ok = TimeSeries.record(snapshot, table)
    samples = TimeSeries.read(table)
    assert length(samples) == 1

    [sample] = samples
    assert sample.running == 2
    assert sample.retrying == 1
    assert sample.input_tokens == 10
    assert sample.output_tokens == 20
    assert sample.total_tokens == 30
    assert %DateTime{} = sample.at
  end

  test "trims to max entries", %{table: table} do
    for _ <- 1..370 do
      TimeSeries.record(%{running: [], retrying: [], claude_totals: %{}}, table)
    end

    samples = TimeSeries.read(table)
    assert length(samples) <= 360
  end

  test "read survives missing table" do
    assert TimeSeries.read(:nonexistent_table) == []
  end

  test "record survives missing table" do
    assert :ok = TimeSeries.record(%{}, :nonexistent_table)
  end
end
