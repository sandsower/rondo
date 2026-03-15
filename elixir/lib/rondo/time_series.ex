defmodule Rondo.TimeSeries do
  @moduledoc """
  ETS-backed ring buffer for dashboard time-series data.
  Stores snapshots at a configurable interval, keeps the last N entries.
  """

  @default_table :rondo_timeseries
  @max_entries 360

  @type sample :: %{
          at: DateTime.t(),
          running: non_neg_integer(),
          retrying: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @spec init(atom()) :: atom()
  def init(table \\ @default_table) do
    :ets.new(table, [:ordered_set, :public, :named_table])
    table
  rescue
    ArgumentError -> table
  end

  @spec record(map(), atom()) :: :ok
  def record(snapshot, table \\ @default_table) do
    now = System.monotonic_time(:millisecond)
    running = snapshot |> Map.get(:running, []) |> length()
    retrying = snapshot |> Map.get(:retrying, []) |> length()
    totals = Map.get(snapshot, :claude_totals, %{})

    sample = %{
      at: DateTime.utc_now(),
      running: running,
      retrying: retrying,
      input_tokens: Map.get(totals, :input_tokens, 0),
      output_tokens: Map.get(totals, :output_tokens, 0),
      total_tokens: Map.get(totals, :total_tokens, 0)
    }

    :ets.insert(table, {now, sample})
    trim(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec read(atom()) :: [sample()]
  def read(table \\ @default_table) do
    :ets.tab2list(table)
    |> Enum.map(fn {_key, sample} -> sample end)
  rescue
    ArgumentError -> []
  end

  defp trim(table) do
    size = :ets.info(table, :size)

    if size > @max_entries do
      keys =
        :ets.tab2list(table)
        |> Enum.map(fn {key, _} -> key end)
        |> Enum.sort()
        |> Enum.take(size - @max_entries)

      Enum.each(keys, &:ets.delete(table, &1))
    end
  end
end
