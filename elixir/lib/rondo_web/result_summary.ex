defmodule RondoWeb.ResultSummary do
  @moduledoc """
  Best-effort structured summaries for dashboard result payloads.
  """

  alias Rondo.FinalReport

  @type kind :: :final_report | :json | :text

  @type field :: %{label: String.t(), value: String.t()}

  @type t :: %{
          kind: kind(),
          preview: String.t(),
          title: String.t(),
          fields: [field()],
          raw: String.t(),
          pretty: String.t() | nil,
          copy_text: String.t()
        }

  @spec describe(term()) :: t()
  def describe(value) do
    value
    |> then(&{&1, unwrap_result(&1)})
    |> then(fn {raw_value, summary_value} -> describe_unwrapped(summary_value, raw_value) end)
  end

  @spec preview(term()) :: String.t()
  def preview(value), do: describe(value).preview

  @doc false
  @spec preview_report(map()) :: String.t()
  def preview_report(report) when is_map(report), do: final_report_preview(report)

  defp describe_unwrapped(value, raw_source) when is_map(value) or is_list(value) do
    normalized = normalize_json_value(value)
    raw_json = json_compact(normalize_json_value(raw_source))
    summary_value = unwrap_final_report_wrapper(normalized)

    case final_report_map(summary_value) do
      {:ok, report} -> final_report_summary(report, raw_json)
      :error -> generic_json_summary(summary_value, raw_json)
    end
  end

  defp describe_unwrapped(value, _raw_source) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      text_summary(trimmed)
    else
      case decoded_json_candidates(trimmed) do
        [] ->
          text_summary(trimmed)

        candidates ->
          json_candidate_summary(candidates)
      end
    end
  end

  defp describe_unwrapped(value, _raw_source), do: text_summary(inspect(value))

  defp unwrap_result(%{schema: _} = value), do: value
  defp unwrap_result(%{"schema" => _} = value), do: value

  defp unwrap_result(%{reason: "final_report_invalid"} = value), do: unwrap_final_report_wrapper(normalize_json_value(value))
  defp unwrap_result(%{"reason" => "final_report_invalid"} = value), do: unwrap_final_report_wrapper(normalize_json_value(value))

  defp unwrap_result(%{result: result}) when is_binary(result) or is_map(result) or is_list(result), do: result
  defp unwrap_result(%{"result" => result}) when is_binary(result) or is_map(result) or is_list(result), do: result

  defp unwrap_result(%{message: message}) when is_binary(message) or is_map(message) or is_list(message), do: message
  defp unwrap_result(%{"message" => message}) when is_binary(message) or is_map(message) or is_list(message), do: message

  defp unwrap_result(%{payload: payload}) when is_binary(payload) or is_map(payload) or is_list(payload), do: payload
  defp unwrap_result(%{"payload" => payload}) when is_binary(payload) or is_map(payload) or is_list(payload), do: payload

  defp unwrap_result(value), do: value

  defp final_report_summary(report, raw_json) do
    preview = final_report_preview(report)

    %{
      kind: :final_report,
      title: "Final report",
      preview: preview,
      fields: final_report_fields(report),
      raw: raw_json,
      pretty: json_pretty(report),
      copy_text: raw_json
    }
  end

  defp generic_json_summary(value, raw_json) do
    %{
      kind: :json,
      title: json_title(value),
      preview: json_preview(value),
      fields: generic_json_fields(value),
      raw: raw_json,
      pretty: json_pretty(value),
      copy_text: raw_json
    }
  end

  defp text_summary(text) do
    preview = normalize_whitespace(text)

    %{
      kind: :text,
      title: "Plain text",
      preview: if(preview == "", do: "n/a", else: truncate_text(preview, 140)),
      fields: [],
      raw: text,
      pretty: nil,
      copy_text: text
    }
  end

  defp final_report_map(report) when is_map(report) do
    normalized = normalize_json_value(report)

    case FinalReport.validate(normalized) do
      {:ok, validated} -> {:ok, normalize_json_value(validated)}
      {:error, _} -> :error
    end
  end

  defp final_report_map(_report), do: :error

  defp unwrap_final_report_wrapper(%{"reason" => "final_report_invalid", "final_report" => final_report}) do
    final_report
  end

  defp unwrap_final_report_wrapper(report), do: report

  defp summary_candidate_value(value) do
    value
    |> normalize_json_value()
    |> unwrap_final_report_wrapper()
  end

  defp decoded_json_candidates(text) when is_binary(text) do
    text
    |> candidate_json_documents()
    |> Enum.flat_map(fn candidate ->
      case Jason.decode(candidate) do
        {:ok, decoded} when is_map(decoded) or is_list(decoded) -> [%{decoded: decoded, raw_json: candidate}]
        _ -> []
      end
    end)
  end

  defp candidate_json_documents(text) do
    fenced =
      Regex.scan(~r/```json\s*\n(.*?)```/s, text, capture: :all_but_first)
      |> Enum.map(fn [block] -> String.trim(block) end)
      |> Enum.reverse()

    [String.trim(text) | fenced]
  end

  defp json_candidate_summary(candidates) do
    case Enum.find(candidates, fn %{decoded: decoded} -> final_report_map(summary_candidate_value(decoded)) != :error end) do
      %{decoded: report, raw_json: raw_json} ->
        {:ok, normalized_report} = final_report_map(summary_candidate_value(report))
        final_report_summary(normalized_report, raw_json)

      nil ->
        %{decoded: decoded, raw_json: raw_json} = List.first(candidates)
        generic_json_summary(summary_candidate_value(decoded), raw_json)
    end
  end

  defp json_title(value) when is_list(value), do: "JSON array"

  defp json_title(value) when is_map(value) do
    cond do
      Map.has_key?(value, "schema") -> "JSON object"
      Map.has_key?(value, :schema) -> "JSON object"
      true -> "JSON object"
    end
  end

  defp json_preview(value) when is_list(value), do: "JSON array (#{length(value)} items)"

  defp json_preview(value) when is_map(value) do
    summary =
      value
      |> ordered_json_preview_keys()
      |> Enum.find_value(fn key ->
        case fetch_json_value(value, key) do
          nil -> nil
          val -> format_scalar(val)
        end
      end)

    if summary && summary != "" do
      "JSON object · #{summary}"
    else
      "JSON object"
    end
  end

  defp generic_json_fields(value) when is_list(value) do
    [
      %{label: "Items", value: Integer.to_string(length(value))}
    ]
  end

  defp generic_json_fields(value) when is_map(value) do
    value
    |> ordered_generic_keys()
    |> Enum.filter(&Map.has_key?(value, &1))
    |> Enum.take(5)
    |> Enum.flat_map(fn key ->
      case fetch_json_value(value, key) do
        nil -> []
        val -> [%{label: humanize_key(key), value: format_json_value(val)}]
      end
    end)
  end

  defp final_report_preview(report) do
    status = first_present(report, ~w(status next_state reported_next_state))
    summary = first_present(report, ~w(summary title))

    cond do
      status && summary -> "#{status} · #{summary}"
      summary -> summary
      status -> status
    end
  end

  defp final_report_fields(report) do
    [
      %{label: "Status", value: first_present(report, ~w(status next_state reported_next_state))},
      %{label: "Blocker", value: blocker_summary(report)},
      %{label: "Files changed", value: files_changed_summary(report)},
      %{label: "Tests / gates", value: gates_summary(report)},
      %{label: "PR / issue links", value: link_summary(report)},
      %{label: "Next action", value: first_present(report, ~w(next_action next_step next_state reported_next_state))}
    ]
    |> Enum.reject(fn %{value: value} -> blank?(value) end)
  end

  defp blocker_summary(report) do
    first_present(report, ~w(blocker blockers blocking failure failures risks))
    |> case do
      nil -> nil
      value -> format_json_value(value)
    end
  end

  defp files_changed_summary(report) do
    report
    |> first_present_value(~w(changed_files files_changed files))
    |> case do
      nil -> nil
      value -> summarize_collection(value)
    end
  end

  defp gates_summary(report) do
    report
    |> first_present_value(~w(gates_run tests gates))
    |> case do
      nil -> nil
      value -> summarize_gate_collection(value)
    end
  end

  defp link_summary(report) do
    report
    |> first_present_value(~w(links pr_links issue_links pull_requests issues prs pr))
    |> case do
      nil -> nil
      value -> summarize_link_collection(value)
    end
  end

  defp preferred_json_preview_keys do
    ~w(reason classification status next_state reported_next_state summary title blocker blockers failure failures risks errors excerpt continuation_count fingerprint question changed_files files_changed gates_run tests next_action next_step links pr_links issue_links)
  end

  defp ordered_json_preview_keys(value) when is_map(value) do
    preferred = preferred_json_preview_keys()
    remaining = Map.keys(value) |> Enum.reject(&(&1 in preferred)) |> Enum.sort()
    preferred ++ remaining
  end

  defp preferred_generic_keys do
    ~w(schema status reported_next_state errors excerpt continuation_count fingerprint reason classification question next_state summary title blocker blockers failure failures risks changed_files files_changed gates_run tests next_action next_step links pr_links issue_links)
  end

  defp ordered_generic_keys(value) when is_map(value) do
    preferred = preferred_generic_keys()
    remaining = Map.keys(value) |> Enum.reject(&(&1 in preferred)) |> Enum.sort()
    preferred ++ remaining
  end

  defp fetch_json_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key)
  end

  defp present_json_value(nil, _formatter), do: nil
  defp present_json_value(value, _formatter) when is_list(value) and value == [], do: nil

  defp present_json_value(value, formatter) when is_binary(value) do
    if String.trim(value) == "" do
      nil
    else
      formatter.(value)
    end
  end

  defp present_json_value(value, formatter), do: formatter.(value)

  defp first_present(report, keys) when is_map(report) do
    Enum.find_value(keys, fn key ->
      fetch_json_value(report, key)
      |> present_json_value(&format_json_value/1)
    end)
  end

  defp first_present_value(report, keys) when is_map(report) do
    Enum.find_value(keys, fn key ->
      fetch_json_value(report, key)
      |> present_json_value(& &1)
    end)
  end

  defp summarize_collection(value) when is_list(value) do
    joined =
      value
      |> Enum.take(3)
      |> Enum.map(&format_json_value/1)
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    if joined == "" do
      nil
    else
      joined
    end
  end

  defp summarize_gate_collection(value) when is_list(value) do
    value
    |> Enum.take(3)
    |> Enum.map(&summarize_gate_item/1)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      items -> Enum.join(items, ", ")
    end
  end

  defp summarize_gate_item(value) when is_map(value) do
    name = first_non_blank([fetch_json_value(value, "name"), fetch_json_value(value, "title")])
    status = first_non_blank([fetch_json_value(value, "status"), fetch_json_value(value, "result")])

    cond do
      name && status -> "#{format_scalar(name)}: #{format_scalar(status)}"
      name -> format_scalar(name)
      status -> format_scalar(status)
      true -> format_json_value(value)
    end
  end

  defp summarize_gate_item(value), do: format_json_value(value)

  defp summarize_link_collection(value) when is_list(value) do
    value
    |> Enum.take(3)
    |> Enum.map(&summarize_link_item/1)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      items -> Enum.join(items, ", ")
    end
  end

  defp summarize_link_collection(value), do: summarize_link_item(value)

  defp summarize_link_item(value) when is_map(value) do
    title =
      first_non_blank([
        fetch_json_value(value, "title"),
        fetch_json_value(value, "name"),
        fetch_json_value(value, "identifier"),
        fetch_json_value(value, "number")
      ])

    url = first_non_blank([fetch_json_value(value, "url"), fetch_json_value(value, "href")])

    cond do
      title && url -> "#{format_scalar(title)} (#{format_scalar(url)})"
      title -> format_scalar(title)
      url -> format_scalar(url)
      true -> format_json_value(value)
    end
  end

  defp summarize_link_item(value), do: format_json_value(value)

  defp format_json_value(value) when is_map(value) do
    normalized = normalize_json_value(value)

    if normalized == %{} do
      "{}"
    else
      json_compact(normalized)
    end
  end

  defp format_json_value(value) when is_list(value), do: summarize_collection(value) || json_compact(normalize_json_value(value))
  defp format_json_value(value) when is_binary(value), do: truncate_text(normalize_whitespace(value), 140)
  defp format_json_value(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp format_json_value(value), do: inspect(value)

  defp format_scalar(value) when is_binary(value), do: truncate_text(normalize_whitespace(value), 140)
  defp format_scalar(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp format_scalar(value), do: format_json_value(value)

  defp json_compact(value) do
    Jason.encode!(value)
  rescue
    _ -> inspect(value)
  end

  defp json_pretty(value) do
    Jason.encode!(value, pretty: true)
  rescue
    _ -> inspect(value)
  end

  defp normalize_json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_json_value(nested)} end)
  end

  defp normalize_json_value(value) when is_list(value), do: Enum.map(value, &normalize_json_value/1)
  defp normalize_json_value(nil), do: nil
  defp normalize_json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_json_value(value), do: value

  defp first_non_blank(values) do
    Enum.find_value(values, fn
      nil ->
        nil

      value when is_list(value) and value == [] ->
        nil

      value when is_binary(value) ->
        if String.trim(value) == "" do
          nil
        else
          value
        end

      value ->
        value
    end)
  end

  defp blank?(value) when is_nil(value), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""

  defp normalize_whitespace(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate_text(text, max_length) when is_binary(text) and is_integer(max_length) and max_length > 0 do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length - 1) <> "…"
    else
      text
    end
  end

  defp humanize_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
