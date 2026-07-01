defmodule Rondo.Tracker.TerminalState do
  @moduledoc """
  Terminal-state refresh helpers for tracker-driven run guards.
  """

  alias Rondo.Linear.Issue

  @spec refresh_issue_state(
          Issue.t() | map(),
          ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()}),
          [String.t()] | MapSet.t(String.t()),
          [String.t()] | MapSet.t(String.t())
        ) ::
          {:active, Issue.t()}
          | {:inactive, Issue.t()}
          | {:terminal, Issue.t()}
          | {:missing, Issue.t() | map()}
          | {:error, term()}
  def refresh_issue_state(%Issue{id: issue_id} = issue, issue_fetcher, active_states, terminal_states)
      when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        classify_issue_state(refreshed_issue, active_states, terminal_states)

      {:ok, []} ->
        {:missing, issue}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:missing, issue}
    end
  end

  def refresh_issue_state(issue, _issue_fetcher, _active_states, _terminal_states), do: {:missing, issue}

  defp classify_issue_state(%Issue{} = issue, active_states, terminal_states) do
    normalized_state = normalize_state(issue.state)

    cond do
      state_match?(normalized_state, terminal_states) ->
        {:terminal, issue}

      state_match?(normalized_state, active_states) ->
        {:active, issue}

      true ->
        {:inactive, issue}
    end
  end

  defp state_match?(normalized_state, states) do
    states
    |> states_list()
    |> Enum.any?(fn state -> normalize_state(state) == normalized_state end)
  end

  defp states_list(%MapSet{} = states), do: MapSet.to_list(states)
  defp states_list(states) when is_list(states), do: states
  defp states_list(_states), do: []

  defp normalize_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state_name), do: ""
end
