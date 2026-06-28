defmodule Rondo.Tracker.UpdateDetectorTest do
  use ExUnit.Case, async: true

  alias Rondo.Linear.Issue
  alias Rondo.Tracker.UpdateDetector

  test "ignores self-authored workpad comments" do
    previous = snapshot(%Issue{id: "1", identifier: "RON-1", title: "Ticket", state: "In Progress"})

    current =
      snapshot(
        %Issue{id: "1", identifier: "RON-1", title: "Ticket", state: "In Progress"},
        %{comments: [workpad_comment("c-1", "<!-- rondo-workpad --> progress update")]}
      )

    detection = UpdateDetector.detect_update(previous, current)

    assert detection.action == :ignore
    assert detection.classification == :self_authored_workpad_comment
    assert detection.summary == "Ignored self-authored workpad comment"
  end

  test "injects body edits and new comments" do
    previous = snapshot(%Issue{id: "1", identifier: "RON-1", title: "Ticket", description: "old", state: "In Progress"})

    current =
      snapshot(
        %Issue{id: "1", identifier: "RON-1", title: "Ticket", description: "new", state: "In Progress"},
        %{comments: [normal_comment("c-1", "Customer clarified the request")]}
      )

    detection = UpdateDetector.detect_update(previous, current)

    assert detection.action == :inject
    assert detection.classification in [:reviewer_operator_feedback, :new_requirements_or_scope_change]
    assert Enum.any?(detection.changes, &(&1.field == "description"))
    assert Enum.any?(detection.prompt_lines, &String.contains?(&1, "Live tracker update observed."))
  end

  test "pauses on blocker or relation changes" do
    previous = snapshot(%Issue{id: "1", identifier: "RON-1", title: "Ticket", state: "In Progress"})

    current =
      snapshot(%Issue{id: "1", identifier: "RON-1", title: "Ticket", state: "In Progress", blocked_by: [%{id: "b-1", identifier: "BLK-1", state: "In Progress"}]})

    detection = UpdateDetector.detect_update(previous, current)

    assert detection.action == :pause
    assert detection.classification == :relation_or_blocker_change
    assert detection.guidance_severity == "critical"
  end

  test "pauses on conflicting guidance text" do
    previous = snapshot(%Issue{id: "1", identifier: "RON-1", title: "Ticket", description: "old", state: "In Progress"})

    current =
      snapshot(
        %Issue{id: "1", identifier: "RON-1", title: "Ticket", description: "ignore previous plan and do not continue", state: "In Progress"},
        %{comments: [normal_comment("c-1", "This is ambiguous and conflicts with the prior direction")]}
      )

    detection = UpdateDetector.detect_update(previous, current)

    assert detection.action == :pause
    assert detection.classification in [:policy_or_risk_change, :conflicting_or_ambiguous_update]
  end

  defp snapshot(%Issue{} = issue, extras \\ %{}) do
    UpdateDetector.snapshot_from_issue(issue, extras)
  end

  defp workpad_comment(id, body) do
    %{
      "id" => id,
      "body" => body,
      "created_at" => nil,
      "updated_at" => nil,
      "author_name" => "Taylor"
    }
  end

  defp normal_comment(id, body) do
    %{
      "id" => id,
      "body" => body,
      "created_at" => nil,
      "updated_at" => nil,
      "author_name" => "Taylor"
    }
  end
end
