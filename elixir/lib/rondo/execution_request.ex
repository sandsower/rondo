defmodule Rondo.ExecutionRequest do
  @moduledoc """
  Loader for local approved-slice / execution-request manifests.
  """

  alias Rondo.Linear.Issue

  @schemas ["approved-slice-v1", "rondo-execution-request-v1"]
  @metadata_keys ~w(parent_contract repo allowed_actions process_provider memory_provider output_expectations runner_extensions model_routing model_routing_hints)

  @type t :: %{
          issue: Issue.t(),
          source_contract: map()
        }

  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    expanded_path = Path.expand(path)

    with {:ok, json} <- read_manifest(expanded_path),
         {:ok, payload} <- Jason.decode(json),
         {:ok, request} <- normalize(payload, expanded_path, json) do
      {:ok, request}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_execution_request_json, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def load(path), do: {:error, {:invalid_execution_request_path, path}}

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:execution_request_read_failed, path, reason}}
    end
  end

  defp normalize(payload, path, json) when is_map(payload) do
    with {:ok, schema} <- required_string(payload, "schema"),
         :ok <- validate_schema(schema),
         {:ok, slice_id} <- required_string(payload, "slice_id"),
         {:ok, prompt} <- prompt(payload),
         {:ok, description} <- description(prompt, payload) do
      source_contract =
        payload
        |> Map.take(@metadata_keys)
        |> Map.merge(%{
          "schema" => schema,
          "slice_id" => slice_id,
          "path" => path,
          "sha256" => sha256(json)
        })
        |> atomize_contract_keys()

      {:ok,
       %{
         issue: issue(slice_id, description),
         source_contract: source_contract
       }}
    end
  end

  defp normalize(_payload, _path, _json), do: {:error, :invalid_execution_request_manifest}

  defp validate_schema(schema) do
    if schema in @schemas do
      :ok
    else
      {:error, {:unsupported_execution_request_schema, schema}}
    end
  end

  defp prompt(payload) do
    case string_value(payload, "prompt") || string_value(payload, "body") do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:missing_execution_request_field, "prompt"}}
    end
  end

  defp required_string(payload, key) do
    case string_value(payload, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:missing_execution_request_field, key}}
    end
  end

  defp string_value(payload, key) do
    case Map.get(payload, key) || Map.get(payload, String.to_atom(key)) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp issue(slice_id, description) do
    %Issue{
      id: slice_id,
      identifier: slice_id,
      title: "Execution request #{slice_id}",
      description: description,
      state: "In Progress",
      labels: ["execution-request"],
      assigned_to_worker: true
    }
  end

  defp description(prompt, payload) do
    with {:ok, boundaries} <- list_section(payload, "boundaries"),
         {:ok, dependencies} <- list_section(payload, "dependencies"),
         {:ok, proof_requirements} <- list_section(payload, "proof_requirements") do
      description =
        [
          {"Prompt", prompt},
          {"Boundaries", boundaries},
          {"Dependencies", dependencies},
          {"Proof requirements", proof_requirements},
          {"Output expectations", json_section(payload, "output_expectations")}
        ]
        |> Enum.reject(fn {_title, value} -> is_nil(value) or value == "" end)
        |> Enum.map_join("\n\n", fn {title, value} -> "## #{title}\n\n#{value}" end)

      {:ok, description}
    end
  end

  defp list_section(payload, key) do
    case Map.get(payload, key) || Map.get(payload, String.to_atom(key)) do
      values when is_list(values) ->
        if Enum.all?(values, &is_binary/1) do
          section =
            values
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.map_join("\n", &("- " <> &1))

          {:ok, section}
        else
          {:error, {:invalid_execution_request_field, key}}
        end

      value when is_binary(value) ->
        {:ok, String.trim(value)}

      nil ->
        {:ok, nil}

      _ ->
        {:error, {:invalid_execution_request_field, key}}
    end
  end

  defp json_section(payload, key) do
    case Map.get(payload, key) || Map.get(payload, String.to_atom(key)) do
      value when is_map(value) -> Jason.encode!(value, pretty: true)
      value when is_list(value) -> Jason.encode!(value, pretty: true)
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp atomize_contract_keys(contract) do
    Map.new(contract, fn {key, value} -> {String.to_atom(key), normalize_contract_value(value)} end)
  end

  defp normalize_contract_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), normalize_contract_value(nested_value)} end)
  end

  defp normalize_contract_value(value) when is_list(value), do: Enum.map(value, &normalize_contract_value/1)
  defp normalize_contract_value(value), do: value

  defp sha256(json) do
    :crypto.hash(:sha256, json)
    |> Base.encode16(case: :lower)
  end
end
