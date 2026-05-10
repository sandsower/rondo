defmodule Rondo.GitHub.Adapter do
  @moduledoc """
  GitHub Issues-backed tracker adapter.
  """

  @behaviour Rondo.Tracker

  alias Rondo.GitHub.Client

  @impl true
  def fetch_candidate_issues, do: Client.fetch_candidate_issues()

  @impl true
  def fetch_issues_by_states(states), do: Client.fetch_issues_by_states(states)

  @impl true
  def fetch_issue_states_by_ids(issue_ids), do: Client.fetch_issue_states_by_ids(issue_ids)

  @impl true
  def create_comment(issue_id, body), do: Client.create_comment(issue_id, body)

  @impl true
  def update_issue_state(issue_id, state_name), do: Client.update_issue_state(issue_id, state_name)
end
