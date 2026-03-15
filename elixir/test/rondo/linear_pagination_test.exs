defmodule Rondo.Linear.PaginationTest do
  use ExUnit.Case, async: true

  alias Rondo.Linear.Client

  test "fetches all issues in a single batch when under page size" do
    ids = Enum.map(1..5, &"id-#{&1}")

    graphql_fun = fn _query, %{ids: batch_ids} ->
      {:ok, mock_issues_response(batch_ids)}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(ids, graphql_fun)
    assert length(issues) == 5
    assert Enum.map(issues, & &1.id) == ids
  end

  test "paginates when IDs exceed page size" do
    ids = Enum.map(1..120, &"id-#{&1}")
    call_count = :counters.new(1, [:atomics])

    graphql_fun = fn _query, %{ids: batch_ids} ->
      :counters.add(call_count, 1, 1)
      {:ok, mock_issues_response(batch_ids)}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(ids, graphql_fun)
    assert length(issues) == 120
    # Should have made 3 requests: 50 + 50 + 20
    assert :counters.get(call_count, 1) == 3
    # Order preserved
    assert Enum.map(issues, & &1.id) == ids
  end

  test "preserves original ID ordering even when API returns shuffled" do
    ids = ["z-id", "a-id", "m-id"]

    graphql_fun = fn _query, %{ids: batch_ids} ->
      # Return in reverse order
      {:ok, mock_issues_response(Enum.reverse(batch_ids))}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(ids, graphql_fun)
    assert Enum.map(issues, & &1.id) == ["z-id", "a-id", "m-id"]
  end

  test "deduplicates input IDs" do
    ids = ["id-1", "id-1", "id-2", "id-2", "id-3"]

    graphql_fun = fn _query, %{ids: batch_ids} ->
      {:ok, mock_issues_response(batch_ids)}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(ids, graphql_fun)
    assert length(issues) == 3
  end

  test "returns ok with empty list for empty input" do
    assert {:ok, []} =
             Client.fetch_issue_states_by_ids_for_test([], fn _, _ ->
               flunk("should not call")
             end)
  end

  test "propagates error from first batch" do
    ids = Enum.map(1..60, &"id-#{&1}")

    graphql_fun = fn _query, _vars ->
      {:error, :network_failure}
    end

    assert {:error, :network_failure} =
             Client.fetch_issue_states_by_ids_for_test(ids, graphql_fun)
  end

  test "propagates error from second batch" do
    ids = Enum.map(1..80, &"id-#{&1}")
    call_count = :counters.new(1, [:atomics])

    graphql_fun = fn _query, _vars ->
      :counters.add(call_count, 1, 1)
      count = :counters.get(call_count, 1)

      if count > 1 do
        {:error, :second_batch_failed}
      else
        {:ok, mock_issues_response(Enum.map(1..50, &"id-#{&1}"))}
      end
    end

    # Should fail on second batch
    assert {:error, :second_batch_failed} =
             Client.fetch_issue_states_by_ids_for_test(ids, graphql_fun)
  end

  defp mock_issues_response(ids) do
    nodes =
      Enum.map(ids, fn id ->
        %{
          "id" => id,
          "identifier" => "TEST-#{id}",
          "title" => "Test issue #{id}",
          "description" => nil,
          "priority" => 1,
          "state" => %{"name" => "In Progress"},
          "branchName" => nil,
          "url" => "https://linear.app/test/#{id}",
          "assignee" => nil,
          "labels" => %{"nodes" => []},
          "inverseRelations" => %{"nodes" => []},
          "createdAt" => nil,
          "updatedAt" => nil
        }
      end)

    %{"data" => %{"issues" => %{"nodes" => nodes}}}
  end
end
