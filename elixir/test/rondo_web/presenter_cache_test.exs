defmodule RondoWeb.PresenterCacheTest do
  use ExUnit.Case, async: true

  alias RondoWeb.PresenterCache

  test "fetch reuses values until the fingerprint changes" do
    key = {__MODULE__, System.unique_integer([:positive])}
    counter = :counters.new(1, [])

    compute = fn ->
      :counters.add(counter, 1, 1)
      :counters.get(counter, 1)
    end

    assert PresenterCache.fetch(key, :v1, compute) == 1
    assert PresenterCache.fetch(key, :v1, compute) == 1
    assert PresenterCache.fetch(key, :v2, compute) == 2
  end
end
