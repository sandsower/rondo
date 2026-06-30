defmodule RondoWeb.ArchivedRuns do
  @moduledoc """
  Filtering, sorting, and pagination helpers for the archived-runs dashboard table.
  """

  @default_page_size 25
  @max_page_size 100
  @sortable_fields ~w(issue project status started ended duration model tokens cost result)
  @param_keys %{
    "search" => :search,
    "status" => :status,
    "model" => :model,
    "project" => :project,
    "date_from" => :date_from,
    "date_to" => :date_to,
    "sort_by" => :sort_by,
    "sort_dir" => :sort_dir,
    "page" => :page,
    "page_size" => :page_size
  }

  @type filters :: %{
          search: String.t(),
          status: String.t(),
          model: String.t(),
          project: String.t(),
          date_from: String.t(),
          date_to: String.t(),
          sort_by: String.t(),
          sort_dir: String.t(),
          page: pos_integer(),
          page_size: pos_integer()
        }

  @spec default_filters() :: filters()
  def default_filters do
    %{
      search: "",
      status: "all",
      model: "all",
      project: "all",
      date_from: "",
      date_to: "",
      sort_by: "ended",
      sort_dir: "desc",
      page: 1,
      page_size: @default_page_size
    }
  end

  @spec merge_filters(map(), map()) :: filters()
  def merge_filters(current, params) when is_map(current) and is_map(params) do
    current
    |> Map.merge(normalize_params(params))
    |> normalize_filters()
  end

  @spec normalize_filters(map()) :: filters()
  def normalize_filters(filters) when is_map(filters) do
    defaults = default_filters()

    %{
      search: clean_string(value(filters, :search, defaults.search)),
      status: clean_filter(value(filters, :status, defaults.status)),
      model: clean_filter(value(filters, :model, defaults.model)),
      project: clean_filter(value(filters, :project, defaults.project)),
      date_from: clean_string(value(filters, :date_from, defaults.date_from)),
      date_to: clean_string(value(filters, :date_to, defaults.date_to)),
      sort_by: sort_field(value(filters, :sort_by, defaults.sort_by)),
      sort_dir: sort_dir(value(filters, :sort_dir, defaults.sort_dir)),
      page: positive_int(value(filters, :page, defaults.page), defaults.page),
      page_size: page_size(value(filters, :page_size, defaults.page_size))
    }
  end

  @spec view([map()], map()) :: map()
  def view(rows, filters) when is_list(rows) and is_map(filters) do
    filters = normalize_filters(filters)

    filtered =
      rows
      |> Enum.filter(&matches_filters?(&1, filters))
      |> maybe_sort_rows(filters)

    total = length(filtered)
    page_count = max(ceil_div(total, filters.page_size), 1)
    page = min(filters.page, page_count)
    offset = (page - 1) * filters.page_size
    page_rows = Enum.slice(filtered, offset, filters.page_size)

    %{
      rows: page_rows,
      total: total,
      page: page,
      page_count: page_count,
      page_size: filters.page_size,
      filters: %{filters | page: page},
      options: options(rows),
      recent_failures: recent_failures(rows)
    }
  end

  @spec next_sort(map(), String.t()) :: map()
  def next_sort(filters, field) when field in @sortable_fields do
    filters = normalize_filters(filters)
    dir = if filters.sort_by == field and filters.sort_dir == "asc", do: "desc", else: "asc"
    %{filters | sort_by: field, sort_dir: dir, page: 1}
  end

  def next_sort(filters, _field), do: normalize_filters(filters)

  defp normalize_params(params) do
    params
    |> Enum.map(fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
    |> Map.new()
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    normalized = String.replace(key, "-", "_")
    Map.get(@param_keys, normalized, key)
  end

  defp normalize_key(key), do: key

  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(value), do: value

  defp value(map, key, default), do: Map.get(map, key) || Map.get(map, Atom.to_string(key), default)

  defp clean_string(value) when is_binary(value), do: String.trim(value)
  defp clean_string(_value), do: ""

  defp clean_filter(value) when is_binary(value) and value != "", do: String.trim(value)
  defp clean_filter(_value), do: "all"

  defp sort_field(field) when field in @sortable_fields, do: field
  defp sort_field(_field), do: "ended"

  defp sort_dir("asc"), do: "asc"
  defp sort_dir("desc"), do: "desc"
  defp sort_dir(_dir), do: "desc"

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_int(_value, default), do: default

  defp page_size(value) do
    value
    |> positive_int(@default_page_size)
    |> min(@max_page_size)
    |> max(1)
  end

  defp matches_filters?(row, filters) do
    search_match?(row, filters.search) and status_match?(row, filters.status) and
      exact_or_all?(row_model(row), filters.model) and exact_or_all?(row_project(row), filters.project) and
      date_match?(row, filters.date_from, filters.date_to)
  end

  defp search_match?(_row, ""), do: true

  defp search_match?(row, search) do
    needle = String.downcase(search)

    row
    |> search_fields()
    |> Enum.any?(fn value -> value |> to_string() |> String.downcase() |> String.contains?(needle) end)
  end

  defp search_fields(row) do
    [
      row[:issue_identifier],
      row[:issue_title],
      row[:project],
      row[:repo],
      row[:status],
      row[:outcome],
      row[:model],
      row[:provider],
      row[:last_meaningful_result]
    ]
  end

  defp status_match?(_row, "all"), do: true
  defp status_match?(row, "failed"), do: row[:status] in ["failed", "exited", "error"]
  defp status_match?(row, status), do: row[:status] == status or row[:outcome] == status

  defp exact_or_all?(_value, "all"), do: true
  defp exact_or_all?(value, wanted), do: to_string(value || "unknown") == wanted

  defp date_match?(row, date_from, date_to) do
    case row_date(row) do
      nil -> date_from == "" and date_to == ""
      date -> after_or_on?(date, parse_date(date_from)) and before_or_on?(date, parse_date(date_to))
    end
  end

  defp after_or_on?(_date, nil), do: true
  defp after_or_on?(date, min_date), do: Date.compare(date, min_date) in [:gt, :eq]

  defp before_or_on?(_date, nil), do: true
  defp before_or_on?(date, max_date), do: Date.compare(date, max_date) in [:lt, :eq]

  defp row_date(row) do
    (row[:finished_at] || row[:started_at])
    |> parse_date_time()
    |> case do
      %DateTime{} = dt -> DateTime.to_date(dt)
      _ -> nil
    end
  end

  defp parse_date(""), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp maybe_sort_rows(rows, %{sort_by: "ended", sort_dir: "desc"}), do: rows
  defp maybe_sort_rows(rows, filters), do: sort_rows(rows, filters)

  defp sort_rows(rows, %{sort_by: sort_by, sort_dir: sort_dir}) do
    direction = if sort_dir == "asc", do: :asc, else: :desc
    Enum.sort_by(rows, &sort_value(&1, sort_by), {direction, __MODULE__.Sorter})
  end

  defp sort_value(row, "issue"), do: row[:issue_identifier] || ""
  defp sort_value(row, "project"), do: row_project(row)
  defp sort_value(row, "status"), do: {attention_rank(row), row[:status] || ""}
  defp sort_value(row, "started"), do: parse_date_time(row[:started_at]) || ~U[1970-01-01 00:00:00Z]
  defp sort_value(row, "ended"), do: parse_date_time(row[:finished_at]) || parse_date_time(row[:started_at]) || ~U[1970-01-01 00:00:00Z]
  defp sort_value(row, "duration"), do: row[:duration_ms] || 0
  defp sort_value(row, "model"), do: row_model(row)
  defp sort_value(row, "tokens"), do: get_in(row, [:tokens, :total_tokens]) || 0
  defp sort_value(row, "cost"), do: row[:cost] || 0
  defp sort_value(row, "result"), do: row[:last_meaningful_result] || row[:outcome] || ""

  defp parse_date_time(%DateTime{} = dt), do: dt

  defp parse_date_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_date_time(_value), do: nil

  defp row_model(row), do: row[:model] || row[:adapter] || "unknown"
  defp row_project(row), do: row[:project] || row[:repo] || "unknown"

  defp attention_rank(row) do
    case row[:status] do
      "failed" -> 0
      "exited" -> 1
      "terminated" -> 2
      "handed_off" -> 3
      _ -> 4
    end
  end

  defp options(rows) do
    %{
      statuses: option_values(rows, & &1[:status]),
      models: option_values(rows, &row_model/1),
      projects: option_values(rows, &row_project/1)
    }
  end

  defp ceil_div(0, _denominator), do: 0
  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)

  defp option_values(rows, fun) do
    rows
    |> Enum.map(fun)
    |> Enum.map(&to_string(&1 || "unknown"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp recent_failures(rows) do
    rows
    |> Enum.filter(&(&1[:status] in ["failed", "exited", "error"]))
    |> Enum.take(5)
  end

  defmodule Sorter do
    @moduledoc false

    @spec compare(term(), term()) :: :lt | :gt | :eq
    def compare(left, right) do
      cond do
        left == right -> :eq
        is_nil(left) -> :lt
        is_nil(right) -> :gt
        true -> if left <= right, do: :lt, else: :gt
      end
    end
  end
end
