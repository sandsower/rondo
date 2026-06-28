defmodule Rondo.Tracker.UpdateDetector do
  # credo:disable-for-this-file
  @moduledoc """
  Normalizes tracker snapshots and classifies live issue updates.
  """

  alias Rondo.Linear.Issue

  @workpad_marker "<!-- rondo-workpad"
  @pause_phrases [
    "ignore previous",
    "conflict",
    "contradict",
    "ambiguous",
    "unclear",
    "policy",
    "risk",
    "security",
    "blocker",
    "blocked",
    "do not",
    "don't",
    "must not",
    "cannot",
    "can't",
    "manual approval",
    "change of plan",
    "stop automation"
  ]

  @spec snapshot_from_issue(map(), map()) :: map()
  def snapshot_from_issue(issue, extras \\ %{}) when is_map(issue) and is_map(extras) do
    issue
    |> issue_snapshot()
    |> Map.merge(normalize_extra_snapshot(extras))
  end

  @spec detect_update(map() | nil, map(), keyword()) :: map()
  def detect_update(previous_snapshot, current_snapshot, opts \\ []) when is_map(current_snapshot) do
    previous_snapshot = normalize_snapshot(previous_snapshot)
    current_snapshot = normalize_snapshot(current_snapshot)

    changes = diff_snapshots(previous_snapshot, current_snapshot, opts)
    workpad_comments = comment_changes(current_snapshot, previous_snapshot) |> Map.get(:ignored_workpad_comments, [])

    {action, classification, reason, guidance_severity} = classify_update(changes, workpad_comments, previous_snapshot, current_snapshot)

    %{
      action: action,
      classification: classification,
      reason: reason,
      guidance_severity: guidance_severity,
      summary: summary_for(changes, workpad_comments, action, classification),
      prompt_lines: prompt_lines(current_snapshot, changes, workpad_comments, action, classification),
      changes: changes,
      issue: issue_summary(current_snapshot),
      previous_snapshot: previous_snapshot,
      snapshot: current_snapshot
    }
  end

  @spec prompt_lines(map(), [map()], [map()], atom(), atom()) :: [String.t()]
  def prompt_lines(current_snapshot, changes, workpad_comments, action, classification) do
    lines =
      [
        "Live tracker update observed.",
        "Action: #{action}",
        "Classification: #{classification}",
        "Issue: #{issue_line(current_snapshot)}"
      ]
      |> maybe_put_change_lines(changes)
      |> maybe_put_workpad_lines(workpad_comments)

    lines ++ ["Use the live tracker update above instead of stale assumptions from earlier turns."]
  end

  @spec snapshot_changed?(map() | nil, map()) :: boolean()
  def snapshot_changed?(previous_snapshot, current_snapshot) when is_map(current_snapshot) do
    previous_snapshot = normalize_snapshot(previous_snapshot)
    current_snapshot = normalize_snapshot(current_snapshot)

    diff_snapshots(previous_snapshot, current_snapshot, []) != []
  end

  def snapshot_changed?(_previous_snapshot, _current_snapshot), do: false

  @spec issue_summary(map()) :: map()
  def issue_summary(snapshot) when is_map(snapshot) do
    %{
      "id" => snapshot_value(snapshot, "id"),
      "identifier" => snapshot_value(snapshot, "identifier"),
      "title" => snapshot_value(snapshot, "title"),
      "state" => snapshot_value(snapshot, "state"),
      "updated_at" => snapshot_value(snapshot, "updated_at")
    }
    |> drop_nil_values()
  end

  def issue_summary(_snapshot), do: %{}

  @spec workpad_comment?(map()) :: boolean()
  def workpad_comment?(comment) when is_map(comment) do
    body = snapshot_value(comment, "body") || ""
    String.contains?(body, @workpad_marker)
  end

  def workpad_comment?(_comment), do: false

  @spec comment_summary(map()) :: String.t()
  def comment_summary(comment) when is_map(comment) do
    author = snapshot_value(comment, "author_name") || snapshot_value(comment, "user_name") || snapshot_value(comment, "creator_name") || "unknown"
    body = snapshot_value(comment, "body") || ""
    preview = body |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 180)
    "comment by #{author}: #{preview}"
  end

  def comment_summary(_comment), do: "comment update"

  defp normalize_snapshot(nil), do: %{}
  defp normalize_snapshot(snapshot) when is_map(snapshot), do: snapshot
  defp normalize_snapshot(_other), do: %{}

  defp diff_snapshots(previous_snapshot, current_snapshot, _opts) do
    base_fields = ["title", "description", "state", "labels", "blocked_by", "relations", "inverse_relations", "attachments", "custom_fields"]

    text_changes =
      base_fields
      |> Enum.flat_map(fn field -> field_change(previous_snapshot, current_snapshot, field) end)

    comment_change = comment_changes(current_snapshot, previous_snapshot)
    updated_at_change = field_change(previous_snapshot, current_snapshot, "updated_at")

    text_changes ++ updated_at_change ++ comment_change[:changes]
  end

  defp comment_changes(current_snapshot, previous_snapshot) do
    current_comments = normalized_comments(snapshot_value(current_snapshot, "comments"))
    previous_comments = normalized_comments(snapshot_value(previous_snapshot, "comments"))

    previous_by_id = Map.new(previous_comments, fn comment -> {comment["id"], comment} end)

    {substantive_changes, ignored_workpad_comments} =
      Enum.reduce(current_comments, {[], []}, fn comment, {changes, ignored} ->
        cond do
          workpad_comment?(comment) and not Map.has_key?(previous_by_id, comment["id"]) ->
            {changes, [comment | ignored]}

          workpad_comment?(comment) ->
            {changes, [comment | ignored]}

          true ->
            previous_comment = Map.get(previous_by_id, comment["id"])

            cond do
              is_nil(previous_comment) ->
                {[comment_change("added", nil, comment, comment_summary(comment)) | changes], ignored}

              comment_body_changed?(previous_comment, comment) ->
                {[comment_change("updated", previous_comment, comment, comment_summary(comment)) | changes], ignored}

              true ->
                {changes, ignored}
            end
        end
      end)

    removed_comments =
      previous_comments
      |> Enum.reject(fn comment -> workpad_comment?(comment) end)
      |> Enum.reject(fn comment -> Enum.any?(current_comments, &(&1["id"] == comment["id"])) end)
      |> Enum.map(fn comment -> comment_change("removed", comment, nil, comment_summary(comment)) end)

    %{
      changes: Enum.reverse(substantive_changes) ++ removed_comments,
      ignored_workpad_comments: Enum.reverse(ignored_workpad_comments)
    }
  end

  defp comment_body_changed?(previous_comment, current_comment) do
    snapshot_value(previous_comment, "body") != snapshot_value(current_comment, "body") or
      snapshot_value(previous_comment, "updated_at") != snapshot_value(current_comment, "updated_at")
  end

  defp comment_change(kind, from, to, summary) do
    %{
      field: "comments",
      kind: kind,
      from: maybe_comment_snapshot(from),
      to: maybe_comment_snapshot(to),
      summary: summary
    }
  end

  defp maybe_comment_snapshot(nil), do: nil
  defp maybe_comment_snapshot(comment) when is_map(comment), do: comment

  defp classify_update(changes, workpad_comments, previous_snapshot, current_snapshot) do
    cond do
      changes == [] and workpad_comments != [] ->
        {:ignore, :self_authored_workpad_comment, "self-authored workpad comment ignored", "info"}

      changes == [] ->
        {:ignore, :no_op, "updated_at changed without substantive tracker diffs", "info"}

      blocker_or_relation_change?(changes) ->
        {:pause, :relation_or_blocker_change, "blocker or relation change detected", "critical"}

      policy_or_risk_change?(changes) ->
        {:pause, :policy_or_risk_change, "policy or risk change detected", "critical"}

      conflicting_change?(changes, previous_snapshot, current_snapshot) ->
        {:pause, :conflicting_or_ambiguous_update, "conflicting or ambiguous update detected", "critical"}

      reviewer_feedback_change?(changes) ->
        {:inject, :reviewer_operator_feedback, "reviewer or operator feedback detected", "info"}

      true ->
        {:inject, :new_requirements_or_scope_change, "substantive tracker update detected", "info"}
    end
  end

  defp blocker_or_relation_change?(changes) do
    Enum.any?(changes, fn change -> change.field in ["blocked_by", "relations", "inverse_relations"] end)
  end

  defp policy_or_risk_change?(changes) do
    Enum.any?(changes, fn change ->
      change.field in ["labels", "attachments", "custom_fields"] and text_has_pause_phrase?(snapshot_text(change))
    end) or
      Enum.any?(changes, fn change ->
        change.field in ["title", "description", "comments"] and text_has_pause_phrase?(snapshot_text(change))
      end)
  end

  defp conflicting_change?(changes, _previous_snapshot, _current_snapshot) do
    Enum.any?(changes, fn change ->
      change.field in ["title", "description", "comments", "custom_fields"] and text_has_conflict_phrase?(snapshot_text(change))
    end)
  end

  defp reviewer_feedback_change?(changes) do
    Enum.any?(changes, fn change -> change.field == "comments" end)
  end

  defp snapshot_text(%{from: from, to: to}) do
    [from, to]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map_join(" ", &inspect/1)
    |> String.downcase()
  end

  defp text_has_pause_phrase?(text) when is_binary(text) do
    Enum.any?(@pause_phrases, &String.contains?(text, &1))
  end

  defp text_has_conflict_phrase?(text) when is_binary(text) do
    Enum.any?(["conflict", "contradict", "ambiguous", "unclear", "ignore previous", "instead"], &String.contains?(text, &1))
  end

  defp summary_for(changes, workpad_comments, action, classification) do
    cond do
      changes == [] and workpad_comments != [] ->
        "Ignored self-authored workpad comment"

      changes == [] ->
        "No substantive tracker change"

      true ->
        change_summary = changes |> Enum.map(& &1.summary) |> Enum.reject(&is_nil/1) |> Enum.join("; ")
        "#{action} #{classification}: #{change_summary}"
    end
  end

  defp maybe_put_change_lines(lines, changes) do
    change_lines =
      changes
      |> Enum.flat_map(fn change ->
        ["- #{change.field} #{change.kind || "changed"}: #{change.summary}"]
      end)

    lines ++ change_lines
  end

  defp maybe_put_workpad_lines(lines, []), do: lines

  defp maybe_put_workpad_lines(lines, workpad_comments) do
    lines ++ Enum.map(workpad_comments, fn comment -> "- ignored workpad: #{comment_summary(comment)}" end)
  end

  defp issue_line(snapshot) do
    [snapshot_value(snapshot, "identifier"), snapshot_value(snapshot, "title")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" — ")
  end

  defp issue_snapshot(issue) when is_struct(issue, Issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "state" => issue.state,
      "updated_at" => issue.updated_at,
      "labels" => issue.labels || [],
      "blocked_by" => issue.blocked_by || []
    }
    |> drop_nil_values()
  end

  defp issue_snapshot(issue) when is_map(issue) do
    %{
      "id" => snapshot_value(issue, "id"),
      "identifier" => snapshot_value(issue, "identifier"),
      "title" => snapshot_value(issue, "title"),
      "description" => snapshot_value(issue, "description"),
      "state" => snapshot_value(issue, "state"),
      "updated_at" => snapshot_value(issue, "updated_at"),
      "labels" => normalize_string_list(snapshot_value(issue, "labels") || snapshot_value(issue, :labels) || []),
      "blocked_by" => normalize_relations(snapshot_value(issue, "blocked_by") || snapshot_value(issue, :blocked_by) || []),
      "relations" => normalize_relations(snapshot_value(issue, "relations") || snapshot_value(issue, :relations) || []),
      "inverse_relations" => normalize_relations(snapshot_value(issue, "inverse_relations") || snapshot_value(issue, :inverse_relations) || []),
      "attachments" => normalize_attachments(snapshot_value(issue, "attachments") || snapshot_value(issue, :attachments) || []),
      "comments" => normalized_comments(snapshot_value(issue, "comments") || snapshot_value(issue, :comments) || []),
      "custom_fields" => snapshot_value(issue, "custom_fields") || snapshot_value(issue, :custom_fields)
    }
    |> drop_nil_values()
  end

  defp normalize_extra_snapshot(extras) when is_map(extras) do
    extras
    |> Enum.into(%{}, fn {key, value} -> {normalize_key(key), normalize_snapshot_value(value)} end)
    |> Map.new(fn {key, value} -> {key, value} end)
  end

  defp normalize_snapshot_value(%DateTime{} = dt), do: DateTime.to_iso8601(DateTime.truncate(dt, :second))
  defp normalize_snapshot_value(value) when is_list(value), do: Enum.map(value, &normalize_snapshot_value/1)
  defp normalize_snapshot_value(value) when is_map(value), do: Map.new(value, fn {key, nested} -> {normalize_key(key), normalize_snapshot_value(nested)} end)
  defp normalize_snapshot_value(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_scalar/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp normalize_string_list(value) when is_binary(value), do: [value]
  defp normalize_string_list(_value), do: []

  defp normalize_relations(value) when is_list(value) do
    value
    |> Enum.map(&normalize_relation/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&relation_sort_key/1)
  end

  defp normalize_relations(%{"nodes" => nodes}) when is_list(nodes), do: normalize_relations(nodes)
  defp normalize_relations(_value), do: []

  defp normalize_relation(%{"issue" => issue} = relation) when is_map(issue) do
    %{
      "type" => snapshot_value(relation, "type"),
      "issue_id" => snapshot_value(issue, "id"),
      "issue_identifier" => snapshot_value(issue, "identifier"),
      "issue_state" => get_in(issue, ["state", "name"]),
      "issue_title" => snapshot_value(issue, "title")
    }
    |> drop_nil_values()
  end

  defp normalize_relation(%{issue: issue} = relation) when is_map(issue) do
    %{
      "type" => snapshot_value(relation, "type") || snapshot_value(relation, :type),
      "issue_id" => snapshot_value(issue, "id") || snapshot_value(issue, :id),
      "issue_identifier" => snapshot_value(issue, "identifier") || snapshot_value(issue, :identifier),
      "issue_state" => get_in(issue, ["state", "name"]) || get_in(issue, [:state, :name]),
      "issue_title" => snapshot_value(issue, "title") || snapshot_value(issue, :title)
    }
    |> drop_nil_values()
  end

  defp normalize_relation(%{"id" => id, "identifier" => identifier} = relation) do
    %{
      "type" => snapshot_value(relation, "type"),
      "issue_id" => id,
      "issue_identifier" => identifier,
      "issue_state" => get_in(relation, ["state", "name"]),
      "issue_title" => snapshot_value(relation, "title")
    }
    |> drop_nil_values()
  end

  defp normalize_relation(_value), do: nil

  defp relation_sort_key(relation) do
    [Map.get(relation, "type"), Map.get(relation, "issue_identifier"), Map.get(relation, "issue_id")]
  end

  defp normalize_attachments(value) when is_list(value) do
    value
    |> Enum.map(&normalize_attachment/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&attachment_sort_key/1)
  end

  defp normalize_attachments(%{"nodes" => nodes}) when is_list(nodes), do: normalize_attachments(nodes)
  defp normalize_attachments(_value), do: []

  defp normalize_attachment(%{} = attachment) do
    %{
      "id" => snapshot_value(attachment, "id"),
      "title" => snapshot_value(attachment, "title"),
      "subtitle" => snapshot_value(attachment, "subtitle"),
      "url" => snapshot_value(attachment, "url"),
      "source_type" => snapshot_value(attachment, "sourceType") || snapshot_value(attachment, "source_type"),
      "metadata" => snapshot_value(attachment, "metadata")
    }
    |> drop_nil_values()
  end

  defp attachment_sort_key(attachment) do
    [Map.get(attachment, "title"), Map.get(attachment, "url"), Map.get(attachment, "id")]
  end

  defp normalized_comments(value) when is_list(value) do
    value
    |> Enum.map(&normalize_comment/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&comment_sort_key/1)
  end

  defp normalized_comments(%{"nodes" => nodes}) when is_list(nodes), do: normalized_comments(nodes)
  defp normalized_comments(_value), do: []

  defp normalize_comment(%{} = comment) do
    %{
      "id" => snapshot_value(comment, "id"),
      "body" => snapshot_value(comment, "body") || snapshot_value(comment, "content"),
      "updated_at" => snapshot_value(comment, "updatedAt") || snapshot_value(comment, "updated_at"),
      "created_at" => snapshot_value(comment, "createdAt") || snapshot_value(comment, "created_at"),
      "author_id" => author_id(comment),
      "author_name" => author_name(comment),
      "workpad" => workpad_comment?(comment)
    }
    |> drop_nil_values()
  end

  defp normalize_comment(_value), do: nil

  defp comment_sort_key(comment) do
    [Map.get(comment, "updated_at") || Map.get(comment, "created_at") || "", Map.get(comment, "id") || ""]
  end

  defp author_id(comment) do
    snapshot_value(comment, "author_id") ||
      snapshot_value(comment, "user_id") ||
      snapshot_value(comment, "creator_id") ||
      get_in(comment, ["user", "id"]) ||
      get_in(comment, ["creator", "id"]) ||
      get_in(comment, [:user, :id]) ||
      get_in(comment, [:creator, :id])
  end

  defp author_name(comment) do
    snapshot_value(comment, "author_name") ||
      snapshot_value(comment, "user_name") ||
      snapshot_value(comment, "creator_name") ||
      get_in(comment, ["user", "name"]) ||
      get_in(comment, ["creator", "name"]) ||
      get_in(comment, [:user, :name]) ||
      get_in(comment, [:creator, :name])
  end

  defp field_change(previous_snapshot, current_snapshot, field) do
    previous_value = snapshot_value(previous_snapshot, field)
    current_value = snapshot_value(current_snapshot, field)

    if previous_value == current_value do
      []
    else
      [
        %{
          field: field,
          kind: "changed",
          from: previous_value,
          to: current_value,
          summary: "#{field} changed"
        }
      ]
    end
  end

  defp snapshot_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp snapshot_value(_map, _key), do: nil

  defp normalize_scalar(value) when is_binary(value), do: value
  defp normalize_scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_scalar(value) when is_integer(value) or is_float(value) or is_boolean(value), do: value |> to_string()
  defp normalize_scalar(%DateTime{} = dt), do: DateTime.to_iso8601(DateTime.truncate(dt, :second))
  defp normalize_scalar(value), do: if(is_nil(value), do: nil, else: inspect(value))

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
