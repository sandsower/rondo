defmodule RondoWeb.DashboardEventStream do
  # credo:disable-for-this-file
  @dialyzer {:nowarn_function,
             [
               select_run: 4,
               select_live_run: 2,
               select_matching_run: 2,
               run_meta: 2,
               provider_name: 2,
               model_name: 2,
               model_source: 2,
               action_for: 1,
               artifact_labels: 1,
               match_filters?: 2,
               facet_for: 2
             ]}
  @moduledoc """
  Helpers for the dashboard event-stream view.
  """

  @default_filters %{
    query: "",
    scope: "",
    facet: "all",
    kind: "all",
    status: "all",
    provider: "all",
    model: "all",
    run_state: "all",
    result: "all",
    from: "",
    to: "",
    sort: "time_asc"
  }

  @facet_order ~w(dispatch turn workspace tool gates decision interrupt terminal event)
  @tool_kinds MapSet.new(["tool_activity", "tool", "tool_use", "tool_started", "tool_updated", "tool_completed", "bash", "read", "write", "edit", "grep", "glob", "agent"])
  @decision_kinds MapSet.new(["continue", "stop", "retry", "pause", "fail", "terminate"])
  @terminal_kinds MapSet.new(["completed", "failed", "terminated"])
  @gate_kinds MapSet.new(["gates_completed", "gates_reused", "final_report_validated"])
  @interrupt_kinds MapSet.new(["interrupt_created", "pause"])

  @type view :: %{
          rows: [map()],
          total_count: non_neg_integer(),
          filtered_count: non_neg_integer(),
          filters: map(),
          facets: map(),
          options: map(),
          selected_run: map() | nil
        }

  @spec default_filters() :: map()
  def default_filters, do: @default_filters

  @spec normalize_filters(map()) :: map()
  def normalize_filters(params) when is_map(params) do
    Enum.reduce(@default_filters, %{}, fn {key, default}, acc ->
      value = Map.get(params, key) || Map.get(params, to_string(key)) || default
      Map.put(acc, key, normalize_filter_value(key, value, default))
    end)
  end

  def normalize_filters(_), do: @default_filters

  @spec build(map(), map() | nil, [map()] | nil, non_neg_integer(), map()) :: view()
  def build(payload, selected_issue_data, selected_runs, selected_run_index, filters) when is_map(payload) do
    filters = normalize_filters(filters)
    selected_run = select_run(payload, selected_issue_data, selected_runs, selected_run_index)
    rows = rows_for(selected_run, selected_issue_data)

    filtered_rows =
      rows
      |> Enum.filter(&match_filters?(&1, filters))
      |> sort_rows(filters.sort)

    %{
      rows: filtered_rows,
      total_count: length(rows),
      filtered_count: length(filtered_rows),
      filters: filters,
      facets: facet_counts(rows),
      options: option_lists(rows),
      selected_run: selected_run
    }
  end

  def build(_payload, _selected_issue_data, _selected_runs, _selected_run_index, filters) do
    filters = normalize_filters(filters)

    %{rows: [], total_count: 0, filtered_count: 0, filters: filters, facets: %{}, options: %{}, selected_run: nil}
  end

  @spec facet_choices(map()) :: [{String.t(), String.t(), non_neg_integer()}]
  def facet_choices(facets) when is_map(facets) do
    facets
    |> facet_names()
    |> Enum.map(fn facet -> {facet, facet_label(facet), Map.get(facets, facet, 0)} end)
  end

  def facet_choices(_), do: []

  @spec selection_params(map()) :: map()
  def selection_params(params) when is_map(params) do
    %{}
    |> put_param("issue", Map.get(params, "issue") || Map.get(params, :issue))
    |> put_param("run", Map.get(params, "run") || Map.get(params, :run))
  end

  def selection_params(_), do: %{}

  defp select_run(payload, selected_issue_data, selected_runs, selected_run_index) do
    issue_identifier = issue_identifier(selected_issue_data)
    all_runs = runs_for_identifier(payload, issue_identifier)

    cond do
      is_list(selected_runs) and selected_runs != [] ->
        selected_run = Enum.at(selected_runs, selected_run_index || 0)
        select_matching_run(all_runs, selected_run) || List.first(all_runs)

      true ->
        select_live_run(all_runs, selected_issue_data) || List.first(all_runs)
    end
  end

  defp select_live_run([], _selected_issue_data), do: nil

  defp select_live_run(runs, selected_issue_data) do
    session_id = Map.get(selected_issue_data || %{}, :session_id) || Map.get(selected_issue_data || %{}, "session_id")
    started_at = Map.get(selected_issue_data || %{}, :started_at) || Map.get(selected_issue_data || %{}, "started_at")

    runs
    |> Enum.find(&same_run?(&1, session_id, started_at))
    |> case do
      nil -> runs |> Enum.find(&is_nil(Map.get(&1, :finished_at))) || List.first(runs)
      run -> run
    end
  end

  defp select_matching_run(runs, selected_run) when is_map(selected_run) do
    session_id = Map.get(selected_run, :session_id) || Map.get(selected_run, "session_id")
    started_at = Map.get(selected_run, :started_at) || Map.get(selected_run, "started_at")
    finished_at = Map.get(selected_run, :finished_at) || Map.get(selected_run, "finished_at")

    runs
    |> Enum.find(&same_run?(&1, session_id, started_at, finished_at))
    |> case do
      nil -> runs |> Enum.sort_by(&sortable_started_at/1) |> List.first()
      run -> run
    end
  end

  defp select_matching_run(_, _), do: nil

  defp same_run?(run, session_id, started_at, finished_at \\ nil) do
    same_session? = normalized_value(Map.get(run, :session_id) || Map.get(run, "session_id")) == normalized_value(session_id)
    same_started? = normalized_value(Map.get(run, :started_at) || Map.get(run, "started_at")) == normalized_value(started_at)
    same_finished? = is_nil(finished_at) or normalized_value(Map.get(run, :finished_at) || Map.get(run, "finished_at")) == normalized_value(finished_at)

    same_session? and same_started? and same_finished?
  end

  defp runs_for_identifier(payload, issue_identifier) when is_binary(issue_identifier) do
    payload
    |> Map.get(:run_timelines, [])
    |> Enum.filter(&(normalized_value(Map.get(&1, :identifier) || Map.get(&1, "identifier")) == normalized_value(issue_identifier)))
    |> Enum.sort_by(&sortable_started_at/1)
  end

  defp runs_for_identifier(payload, _issue_identifier) do
    payload
    |> Map.get(:run_timelines, [])
    |> Enum.sort_by(&sortable_started_at/1)
  end

  defp rows_for(nil, selected_issue_data), do: fallback_rows(selected_issue_data)

  defp rows_for(selected_run, selected_issue_data) when is_map(selected_run) do
    run_meta = run_meta(selected_run, selected_issue_data)

    selected_run
    |> Map.get(:timeline, [])
    |> Enum.with_index()
    |> Enum.map(fn {step, index} -> row_from_step(step, index, selected_run, run_meta) end)
  end

  defp fallback_rows(selected_issue_data) when is_map(selected_issue_data) do
    run_meta = run_meta(%{}, selected_issue_data)

    selected_issue_data
    |> Map.get(:event_log, [])
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      timestamp = entry[:at] || entry["at"]
      kind = normalized_value(entry[:event] || entry["event"] || "event")
      summary = entry[:message] || entry["message"] || ""
      artifacts = []

      build_row(%{
        at: iso8601(timestamp),
        kind: kind,
        phase: phase_for_kind(kind),
        status: default_status(kind),
        outcome: default_outcome(kind),
        summary: summary,
        source: %{kind: "event_log", event_index: index},
        artifacts: artifacts,
        run_meta: run_meta
      })
    end)
  end

  defp fallback_rows(_), do: []

  defp row_from_step(step, index, _selected_run, run_meta) do
    step = if is_map(step), do: step, else: %{}

    build_row(%{
      at: Map.get(step, :at) || Map.get(step, "at") || Map.get(step, :timestamp) || Map.get(step, "timestamp"),
      kind: normalized_value(Map.get(step, :kind) || Map.get(step, "kind") || "event"),
      phase: normalized_value(Map.get(step, :phase) || Map.get(step, "phase") || phase_for_kind(Map.get(step, :kind) || Map.get(step, "kind"))),
      status: normalized_value(Map.get(step, :status) || Map.get(step, "status") || default_status(Map.get(step, :kind) || Map.get(step, "kind"))),
      outcome: normalized_value(Map.get(step, :outcome) || Map.get(step, "outcome") || default_outcome(Map.get(step, :kind) || Map.get(step, "kind"))),
      summary: Map.get(step, :summary) || Map.get(step, "summary") || Map.get(step, :message) || Map.get(step, "message") || normalized_value(Map.get(step, :kind) || Map.get(step, "kind") || "event"),
      source: Map.get(step, :source) || Map.get(step, "source") || %{kind: "timeline", event_index: index},
      artifacts: Map.get(step, :artifacts) || Map.get(step, "artifacts") || [],
      run_meta: run_meta,
      step_index: index
    })
  end

  defp build_row(attrs) do
    run_meta = Map.get(attrs, :run_meta, %{})
    issue_identifier = Map.get(run_meta, :identifier)
    issue_id = Map.get(run_meta, :issue_id)
    run_state = Map.get(run_meta, :run_state)
    provider = Map.get(run_meta, :provider)
    model = Map.get(run_meta, :model)
    project = Map.get(run_meta, :project)
    action = action_for(attrs)
    artifacts = artifact_labels(Map.get(attrs, :artifacts, []))
    facet = facet_for(Map.get(attrs, :kind), Map.get(attrs, :phase))
    kind = Map.get(attrs, :kind) || "event"
    status = Map.get(attrs, :status) || "n/a"
    outcome = Map.get(attrs, :outcome) || ""
    summary = Map.get(attrs, :summary) || ""
    at = Map.get(attrs, :at)

    row = %{
      id: row_id(kind, at, Map.get(attrs, :step_index, 0)),
      at: iso8601(at),
      sort_at: parse_dt(at),
      kind: kind,
      phase: Map.get(attrs, :phase) || facet,
      facet: facet,
      status: status,
      outcome: outcome,
      summary: summary,
      issue_identifier: issue_identifier,
      issue_id: issue_id,
      run_state: run_state,
      provider: provider,
      model: model,
      project: project,
      action: action,
      artifacts: artifacts,
      source: Map.get(attrs, :source) || %{},
      search_text: search_text([kind, status, outcome, summary, issue_identifier, issue_id, run_state, provider, model, project, action, Enum.join(artifacts, " "), Map.get(attrs, :at)])
    }

    Map.merge(row, %{
      status_class: status_class(status),
      kind_class: kind_class(kind),
      result_status: result_status(kind, status, outcome),
      search_text: search_text([Map.get(row, :search_text), scope_text(row)])
    })
  end

  defp run_meta(selected_run, selected_issue_data) do
    issue_identifier =
      Map.get(selected_issue_data || %{}, :issue_identifier) ||
        Map.get(selected_issue_data || %{}, "issue_identifier") ||
        Map.get(selected_run || %{}, :identifier) ||
        Map.get(selected_run || %{}, "identifier")

    issue_id = Map.get(selected_issue_data || %{}, :issue_id) || Map.get(selected_issue_data || %{}, "issue_id") || Map.get(selected_run || %{}, :issue_id) || Map.get(selected_run || %{}, "issue_id")
    run_state = Map.get(selected_issue_data || %{}, :state) || Map.get(selected_issue_data || %{}, "state") || Map.get(selected_run || %{}, :status) || Map.get(selected_run || %{}, "status")
    provider = provider_name(selected_issue_data, selected_run)
    model = model_name(selected_issue_data, selected_run)
    project = Map.get(selected_issue_data || %{}, :project) || Map.get(selected_issue_data || %{}, "project") || Map.get(selected_run || %{}, :project) || Map.get(selected_run || %{}, "project")

    %{
      identifier: issue_identifier,
      issue_id: issue_id,
      run_state: run_state,
      provider: provider,
      model: model,
      project: project
    }
  end

  defp provider_name(selected_issue_data, selected_run) do
    case model_source(selected_issue_data, selected_run) do
      %{adapter: adapter} when is_binary(adapter) ->
        adapter

      %{provider: provider} when is_binary(provider) ->
        provider

      _ ->
        Map.get(selected_issue_data || %{}, :adapter) ||
          Map.get(selected_issue_data || %{}, "adapter") ||
          Map.get(selected_run || %{}, :adapter) ||
          Map.get(selected_run || %{}, "adapter")
    end
  end

  defp model_name(selected_issue_data, selected_run) do
    source = model_source(selected_issue_data, selected_run)

    cond do
      is_map(source) and is_map(Map.get(source, :resolved)) and is_binary(Map.get(source.resolved, :model)) -> Map.get(source.resolved, :model)
      is_map(source) and is_map(Map.get(source, "resolved")) and is_binary(Map.get(source["resolved"], "model")) -> Map.get(source["resolved"], "model")
      is_map(source) and is_map(Map.get(source, :fallback)) and is_binary(Map.get(source.fallback, :model)) -> Map.get(source.fallback, :model)
      is_map(source) and is_map(Map.get(source, "fallback")) and is_binary(Map.get(source["fallback"], "model")) -> Map.get(source["fallback"], "model")
      true -> Map.get(selected_issue_data || %{}, :model) || Map.get(selected_issue_data || %{}, "model") || Map.get(selected_run || %{}, :model) || Map.get(selected_run || %{}, "model")
    end
  end

  defp model_source(selected_issue_data, selected_run) do
    Map.get(selected_issue_data || %{}, :model_routing) || Map.get(selected_issue_data || %{}, "model_routing") || Map.get(selected_run || %{}, :model_routing) ||
      Map.get(selected_run || %{}, "model_routing")
  end

  defp action_for(%{source: %{checkpoint_kind: checkpoint_kind}}) when is_binary(checkpoint_kind), do: checkpoint_kind
  defp action_for(%{source: %{"checkpoint_kind" => checkpoint_kind}}) when is_binary(checkpoint_kind), do: checkpoint_kind
  defp action_for(%{source: %{kind: source_kind}}) when is_binary(source_kind), do: source_kind
  defp action_for(%{source: %{"kind" => source_kind}}) when is_binary(source_kind), do: source_kind
  defp action_for(%{kind: kind}) when is_binary(kind), do: kind

  defp artifact_labels([]), do: []

  defp artifact_labels(artifacts) when is_list(artifacts) do
    artifacts
    |> Enum.map(fn artifact ->
      cond do
        is_map(artifact) and is_binary(Map.get(artifact, :kind)) and is_binary(Map.get(artifact, :path)) -> "#{artifact.kind}: #{artifact.path}"
        is_map(artifact) and is_binary(Map.get(artifact, "kind")) and is_binary(Map.get(artifact, "path")) -> "#{Map.get(artifact, "kind")}: #{Map.get(artifact, "path")}"
        is_map(artifact) and is_binary(Map.get(artifact, :path)) -> Map.get(artifact, :path)
        is_map(artifact) and is_binary(Map.get(artifact, "path")) -> Map.get(artifact, "path")
        is_binary(artifact) -> artifact
        true -> inspect(artifact)
      end
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp artifact_labels(_), do: []

  defp scope_text(row) do
    [Map.get(row, :issue_identifier), Map.get(row, :issue_id), Map.get(row, :project)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp row_id(kind, at, index) do
    base = [kind, iso8601(at) || "", Integer.to_string(index)] |> Enum.join("-")
    base |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.replace(~r/-+/, "-")
  end

  defp sort_rows(rows, "time_desc"), do: rows |> Enum.sort_by(fn row -> {Map.get(row, :sort_at), Map.get(row, :id)} end) |> Enum.reverse()
  defp sort_rows(rows, "kind_asc"), do: Enum.sort_by(rows, fn row -> {Map.get(row, :kind), Map.get(row, :sort_at), Map.get(row, :id)} end)
  defp sort_rows(rows, "kind_desc"), do: rows |> Enum.sort_by(fn row -> {Map.get(row, :kind), Map.get(row, :sort_at), Map.get(row, :id)} end) |> Enum.reverse()
  defp sort_rows(rows, "status_asc"), do: Enum.sort_by(rows, fn row -> {Map.get(row, :status), Map.get(row, :sort_at), Map.get(row, :id)} end)
  defp sort_rows(rows, "status_desc"), do: rows |> Enum.sort_by(fn row -> {Map.get(row, :status), Map.get(row, :sort_at), Map.get(row, :id)} end) |> Enum.reverse()
  defp sort_rows(rows, "summary_asc"), do: Enum.sort_by(rows, fn row -> {String.downcase(to_string(Map.get(row, :summary) || "")), Map.get(row, :sort_at), Map.get(row, :id)} end)
  defp sort_rows(rows, "summary_desc"), do: rows |> Enum.sort_by(fn row -> {String.downcase(to_string(Map.get(row, :summary) || "")), Map.get(row, :sort_at), Map.get(row, :id)} end) |> Enum.reverse()
  defp sort_rows(rows, _), do: Enum.sort_by(rows, fn row -> {Map.get(row, :sort_at), Map.get(row, :id)} end)

  defp match_filters?(row, filters) do
    matches_query?(row, filters.query) and
      matches_scope?(row, filters.scope) and
      matches_exact?(row.facet, filters.facet) and
      matches_exact?(row.kind, filters.kind) and
      matches_exact?(row.status, filters.status) and
      matches_exact?(row.provider, filters.provider) and
      matches_exact?(row.model, filters.model) and
      matches_exact?(row.run_state, filters.run_state) and
      matches_result?(row, filters.result) and
      matches_from?(row.sort_at, filters.from) and
      matches_to?(row.sort_at, filters.to)
  end

  defp matches_query?(_row, ""), do: true
  defp matches_query?(row, query), do: String.contains?(Map.get(row, :search_text, ""), normalized_value(query))

  defp matches_scope?(_row, ""), do: true
  defp matches_scope?(row, scope), do: String.contains?(scope_text(row) |> String.downcase(), normalized_value(scope))

  defp matches_exact?(value, filter), do: normalized_value(value) == normalized_value(filter) or filter == "all"

  defp matches_result?(_row, "all"), do: true
  defp matches_result?(row, result), do: normalized_value(Map.get(row, :result_status)) == normalized_value(result)

  defp matches_from?(_sort_at, ""), do: true
  defp matches_from?(sort_at, from), do: DateTime.compare(sort_at, parse_dt(from)) != :lt

  defp matches_to?(_sort_at, ""), do: true
  defp matches_to?(sort_at, to), do: DateTime.compare(sort_at, parse_dt(to)) != :gt

  defp facet_for(kind, phase) do
    cond do
      kind in @gate_kinds -> "gates"
      kind in @interrupt_kinds -> "interrupt"
      kind in @terminal_kinds -> "terminal"
      kind in @decision_kinds -> "decision"
      kind in @tool_kinds or phase == "tool" -> "tool"
      phase == "turn" -> "turn"
      phase == "dispatch" -> "dispatch"
      phase == "workspace" -> "workspace"
      true -> "event"
    end
  end

  defp facet_counts(rows) do
    rows
    |> Enum.group_by(& &1.facet)
    |> Enum.map(fn {facet, facet_rows} -> {facet, length(facet_rows)} end)
    |> Map.new()
  end

  defp facet_names(facets) do
    known = Enum.filter(@facet_order, &Map.has_key?(facets, &1))
    extras = facets |> Map.keys() |> Enum.reject(&(&1 in @facet_order)) |> Enum.sort()
    known ++ extras
  end

  defp facet_label(facet) when is_binary(facet), do: String.capitalize(facet)
  defp facet_label(facet), do: facet |> to_string() |> String.capitalize()

  defp option_lists(rows) do
    %{
      kinds: unique_values(rows, :kind),
      statuses: unique_values(rows, :status),
      providers: unique_values(rows, :provider),
      models: unique_values(rows, :model),
      run_states: unique_values(rows, :run_state),
      results: unique_values(rows, :result_status)
    }
  end

  defp unique_values(rows, key) do
    rows
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase(to_string(&1)))
  end

  defp status_class(status) do
    normalized = normalized_value(status)

    cond do
      normalized in ["fail", "failed", "error", "terminated"] -> "state-badge state-badge-danger"
      normalized in ["pass", "passed", "completed", "ready", "reused"] -> "state-badge state-badge-active"
      normalized in ["pause", "paused", "retry", "retrying", "queued", "waiting", "blocked"] -> "state-badge state-badge-warning"
      true -> "state-badge"
    end
  end

  defp kind_class(kind) do
    cond do
      kind in @gate_kinds -> "event-kind-pill event-kind-gate"
      kind in @interrupt_kinds -> "event-kind-pill event-kind-interrupt"
      kind in @terminal_kinds -> "event-kind-pill event-kind-terminal"
      kind in @decision_kinds -> "event-kind-pill event-kind-decision"
      kind in @tool_kinds -> "event-kind-pill event-kind-tool"
      true -> "event-kind-pill"
    end
  end

  defp result_status(kind, status, outcome) do
    cond do
      kind in @terminal_kinds -> status
      kind in @gate_kinds -> status || outcome
      kind in @decision_kinds -> status || outcome
      true -> nil
    end
  end

  defp default_status(kind) do
    cond do
      kind in @terminal_kinds -> kind
      kind in @gate_kinds -> "completed"
      kind in @decision_kinds -> kind
      kind in @tool_kinds -> "completed"
      true -> "event"
    end
  end

  defp default_outcome(kind) do
    cond do
      kind in @terminal_kinds -> kind
      kind in @gate_kinds -> kind
      kind in @decision_kinds -> kind
      kind in @tool_kinds -> "tool"
      true -> "event"
    end
  end

  defp phase_for_kind(kind) do
    cond do
      kind in @gate_kinds -> "gates"
      kind in @interrupt_kinds -> "interrupt"
      kind in @terminal_kinds -> "terminal"
      kind in @decision_kinds -> "decision"
      kind in @tool_kinds -> "tool"
      true -> "event"
    end
  end

  defp search_text(values) do
    values
    |> List.wrap()
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.map(&normalized_value/1)
    |> Enum.join(" ")
  end

  defp normalized_value(nil), do: ""
  defp normalized_value(value) when is_binary(value), do: String.downcase(value)
  defp normalized_value(value) when is_atom(value), do: value |> Atom.to_string() |> String.downcase()
  defp normalized_value(value), do: value |> to_string() |> String.downcase()

  defp blank?(value), do: normalized_value(value) == ""

  defp sortable_started_at(%{started_at: started_at}), do: parse_dt(started_at)
  defp sortable_started_at(%{"started_at" => started_at}), do: parse_dt(started_at)
  defp sortable_started_at(_), do: ~U[1970-01-01 00:00:00Z]

  defp parse_dt(%DateTime{} = dt), do: dt
  defp parse_dt(nil), do: ~U[1970-01-01 00:00:00Z]
  defp parse_dt(""), do: ~U[1970-01-01 00:00:00Z]

  defp parse_dt(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} ->
        dt

      _ ->
        case NaiveDateTime.from_iso8601(ts) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> ~U[1970-01-01 00:00:00Z]
        end
    end
  end

  defp parse_dt(_), do: ~U[1970-01-01 00:00:00Z]

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(ts) when is_binary(ts), do: ts
  defp iso8601(other), do: if(other, do: to_string(other), else: nil)

  defp put_param(map, _key, nil), do: map
  defp put_param(map, _key, ""), do: map
  defp put_param(map, key, value), do: Map.put(map, key, value)

  defp normalize_filter_value(_key, "", default), do: default
  defp normalize_filter_value(key, value, _default) when key in [:from, :to], do: String.trim(to_string(value))
  defp normalize_filter_value(_key, value, _default) when is_binary(value), do: String.trim(value)
  defp normalize_filter_value(_key, value, _default), do: to_string(value)

  defp issue_identifier(selected_issue_data) do
    Map.get(selected_issue_data || %{}, :issue_identifier) ||
      Map.get(selected_issue_data || %{}, "issue_identifier") ||
      Map.get(selected_issue_data || %{}, :identifier) ||
      Map.get(selected_issue_data || %{}, "identifier")
  end
end
