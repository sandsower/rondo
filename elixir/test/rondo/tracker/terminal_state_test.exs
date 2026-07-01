defmodule Rondo.Tracker.TerminalStateTest do
  use ExUnit.Case, async: true

  alias Rondo.Linear.Issue
  alias Rondo.Tracker.TerminalState

  test "refresh_issue_state classifies active, inactive, and terminal states" do
    issue = %Issue{id: "issue-terminal-state", state: "Todo"}
    active_states = ["Todo", "In Progress"]
    terminal_states = MapSet.new(["Done", "Canceled", "Cancelled", "Duplicate", "Closed"])

    assert {:active, %Issue{state: "In Progress"}} =
             TerminalState.refresh_issue_state(
               issue,
               fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
               active_states,
               terminal_states
             )

    assert {:inactive, %Issue{state: "Paused"}} =
             TerminalState.refresh_issue_state(
               issue,
               fn [_issue_id] -> {:ok, [%{issue | state: "Paused"}]} end,
               active_states,
               terminal_states
             )

    assert {:terminal, %Issue{state: "Closed"}} =
             TerminalState.refresh_issue_state(
               issue,
               fn [_issue_id] -> {:ok, [%{issue | state: "Closed"}]} end,
               active_states,
               terminal_states
             )
  end

  test "refresh_issue_state returns missing when no refreshed issue is visible" do
    issue = %Issue{id: "issue-terminal-state-missing", state: "In Progress"}

    assert {:missing, ^issue} =
             TerminalState.refresh_issue_state(
               issue,
               fn [_issue_id] -> {:ok, []} end,
               ["In Progress"],
               MapSet.new(["Done"])
             )
  end

  test "refresh_issue_state returns error when the fetcher fails" do
    issue = %Issue{id: "issue-terminal-state-error", state: "In Progress"}

    assert {:error, :boom} =
             TerminalState.refresh_issue_state(
               issue,
               fn [_issue_id] -> {:error, :boom} end,
               ["In Progress"],
               MapSet.new(["Done"])
             )
  end

  test "refresh_issue_state returns missing for non-issue inputs and unexpected fetch payloads" do
    issue = %Issue{id: "issue-terminal-state-other", state: "In Progress"}

    assert {:missing, %{id: "issue-terminal-state-map"}} =
             TerminalState.refresh_issue_state(
               %{id: "issue-terminal-state-map", state: "In Progress"},
               fn [_issue_id] -> {:ok, [%Issue{id: "issue-terminal-state-map", state: "In Progress"}]} end,
               ["In Progress"],
               ["Done"]
             )

    assert {:missing, ^issue} =
             TerminalState.refresh_issue_state(
               issue,
               fn [_issue_id] -> {:ok, [%{id: issue.id, state: "Paused"}]} end,
               ["In Progress"],
               ["Done"]
             )
  end

  test "refresh_issue_state normalizes unexpected state collections and non-binary states" do
    issue = %Issue{id: "issue-terminal-state-normalize", state: "Paused"}

    assert {:inactive, %Issue{state: "Paused"}} =
             TerminalState.refresh_issue_state(
               issue,
               fn [_issue_id] -> {:ok, [%{issue | state: "Paused"}]} end,
               {:unexpected, :states},
               [123]
             )
  end
end
