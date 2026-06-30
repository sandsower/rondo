defmodule RondoWeb.EventInspector do
  @moduledoc """
  Builds dashboard-friendly event lists and event detail models.
  """

  @prompt_event_names ~w(assistant assistant_message prompt request turn_started invocation_started)
  @result_event_names ~w(result invocation_completed turn_completed final_report final_report_validated)
  @gate_event_names ~w(gates_completed gates_reused)
  @system_event_names ~w(session_started notification rate_limit warning system)
  @tool_event_names ~w(linear github bash read write edit grep glob agent tool tool_started tool_updated tool_completed)
  @artifact_path_keys ~w(path file_path source_path artifact_path results_path state_path checkpoint_path final_report_path)
  @event_categories [:all, :prompt, :tool, :result, :gate, :system, :other]
  @detail_event_limit 250

  @spec event_entries(map(), map() | keyword()) :: [map()]
  def event_entries(selected_issue_data, filters \\ %{}) do
    selected_issue_data
    |> selected_event_log()
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> event_entry(entry, index, selected_issue_data) end)
    |> apply_filters(filters)
  end

  @spec event_categories(map()) :: [atom()]
  def event_categories(selected_issue_data) do
    selected_issue_log(selected_issue_data)
    |> Enum.map(&event_category/1)
    |> Enum.uniq()
  end

  @spec select_event_detail(map(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def select_event_detail(selected_issue_data, index) when is_integer(index) and index >= 0 do
    case Enum.at(selected_event_log(selected_issue_data), index) do
      nil -> {:error, :event_not_found}
      entry -> {:ok, build_event_detail(selected_issue_data, entry, index)}
    end
  end

  def select_event_detail(_selected_issue_data, _index), do: {:error, :event_not_found}

  @spec event_source_path(map()) :: String.t() | nil
  def event_source_path(selected_issue_data) do
    run_dir = map_get(selected_issue_data, :run_dir)

    if is_binary(run_dir) and String.trim(run_dir) != "" do
      Path.join([run_dir, "artifacts", "agent-events.ndjson"])
    else
      nil
    end
  end

  defp selected_event_log(selected_issue_data) do
    map_get(selected_issue_data, :event_log) || []
  end

  defp selected_issue_log(selected_issue_data), do: selected_event_log(selected_issue_data)

  defp event_entry(entry, index, selected_issue_data) do
    category = event_category(entry)
    event = map_get(entry, :event)
    message = map_get(entry, :message)
    at = map_get(entry, :at)

    %{
      index: index,
      at: at,
      event: event,
      category: category,
      category_label: category_label(category),
      message: display_value(message),
      search_text:
        [
          event_label(event),
          category_label(category),
          at,
          display_value(message),
          map_get(selected_issue_data, :session_id),
          map_get(selected_issue_data, :run_id),
          map_get(selected_issue_data, :run_dir)
        ]
        |> Enum.reject(&blank?/1)
        |> Enum.map_join(" ", &to_string/1),
      is_tool?: tool_event?(event)
    }
  end

  defp apply_filters(entries, filters) do
    query = filters |> map_get(:query) |> normalize_query()
    category = filters |> map_get(:category) |> normalize_category()

    Enum.filter(entries, fn entry ->
      query_match?(entry, query) and category_match?(entry, category)
    end)
  end

  defp normalize_query(nil), do: nil

  defp normalize_query(query) when is_binary(query) do
    trimmed = String.trim(query)

    if trimmed == "" do
      nil
    else
      String.downcase(trimmed)
    end
  end

  defp normalize_query(query), do: query |> to_string() |> normalize_query()

  defp normalize_category(nil), do: :all
  defp normalize_category(category) when category in ["", :all, "all"], do: :all
  defp normalize_category(category) when is_atom(category), do: category

  defp normalize_category(category) when is_binary(category) do
    Enum.find(@event_categories, :all, &(Atom.to_string(&1) == category))
  end

  defp normalize_category(category), do: category |> to_string() |> normalize_category()

  defp query_match?(_entry, nil), do: true

  defp query_match?(entry, query) do
    String.contains?(String.downcase(entry.search_text || ""), query)
  end

  defp category_match?(_entry, :all), do: true
  defp category_match?(entry, category), do: entry.category == category

  defp build_event_detail(selected_issue_data, entry, index) do
    raw = load_raw_event(selected_issue_data, entry, index) || fallback_raw_event(selected_issue_data, entry)
    source_path = event_source_path(selected_issue_data)
    category = detail_category(entry)
    category_label = detail_category_label(entry, category)

    %{
      index: index,
      at: detail_timestamp(entry, raw),
      event: detail_event(entry, raw),
      display_event: map_get(entry, :event),
      category: category,
      category_label: category_label,
      summary: detail_summary(entry, raw, selected_issue_data, category),
      session_id: detail_session_id(raw, selected_issue_data),
      run_id: map_get(selected_issue_data, :run_id),
      turn_id: detail_turn_id(raw, selected_issue_data),
      turn_count: map_get(selected_issue_data, :turn_count),
      adapter: adapter(raw, selected_issue_data),
      provider: provider(raw, selected_issue_data),
      model: model(raw, selected_issue_data),
      source_path: source_path,
      artifact_links: artifact_links(raw, source_path, selected_issue_data),
      structured_fields: structured_fields(entry, raw, selected_issue_data, source_path, category_label, category),
      raw: raw,
      raw_json: pretty_json(raw),
      raw_available?: raw != nil,
      has_redacted_content?: raw_redacted?(raw)
    }
  end

  defp structured_fields(entry, raw, selected_issue_data, source_path, category_label, category) do
    [
      {"Timestamp", map_get(raw, :timestamp) || map_get(raw, "timestamp") || entry.at},
      {"Event", event_label(map_get(raw, :event) || map_get(raw, "event") || entry.event)},
      {"Category", category_label},
      {"Session", map_get(raw, :session_id) || map_get(raw, "session_id") || map_get(selected_issue_data, :session_id)},
      {"Run", map_get(selected_issue_data, :run_id)},
      {"Turn", turn_label(raw, selected_issue_data)},
      {"Adapter", adapter(raw, selected_issue_data)},
      {"Provider", provider(raw, selected_issue_data)},
      {"Model", model(raw, selected_issue_data)},
      {"Source path", source_path}
    ]
    |> Kernel.++(detail_specific_fields(category, entry, raw, selected_issue_data))
    |> Enum.reject(fn {_label, value} -> blank?(value) end)
    |> Enum.map(fn {label, value} -> {label, display_value(value)} end)
  end

  defp detail_specific_fields(:prompt, entry, raw, _selected_issue_data) do
    [
      {"Role", prompt_role(raw)},
      {"Prompt", prompt_content(entry, raw)},
      {"Redaction", redaction_note(raw)}
    ]
  end

  defp detail_specific_fields(:tool, entry, raw, _selected_issue_data) do
    [
      {"Tool", tool_name(entry, raw)},
      {"Status", detail_text(raw, [[:status], [:raw, :status]])},
      {"Command", detail_text(raw, [[:command], [:raw, :command], [:message, :command], [:params, :command]])},
      {"Input", detail_text(raw, [[:input], [:arguments], [:params], [:raw, :input], [:raw, :arguments], [:raw, :params]])},
      {"Output",
       detail_text(raw, [
         [:output],
         [:stdout],
         [:stderr],
         [:result],
         [:raw, :output],
         [:raw, :stdout],
         [:raw, :stderr],
         [:raw, :result]
       ])}
    ]
  end

  defp detail_specific_fields(:gate, _entry, raw, selected_issue_data) do
    [
      {"Gate status", gate_status(raw, selected_issue_data)},
      {"Failed gates", gate_failed_names(raw, selected_issue_data)},
      {"Results path", gate_results_path(raw, selected_issue_data)},
      {"State path", gate_state_path(raw, selected_issue_data)},
      {"Reused from", detail_text(raw, [[:reused_from], [:raw, :reused_from]])}
    ]
  end

  defp detail_specific_fields(:result, _entry, raw, selected_issue_data) do
    report = final_report_data(selected_issue_data)

    [
      {"Status", detail_text(raw, [[:status], [:raw, :status]])},
      {"Summary", first_nonblank([detail_text(raw, [[:summary], [:raw, :summary]]), map_get(report, "summary")])},
      {"Changed files", detail_list(map_get(report, "changed_files"))},
      {"Gates run", detail_list(map_get(report, "gates_run"))},
      {"Next state", map_get(report, "next_state")},
      {"Final report path", final_report_artifact_path(selected_issue_data)}
    ]
  end

  defp detail_specific_fields(:system, _entry, raw, _selected_issue_data) do
    [
      {"Subtype", detail_text(raw, [[:subtype], [:raw, :subtype]])},
      {"Status", detail_text(raw, [[:status], [:raw, :status]])}
    ]
  end

  defp detail_specific_fields(_category, _entry, _raw, _selected_issue_data), do: []

  defp detail_summary(entry, raw, selected_issue_data, category) do
    candidate =
      case category do
        :prompt -> first_nonblank([prompt_content(entry, raw), map_get(entry, :message)])
        :tool -> first_nonblank([tool_summary(entry, raw), map_get(entry, :message)])
        :gate -> first_nonblank([gate_summary(entry, raw, selected_issue_data), map_get(entry, :message)])
        :result -> first_nonblank([result_summary(entry, raw, selected_issue_data), map_get(entry, :message)])
        :system -> first_nonblank([system_summary(raw), map_get(entry, :message)])
        _ -> map_get(entry, :message)
      end

    display_value(candidate)
  end

  defp prompt_role(raw), do: detail_text(raw, [[:role], [:message, :role], [:raw, :role]])

  defp prompt_content(entry, raw) do
    first_nonblank([
      message_text(raw),
      detail_text(raw, [[:summary], [:message], [:raw, :summary], [:raw, :message]]),
      map_get(entry, :message)
    ])
  end

  defp tool_name(entry, raw) do
    first_nonblank([
      detail_text(raw, [
        [:tool],
        [:name],
        [:toolName],
        [:message, :tool],
        [:message, :name],
        [:raw, :tool],
        [:raw, :name]
      ]),
      map_get(entry, :message)
    ])
  end

  defp tool_summary(entry, raw) do
    first_nonblank([
      detail_text(raw, [[:command], [:summary], [:status], [:raw, :command], [:raw, :summary], [:raw, :status]]),
      map_get(entry, :message)
    ])
  end

  defp gate_summary(entry, raw, selected_issue_data) do
    first_nonblank([
      detail_text(raw, [[:summary], [:status], [:raw, :summary], [:raw, :status]]),
      gate_status(raw, selected_issue_data),
      map_get(entry, :message)
    ])
  end

  defp result_summary(entry, raw, selected_issue_data) do
    report = final_report_data(selected_issue_data)

    first_nonblank([
      map_get(report, "summary"),
      detail_text(raw, [[:summary], [:status], [:subtype], [:raw, :summary], [:raw, :status], [:raw, :subtype]]),
      map_get(entry, :message)
    ])
  end

  defp system_summary(raw) do
    detail_text(raw, [[:summary], [:status], [:subtype], [:raw, :summary], [:raw, :status], [:raw, :subtype]])
  end

  defp detail_text(term, paths) when is_list(paths) do
    paths
    |> Enum.find_value(fn path -> lookup(term, path) end)
    |> display_value()
  end

  defp detail_list(value) when is_list(value) do
    value
    |> Enum.map(&item_summary/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
    |> blank_to_nil()
  end

  defp detail_list(value), do: display_value(value)

  defp item_summary(%{} = item) do
    name =
      first_nonblank([
        lookup(item, [:name]),
        lookup(item, [:path]),
        lookup(item, [:file_path]),
        lookup(item, [:summary]),
        lookup(item, [:result]),
        lookup(item, [:status])
      ])

    status = lookup(item, [:status])

    cond do
      blank?(name) and blank?(status) ->
        inspect(item, pretty: true, limit: @detail_event_limit, printable_limit: @detail_event_limit)

      blank?(status) ->
        display_value(name)

      name == status ->
        display_value(name)

      true ->
        "#{display_value(name)}: #{display_value(status)}"
    end
  end

  defp item_summary(item), do: display_value(item)

  defp gate_status(raw, selected_issue_data) do
    first_nonblank([
      detail_text(raw, [[:status], [:raw, :status]]),
      detail_text(selected_issue_data, [[:latest_gate, :status]])
    ])
  end

  defp gate_failed_names(raw, selected_issue_data) do
    first_nonblank([
      detail_list(lookup(raw, [:failed]) || lookup(raw, [:raw, :failed])),
      detail_list(failed_gate_results(lookup(raw, [:results]) || lookup(raw, [:raw, :results]))),
      detail_list(lookup(selected_issue_data, [:latest_gate, :failed]))
    ])
  end

  defp failed_gate_results(results) when is_list(results) do
    Enum.reject(results, &result_pass?/1)
  end

  defp failed_gate_results(results), do: results

  defp result_pass?(%{} = result) do
    result
    |> lookup([:status])
    |> normalize_status()
    |> case do
      "pass" -> true
      "passed" -> true
      "ok" -> true
      "success" -> true
      _ -> false
    end
  end

  defp result_pass?(_result), do: false

  defp normalize_status(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_status(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_status()
  defp normalize_status(value), do: value |> to_string() |> normalize_status()

  defp gate_results_path(raw, selected_issue_data) do
    first_nonblank([
      detail_text(raw, [[:results_path], [:raw, :results_path]]),
      detail_text(selected_issue_data, [[:latest_gate, :results_path]])
    ])
  end

  defp gate_state_path(raw, selected_issue_data) do
    first_nonblank([
      detail_text(raw, [[:state_path], [:raw, :state_path]]),
      detail_text(selected_issue_data, [[:latest_gate, :state_path]])
    ])
  end

  defp final_report_artifact_path(selected_issue_data) do
    run_dir = map_get(selected_issue_data, :run_dir)

    if is_binary(run_dir) and String.trim(run_dir) != "" do
      path = Path.join([run_dir, "artifacts", "final-report.json"])
      if File.exists?(path), do: path, else: nil
    else
      nil
    end
  end

  defp final_report_data(selected_issue_data) do
    with path when is_binary(path) <- final_report_artifact_path(selected_issue_data),
         {:ok, json} <- File.read(path),
         {:ok, report} <- Jason.decode(json),
         true <- is_map(report) do
      report
    else
      _ -> nil
    end
  end

  defp collect_path_candidates(term), do: collect_path_candidates(term, [])

  defp collect_path_candidates(%{} = map, acc) do
    Enum.reduce(map, acc, fn {key, value}, acc ->
      acc = if path_key?(key) and is_binary(value) and String.trim(value) != "", do: [value | acc], else: acc
      collect_path_candidates(value, acc)
    end)
  end

  defp collect_path_candidates([head | tail], acc), do: collect_path_candidates(tail, collect_path_candidates(head, acc))
  defp collect_path_candidates([], acc), do: acc
  defp collect_path_candidates(_other, acc), do: acc

  defp path_key?(key), do: normalize_key(key) in @artifact_path_keys

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp lookup(term, []), do: term

  defp lookup(%{} = map, [key | rest]) do
    case map_get(map, key) do
      nil -> nil
      next -> lookup(next, rest)
    end
  end

  defp lookup([head | tail], path) do
    case lookup(head, path) do
      nil -> lookup(tail, path)
      value -> value
    end
  end

  defp lookup(_term, _path), do: nil

  defp first_nonblank(values) when is_list(values) do
    Enum.find_value(values, fn value -> if blank?(value), do: nil, else: value end)
  end

  defp display_value(nil), do: nil
  defp display_value(value) when is_binary(value), do: Rondo.Redaction.redact(value)
  defp display_value(value) when is_integer(value) or is_float(value) or is_boolean(value), do: value
  defp display_value(value) when is_atom(value), do: value |> Atom.to_string() |> display_value()

  defp display_value(value) when is_list(value) do
    value
    |> Enum.map(&display_value/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
    |> blank_to_nil()
  end

  defp display_value(value) when is_map(value) do
    value
    |> inspect(pretty: true, limit: @detail_event_limit, printable_limit: @detail_event_limit)
    |> Rondo.Redaction.redact()
  end

  defp display_value(value), do: inspect(value, pretty: true, limit: @detail_event_limit, printable_limit: @detail_event_limit) |> Rondo.Redaction.redact()

  defp redaction_note(raw) do
    if raw_redacted?(raw), do: "[REDACTED]", else: nil
  end

  defp artifact_links(raw, source_path, selected_issue_data) do
    [source_path, final_report_artifact_path(selected_issue_data)]
    |> Kernel.++(collect_path_candidates(raw))
    |> Enum.reject(&blank?/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.map(fn path -> %{label: Path.basename(path), path: path} end)
  end

  defp load_raw_event(selected_issue_data, entry, index) do
    with path when is_binary(path) <- event_source_path(selected_issue_data),
         true <- File.exists?(path),
         {:ok, content} <- File.read(path) do
      lines = String.split(content, ~r/\R/, trim: true)

      find_matching_raw_event(lines, entry, selected_issue_data) || raw_event_at_index(lines, index)
    else
      _ -> nil
    end
  end

  defp find_matching_raw_event(lines, entry, selected_issue_data) do
    Enum.find_value(lines, fn line ->
      with true <- raw_event_matches_entry?(line, entry, selected_issue_data),
           {:ok, raw} <- Jason.decode(line) do
        raw
      else
        _ -> nil
      end
    end)
  end

  defp raw_event_at_index(lines, index) do
    case Enum.at(lines, index) do
      line when is_binary(line) ->
        case Jason.decode(line) do
          {:ok, raw} -> raw
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp raw_event_matches_entry?(line, entry, selected_issue_data) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, raw} -> raw_event_matches_entry?(raw, entry, selected_issue_data)
      _ -> false
    end
  end

  defp raw_event_matches_entry?(raw, entry, selected_issue_data) do
    if is_map(raw) do
      same_timestamp?(map_get(raw, :timestamp) || map_get(raw, "timestamp"), map_get(entry, :at)) and
        same_session?(map_get(raw, :session_id) || map_get(raw, "session_id"), map_get(selected_issue_data, :session_id)) and
        same_adapter?(map_get(raw, :adapter) || map_get(raw, "adapter"), map_get(selected_issue_data, :adapter)) and
        raw_event_content_matches?(raw, entry)
    else
      false
    end
  end

  defp raw_event_content_matches?(raw, entry) do
    same_event?(map_get(raw, :event) || map_get(raw, "event"), map_get(entry, :event)) or same_message?(raw, entry)
  end

  defp detail_timestamp(entry, raw), do: map_get(raw, :timestamp) || map_get(raw, "timestamp") || map_get(entry, :at)
  defp detail_event(entry, raw), do: map_get(raw, :event) || map_get(raw, "event") || map_get(entry, :event)
  defp detail_session_id(raw, selected_issue_data), do: map_get(raw, :session_id) || map_get(raw, "session_id") || map_get(selected_issue_data, :session_id)
  defp detail_turn_id(raw, selected_issue_data), do: turn_id(raw) || map_get(selected_issue_data, :turn_id)
  defp detail_category(entry), do: Map.get(entry, :category) || event_category(entry)
  defp detail_category_label(entry, category), do: Map.get(entry, :category_label) || category_label(category)

  defp same_timestamp?(raw_timestamp, entry_timestamp) do
    if blank?(raw_timestamp) or blank?(entry_timestamp) do
      false
    else
      raw = to_string(raw_timestamp)
      entry = to_string(entry_timestamp)

      raw == entry or String.starts_with?(raw, entry) or String.starts_with?(entry, raw)
    end
  end

  defp same_session?(raw_session, entry_session) do
    blank?(entry_session) or blank?(raw_session) or to_string(raw_session) == to_string(entry_session)
  end

  defp same_adapter?(raw_adapter, entry_adapter) do
    blank?(entry_adapter) or blank?(raw_adapter) or to_string(raw_adapter) == to_string(entry_adapter)
  end

  defp same_event?(raw_event, entry_event) do
    raw_event_name = normalized_event_name(raw_event)
    entry_event_name = normalized_event_name(entry_event)

    raw_event_name != "" and entry_event_name != "" and
      (raw_event_name == entry_event_name or
         String.contains?(raw_event_name, entry_event_name) or
         String.contains?(entry_event_name, raw_event_name))
  end

  defp same_message?(raw, entry) do
    raw_summary = raw_summary_text(raw)
    entry_message = map_get(entry, :message) |> to_string()

    raw_summary != "" and entry_message != "" and
      (String.contains?(String.downcase(raw_summary), String.downcase(entry_message)) or
         String.contains?(String.downcase(entry_message), String.downcase(raw_summary)))
  end

  defp raw_summary_text(raw) when is_map(raw) do
    [
      map_get(raw, :summary) || map_get(raw, "summary"),
      message_text(map_get(raw, :message) || map_get(raw, "message")),
      message_text(map_get(raw, :raw) || map_get(raw, "raw"))
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.map_join(" ", &to_string/1)
  end

  defp message_text(message) when is_map(message) do
    nested =
      map_get(message, :message) ||
        map_get(message, "message") ||
        map_get(message, :raw) ||
        map_get(message, "raw")

    nested_text = nested && message_text(nested)

    if blank?(nested_text) do
      [
        get_in(message, ["content"]),
        get_in(message, [:content]),
        get_in(message, ["text"]),
        get_in(message, [:text])
      ]
      |> Enum.flat_map(fn
        list when is_list(list) ->
          Enum.flat_map(list, fn
            %{"text" => text} when is_binary(text) -> [text]
            _ -> []
          end)

        text when is_binary(text) ->
          [text]

        _ ->
          []
      end)
      |> Enum.join(" ")
    else
      nested_text
    end
  end

  defp message_text(message) when is_binary(message), do: message
  defp message_text(_message), do: ""

  defp normalized_event_name(nil), do: ""

  defp normalized_event_name(event) do
    event
    |> event_label()
    |> String.trim()
    |> String.downcase()
    |> String.replace(["-", " "], "_")
  end

  defp fallback_raw_event(selected_issue_data, entry) do
    %{
      "event" => event_label(map_get(entry, :event)),
      "timestamp" => map_get(entry, :at),
      "session_id" => map_get(selected_issue_data, :session_id),
      "run_id" => map_get(selected_issue_data, :run_id),
      "summary" => map_get(entry, :message)
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp pretty_json(raw) when is_map(raw) do
    raw
    |> Jason.encode!(pretty: true)
    |> Rondo.Redaction.redact()
  rescue
    _ ->
      raw
      |> inspect(pretty: true, limit: @detail_event_limit, printable_limit: @detail_event_limit)
      |> Rondo.Redaction.redact()
  end

  defp pretty_json(raw),
    do:
      raw
      |> inspect(pretty: true, limit: @detail_event_limit, printable_limit: @detail_event_limit)
      |> Rondo.Redaction.redact()

  defp event_category(entry) do
    event = map_get(entry, :event)
    message = map_get(entry, :message)
    event_name = normalized_event_name(event)
    label = String.downcase(event_label(event))

    cond do
      prompt_event?(event_name, label) -> :prompt
      tool_event?(event_name, label) -> :tool
      result_event?(event_name, label) -> :result
      gate_event?(event_name, label, message) -> :gate
      system_event?(event_name) -> :system
      true -> :other
    end
  end

  defp prompt_event?(event_name, label) do
    event_name in @prompt_event_names or
      String.contains?(label, "prompt") or
      String.contains?(label, "request") or
      String.contains?(label, "message")
  end

  defp result_event?(event_name, label) do
    event_name in @result_event_names or
      String.contains?(label, "result") or
      String.contains?(label, "final report") or
      String.contains?(label, "turn completed")
  end

  defp gate_event?(event_name, label, message) do
    event_name in @gate_event_names or
      String.contains?(label, "gate") or
      String.contains?(String.downcase(to_string(message || "")), "gate")
  end

  defp system_event?(event_name), do: event_name in @system_event_names

  defp tool_event?(event_name, label), do: event_name in @tool_event_names or String.contains?(label, "tool")

  defp turn_label(raw, selected_issue_data) do
    turn_id = turn_id(raw)

    cond do
      not blank?(turn_id) -> turn_id
      blank?(map_get(selected_issue_data, :turn_count)) -> nil
      true -> map_get(selected_issue_data, :turn_count)
    end
  end

  defp turn_id(raw) when is_map(raw) do
    map_get(raw, :turn_id) ||
      map_get(raw, "turn_id") ||
      get_in(raw, ["turn", "id"]) ||
      get_in(raw, [:turn, :id]) ||
      get_in(raw, ["message", "turn", "id"]) ||
      get_in(raw, [:message, :turn, :id]) ||
      get_in(raw, ["params", "turn", "id"]) ||
      get_in(raw, [:params, :turn, :id])
  end

  defp turn_id(_raw), do: nil

  defp adapter(raw, selected_issue_data) do
    map_get(raw, :adapter) || map_get(raw, "adapter") || map_get(selected_issue_data, :adapter)
  end

  defp provider(raw, selected_issue_data) do
    map_get(raw, :provider) || map_get(raw, "provider") || adapter(raw, selected_issue_data)
  end

  defp model(raw, selected_issue_data) do
    map_get(raw, :model) ||
      map_get(raw, "model") ||
      get_in(selected_issue_data, [:model_routing, :resolved, :model]) ||
      get_in(selected_issue_data, [:model_fallback, :next_candidate, :model])
  end

  defp raw_redacted?(raw) do
    text = redaction_text(raw)
    Rondo.Redaction.contains_secret?(text) || String.contains?(text, "[REDACTED]")
  rescue
    _ -> false
  end

  defp redaction_text(%{} = raw), do: Jason.encode!(raw)
  defp redaction_text(raw) when is_binary(raw), do: raw
  defp redaction_text(raw), do: inspect(raw, pretty: true, limit: @detail_event_limit, printable_limit: @detail_event_limit)

  defp event_label(event) when is_atom(event), do: event |> Atom.to_string() |> String.replace("_", " ")
  defp event_label(event), do: to_string(event)

  defp category_label(category), do: category |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp tool_event?(event), do: normalized_event_name(event) in @tool_event_names

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, stringify_key(key))
  end

  defp map_get(_map, _key), do: nil

  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: key

  defp blank_to_nil(value) do
    if blank?(value), do: nil, else: value
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(value) when is_list(value), do: value == []
  defp blank?(_value), do: false
end
