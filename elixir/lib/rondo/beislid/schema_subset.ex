defmodule Rondo.Beislid.SchemaSubset do
  @moduledoc false

  @supported_keywords ~w(type required properties enum items minimum pattern)
  @metadata_keywords ~w($schema $id $comment title description)

  @type violation :: %{path: String.t(), rule: atom()}

  @spec load!(Path.t()) :: map()
  def load!(relative_path) when is_binary(relative_path) do
    :rondo
    |> :code.priv_dir()
    |> to_string()
    |> Path.join(relative_path)
    |> File.read!()
    |> Jason.decode!()
  end

  @spec validate(term(), map(), String.t()) :: [violation()]
  def validate(instance, schema, root_label)
      when is_map(schema) and is_binary(root_label) do
    check(instance, schema, root_label)
  end

  @spec supported?(map()) :: boolean()
  def supported?(schema) when is_map(schema), do: unsupported_keywords(schema) == []

  @spec unsupported_keywords(map()) :: [String.t()]
  def unsupported_keywords(schema) when is_map(schema) do
    schema
    |> collect_unsupported("")
    |> Enum.sort()
  end

  defp check(value, schema, path) when is_map(schema) do
    type_violations = check_type(value, Map.get(schema, "type"), path)

    if type_violations == [] do
      check_enum(value, schema, path) ++
        check_pattern(value, schema, path) ++
        check_minimum(value, schema, path) ++
        check_object(value, schema, path) ++
        check_items(value, schema, path)
    else
      type_violations
    end
  end

  defp check(_value, _schema, _path), do: []

  defp check_type(_value, nil, _path), do: []

  defp check_type(value, type, path) do
    if type_matches?(value, type), do: [], else: [violation(path, :type)]
  end

  defp type_matches?(value, "object"), do: is_map(value)
  defp type_matches?(value, "array"), do: is_list(value)
  defp type_matches?(value, "string"), do: is_binary(value)
  defp type_matches?(value, "integer"), do: is_integer(value)
  defp type_matches?(value, "number"), do: is_number(value)
  defp type_matches?(value, "boolean"), do: is_boolean(value)
  defp type_matches?(value, "null"), do: is_nil(value)
  defp type_matches?(_value, _unknown), do: true

  defp check_enum(value, %{"enum" => allowed}, path) when is_list(allowed) do
    if value in allowed, do: [], else: [violation(path, :enum)]
  end

  defp check_enum(_value, _schema, _path), do: []

  defp check_pattern(value, %{"pattern" => pattern}, path)
       when is_binary(value) and is_binary(pattern) do
    case Regex.compile(pattern, "u") do
      {:ok, regex} ->
        if Regex.match?(regex, value), do: [], else: [violation(path, :pattern)]

      {:error, _reason} ->
        [violation(path, :invalid_schema)]
    end
  end

  defp check_pattern(_value, _schema, _path), do: []

  defp check_minimum(value, %{"minimum" => minimum}, path)
       when is_number(value) and is_number(minimum) do
    if value >= minimum, do: [], else: [violation(path, :minimum)]
  end

  defp check_minimum(_value, _schema, _path), do: []

  defp check_object(value, schema, path) when is_map(value) do
    required_violations =
      schema
      |> Map.get("required", [])
      |> Enum.flat_map(fn key ->
        if Map.has_key?(value, key), do: [], else: [violation(child(path, key), :required)]
      end)

    property_violations =
      schema
      |> Map.get("properties", %{})
      |> Enum.flat_map(fn {key, child_schema} ->
        if Map.has_key?(value, key) do
          check(Map.fetch!(value, key), child_schema, child(path, key))
        else
          []
        end
      end)

    required_violations ++ property_violations
  end

  defp check_object(_value, _schema, _path), do: []

  defp check_items(value, %{"items" => item_schema}, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> check(item, item_schema, "#{path}[#{index}]") end)
  end

  defp check_items(_value, _schema, _path), do: []

  defp violation(path, rule), do: %{path: path, rule: rule}

  defp child("", key), do: key
  defp child(path, key), do: "#{path}.#{key}"

  defp collect_unsupported(schema, path) do
    local =
      schema
      |> Map.keys()
      |> Enum.reject(&(&1 in @supported_keywords or &1 in @metadata_keywords))
      |> Enum.map(&child(path, &1))

    properties =
      schema
      |> Map.get("properties", %{})
      |> Enum.flat_map(fn {key, child_schema} ->
        if is_map(child_schema), do: collect_unsupported(child_schema, child(path, key)), else: []
      end)

    items =
      case Map.get(schema, "items") do
        child_schema when is_map(child_schema) ->
          collect_unsupported(child_schema, if(path == "", do: "[]", else: path <> "[]"))

        _other ->
          []
      end

    local ++ properties ++ items
  end
end
