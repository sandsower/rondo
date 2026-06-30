defmodule Rondo.RunOutcome do
  @moduledoc """
  Normalized run outcome semantics for finished-run surfaces.
  """

  alias Rondo.Config

  @type display :: %{
          kind: String.t(),
          label: String.t(),
          class: String.t(),
          detail: String.t() | nil
        }

  @spec display(map() | String.t() | atom() | nil) :: display()
  def display(entry_or_reason) do
    kind = kind(entry_or_reason)
    state = state_hint(entry_or_reason)

    %{
      kind: Atom.to_string(kind),
      label: label(kind),
      class: badge_class(kind),
      detail: detail(kind, state)
    }
  end

  @spec kind(map() | String.t() | atom() | nil) :: atom()
  def kind(entry_or_reason) do
    state = state_hint(entry_or_reason)
    raw_reason = exit_reason(entry_or_reason)

    kind_from_state(state) || kind_from_reason(raw_reason)
  end

  @spec label(atom()) :: String.t()
  def label(:success), do: "success"
  def label(:review_handoff), do: "review handoff"
  def label(:merged_done), do: "merged/done"
  def label(:blocked_paused), do: "blocked/paused"
  def label(:failed), do: "failed"
  def label(:canceled), do: "canceled"
  def label(:terminated), do: "terminated"
  def label(_kind), do: "terminated"

  @spec badge_class(atom()) :: String.t()
  def badge_class(:success), do: "state-badge state-badge-active"
  def badge_class(:review_handoff), do: "state-badge state-badge-handoff"
  def badge_class(:merged_done), do: "state-badge state-badge-active"
  def badge_class(:blocked_paused), do: "state-badge state-badge-warning"
  def badge_class(:failed), do: "state-badge state-badge-danger"
  def badge_class(:canceled), do: "state-badge state-badge-warning"
  def badge_class(:terminated), do: "state-badge state-badge-danger"
  def badge_class(_kind), do: "state-badge state-badge-danger"

  defp detail(:success, _state), do: nil
  defp detail(:failed, _state), do: nil
  defp detail(:terminated, _state), do: nil
  defp detail(:review_handoff, state), do: state_detail(state)
  defp detail(:merged_done, state), do: state_detail(state)
  defp detail(:blocked_paused, state), do: state_detail(state)
  defp detail(:canceled, state), do: state_detail(state)

  defp kind_from_state(state) when is_binary(state) do
    normalized = normalize(state)

    cond do
      canceled_state?(normalized) -> :canceled
      blocked_state?(normalized) -> :blocked_paused
      review_state?(normalized) -> :review_handoff
      done_state?(normalized) -> :merged_done
      true -> nil
    end
  end

  defp kind_from_state(_state), do: nil

  defp kind_from_reason(reason) do
    cond do
      failed_reason?(reason) -> :failed
      canceled_reason?(reason) -> :canceled
      blocked_reason?(reason) -> :blocked_paused
      completed_reason?(reason) -> :success
      handed_off_reason?(reason) -> :review_handoff
      terminated_reason?(reason) -> :terminated
      true -> :terminated
    end
  end

  defp state_detail(nil), do: nil
  defp state_detail(state), do: "issue → #{state}"

  defp state_hint(%{non_active_state: non_active_state}) when is_binary(non_active_state) and non_active_state != "",
    do: non_active_state

  defp state_hint(%{state: state}) when is_binary(state) and state != "", do: state

  defp state_hint(%{"non_active_state" => non_active_state}) when is_binary(non_active_state) and non_active_state != "",
    do: non_active_state

  defp state_hint(%{"state" => state}) when is_binary(state) and state != "", do: state
  defp state_hint(_other), do: nil

  defp exit_reason(%{exit_reason: exit_reason}) when is_binary(exit_reason), do: normalize(exit_reason)
  defp exit_reason(%{"exit_reason" => exit_reason}) when is_binary(exit_reason), do: normalize(exit_reason)
  defp exit_reason(reason) when is_binary(reason), do: normalize(reason)
  defp exit_reason(reason) when is_atom(reason), do: reason |> Atom.to_string() |> normalize()
  defp exit_reason(_other), do: nil

  defp normalize(value), do: value |> String.trim() |> String.downcase()

  defp completed_reason?("completed"), do: true
  defp completed_reason?(_reason), do: false

  defp handed_off_reason?("handed_off"), do: true
  defp handed_off_reason?("handoff"), do: true
  defp handed_off_reason?(_reason), do: false

  defp terminated_reason?("terminated"), do: true
  defp terminated_reason?(_reason), do: false

  defp failed_reason?("failed"), do: true
  defp failed_reason?(reason), do: is_binary(reason) and String.starts_with?(reason, "exited:")

  defp canceled_reason?("canceled"), do: true
  defp canceled_reason?("cancelled"), do: true
  defp canceled_reason?(_reason), do: false

  defp blocked_reason?("paused"), do: true
  defp blocked_reason?(_reason), do: false

  defp review_state?(state) when is_binary(state) do
    state in [normalize(Config.release_loop_review_state()), "review", "in review"]
  end

  defp done_state?(state) when is_binary(state) do
    state in [
      normalize(Config.release_loop_done_state()),
      "done",
      "merged",
      "closed",
      "complete",
      "completed"
    ]
  end

  defp blocked_state?(state) when is_binary(state), do: state in ["blocked", "pause", "paused"]

  defp canceled_state?(state) when is_binary(state), do: state in ["canceled", "cancelled"]
end
