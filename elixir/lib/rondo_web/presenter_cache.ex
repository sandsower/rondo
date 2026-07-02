defmodule RondoWeb.PresenterCache do
  @moduledoc """
  Fingerprint-keyed cache for expensive observability projections.

  The archived-run table is rebuilt from the orchestrator snapshot on every
  dashboard mount, pubsub refresh, and `/api/v1/state` request. Archived data
  only changes when a run is archived, so callers pass a cheap fingerprint of
  the source list and the projection is reused until the fingerprint moves.

  The ETS table is owned by this process. When it is not running (unit tests
  exercising the presenter directly), `fetch/3` transparently computes the
  value without caching.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec fetch(term(), term(), (-> value)) :: value when value: term()
  def fetch(key, fingerprint, compute) when is_function(compute, 0) do
    case :ets.whereis(@table) do
      :undefined ->
        compute.()

      _tid ->
        case :ets.lookup(@table, key) do
          [{^key, ^fingerprint, value}] ->
            value

          _ ->
            value = compute.()
            :ets.insert(@table, {key, fingerprint, value})
            value
        end
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
