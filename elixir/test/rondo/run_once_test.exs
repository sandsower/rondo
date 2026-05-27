defmodule Rondo.RunOnceTest do
  use Rondo.TestSupport, async: true

  alias Rondo.RunOnce

  test "runs exactly one visible active issue" do
    parent = self()

    issue = issue("issue-1", state: "In Progress")

    assert :ok =
             RunOnce.run("issue-1",
               deps: deps(issue, parent)
             )

    assert_received {:fetch_issue_states_by_ids, ["issue-1"]}
    assert_received {:agent_run, %Issue{id: "issue-1", state: "In Progress"}, []}
    refute_received {:update_issue_state, _, _}
  end

  test "returns clear error when issue is missing or not visible" do
    parent = self()

    assert {:error, {:issue_not_visible, "missing-1"}} =
             RunOnce.run("missing-1",
               deps: deps([], parent)
             )

    assert_received {:fetch_issue_states_by_ids, ["missing-1"]}
    refute_received {:agent_run, _, _}
  end

  test "returns clear error for filtered issues omitted by tracker visibility" do
    parent = self()

    assert {:error, {:issue_not_visible, "filtered-1"}} =
             RunOnce.run("filtered-1",
               deps: deps([], parent)
             )

    refute_received {:agent_run, _, _}
  end

  test "rejects terminal issues" do
    parent = self()

    assert {:error, {:issue_not_dispatchable, context, :terminal_state}} =
             RunOnce.run("issue-done",
               deps: deps(issue("issue-done", state: "Done"), parent)
             )

    assert context =~ "issue_identifier=GH-1"
    refute_received {:agent_run, _, _}
  end

  test "rejects inactive issues" do
    parent = self()

    assert {:error, {:issue_not_dispatchable, _context, :inactive_state}} =
             RunOnce.run("issue-backlog",
               deps: deps(issue("issue-backlog", state: "Backlog"), parent)
             )

    refute_received {:agent_run, _, _}
  end

  test "rejects Todo issues blocked by non-terminal blockers" do
    parent = self()

    blocked_issue =
      issue("issue-blocked",
        state: "Todo",
        blocked_by: [%{id: "blocker-1", identifier: "GH-2", state: "In Progress"}]
      )

    assert {:error, {:issue_not_dispatchable, _context, :blocked}} =
             RunOnce.run("issue-blocked",
               deps: deps(blocked_issue, parent)
             )

    refute_received {:agent_run, _, _}
  end

  test "transitions Todo issues to In Progress before running the agent" do
    parent = self()

    assert :ok =
             RunOnce.run("issue-todo",
               deps: deps(issue("issue-todo", state: "Todo"), parent)
             )

    assert_received {:update_issue_state, "issue-todo", "In Progress"}
    assert_received {:agent_run, %Issue{id: "issue-todo", state: "In Progress"}, []}
  end

  test "returns clear error when Todo transition fails" do
    parent = self()

    assert {:error, {:issue_transition_failed, _context, :boom}} =
             RunOnce.run("issue-todo",
               deps: deps(issue("issue-todo", state: "Todo"), parent, update_result: {:error, :boom})
             )

    refute_received {:agent_run, _, _}
  end

  test "converts adapter exceptions into errors" do
    parent = self()

    assert {:error, {:agent_run_failed, "agent exploded"}} =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent, agent_runner: :raise)
             )

    assert_received {:agent_run, %Issue{id: "issue-1"}, []}
  end

  test "passes agent opts through to the agent runner" do
    parent = self()

    assert :ok =
             RunOnce.run("issue-1",
               deps: deps(issue("issue-1", state: "In Progress"), parent),
               agent_opts: [agent_adapter: TestAdapter]
             )

    assert_received {:agent_run, %Issue{id: "issue-1"}, [agent_adapter: TestAdapter]}
  end

  defp deps(fetch_result, parent, opts \\ []) do
    update_result = Keyword.get(opts, :update_result, :ok)
    agent_runner = Keyword.get(opts, :agent_runner, :ok)

    %{
      fetch_issue_states_by_ids: fn issue_ids ->
        send(parent, {:fetch_issue_states_by_ids, issue_ids})
        {:ok, List.wrap(fetch_result)}
      end,
      update_issue_state: fn issue_id, state_name ->
        send(parent, {:update_issue_state, issue_id, state_name})
        update_result
      end,
      agent_runner: fn issue, agent_opts ->
        send(parent, {:agent_run, issue, agent_opts})

        case agent_runner do
          :ok -> :ok
          :raise -> raise "agent exploded"
        end
      end
    }
  end

  defp issue(id, attrs) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: id,
          identifier: "GH-1",
          title: "Run once",
          description: "Run this issue once",
          state: "In Progress",
          labels: []
        ],
        attrs
      )
    )
  end
end
