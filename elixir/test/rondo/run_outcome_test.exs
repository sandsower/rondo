defmodule Rondo.RunOutcomeTest do
  use Rondo.TestSupport

  alias Rondo.RunOutcome

  test "display classifies finished outcomes from tracker state and exit reason" do
    assert RunOutcome.display(%{exit_reason: "completed", state: "In Progress"}) == %{
             kind: "success",
             label: "success",
             class: "state-badge state-badge-active",
             detail: nil
           }

    assert RunOutcome.display(%{exit_reason: "terminated", state: "Human Review"}) == %{
             kind: "review_handoff",
             label: "review handoff",
             class: "state-badge state-badge-handoff",
             detail: "issue → Human Review"
           }

    assert RunOutcome.display(%{exit_reason: "terminated", state: "Done"}) == %{
             kind: "merged_done",
             label: "merged/done",
             class: "state-badge state-badge-active",
             detail: "issue → Done"
           }

    assert RunOutcome.display(%{exit_reason: "failed", state: "In Progress"}) == %{
             kind: "failed",
             label: "failed",
             class: "state-badge state-badge-danger",
             detail: nil
           }

    assert RunOutcome.display(%{exit_reason: "paused", state: "Blocked"}) == %{
             kind: "blocked_paused",
             label: "blocked/paused",
             class: "state-badge state-badge-warning",
             detail: "issue → Blocked"
           }

    assert RunOutcome.display(%{exit_reason: "terminated", state: "In Progress"}) == %{
             kind: "terminated",
             label: "terminated",
             class: "state-badge state-badge-danger",
             detail: nil
           }
  end

  test "kind and presentation helpers accept string-keyed and raw inputs" do
    assert RunOutcome.kind(nil) == :terminated
    assert RunOutcome.kind(:completed) == :success
    assert RunOutcome.kind("handoff") == :review_handoff
    assert RunOutcome.kind("canceled") == :canceled
    assert RunOutcome.kind("paused") == :blocked_paused
    assert RunOutcome.kind(%{"exit_reason" => "cancelled"}) == :canceled
    assert RunOutcome.kind(%{"non_active_state" => "Human Review", "exit_reason" => "terminated"}) == :review_handoff
    assert RunOutcome.kind(%{"state" => "Done", "exit_reason" => "ignored"}) == :merged_done
    assert RunOutcome.kind(%{non_active_state: "Done", exit_reason: "terminated"}) == :merged_done
    assert RunOutcome.kind(%{state: "Blocked", exit_reason: "terminated"}) == :blocked_paused
    assert RunOutcome.kind(%{state: "Incomplete", exit_reason: "terminated"}) == :terminated

    assert RunOutcome.label(:canceled) == "canceled"
    assert RunOutcome.label(:unknown) == "terminated"
    assert RunOutcome.badge_class(:canceled) == "state-badge state-badge-warning"
    assert RunOutcome.badge_class(:unknown) == "state-badge state-badge-danger"
    assert RunOutcome.display(%{"state" => "Human Review", "exit_reason" => "terminated"}).kind == "review_handoff"
    assert RunOutcome.display(%{"state" => "", "exit_reason" => "terminated"}).kind == "terminated"

    assert RunOutcome.display(%{state: "Canceled"}) == %{
             kind: "canceled",
             label: "canceled",
             class: "state-badge state-badge-warning",
             detail: "issue → Canceled"
           }

    assert RunOutcome.display(%{exit_reason: "handed_off"}) == %{
             kind: "review_handoff",
             label: "review handoff",
             class: "state-badge state-badge-handoff",
             detail: nil
           }
  end
end
