defmodule Rondo.ExecutionRequest do
  @moduledoc """
  Loader for local approved-slice / execution-request manifests.
  """

  alias Rondo.Beislid.ExportValidator
  alias Rondo.Linear.Issue

  @schemas ["approved-slice-v1", "rondo-execution-request-v1"]
  @max_repo_id_bytes 512
  @max_plot_id_bytes 512
  @control_character_pattern ~r/[\x00-\x1F\x7F-\x9F]/u
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @metadata_keys ~w(source_ticket parent_contract repo boundaries dependencies proof_requirements allowed_actions process_provider memory_provider output_expectations runner_extensions model_routing model_routing_hints)

  @type t :: %{
          issue: Issue.t(),
          source_contract: map()
        }

  @type prepared_submission :: %{
          issue: Issue.t(),
          source_contract: map(),
          repo_id: String.t(),
          plot_id: String.t() | nil,
          policy_file: Path.t() | nil,
          manifest_evidence: evidence(),
          approval_evidence: approval_evidence()
        }

  @type evidence :: %{
          source_path: Path.t(),
          sha256: String.t(),
          bytes: binary()
        }

  @type approval_evidence :: %{
          source_path: Path.t(),
          sha256: String.t(),
          bytes: binary(),
          kind: String.t(),
          version: pos_integer(),
          status: String.t(),
          approved_at: String.t(),
          approved_by: String.t(),
          slice_id: String.t(),
          verdict: term()
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

  @spec prepare_core_submission(Path.t(), String.t(), String.t()) ::
          {:ok, prepared_submission()} | {:error, term()}
  def prepare_core_submission(path, expected_sha256, repo_id) do
    prepare_core_submission(path, expected_sha256, repo_id, nil)
  end

  @spec prepare_core_submission(Path.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, prepared_submission()} | {:error, term()}
  def prepare_core_submission(path, expected_sha256, repo_id, plot_id) do
    with :ok <- validate_expected_sha256(expected_sha256),
         :ok <- validate_repo_id(repo_id),
         :ok <- validate_plot_id(plot_id),
         {:ok, export} <- validate_export(path),
         digest = export.manifest.sha256,
         :ok <- verify_sha256(expected_sha256, digest),
         {:ok, payload} <- decode_validated_manifest(export.manifest),
         {:ok, request} <-
           normalize(
             payload,
             export.manifest.source_path,
             export.manifest.bytes
           ),
         {:ok, policy_file} <- resolve_manifest_policy_file(request.source_contract) do
      identity = execution_identity(repo_id, digest, plot_id)

      issue = %{
        request.issue
        | id: "execution-request:#{identity}",
          identifier: "execution-request-#{identity}"
      }

      {:ok,
       %{
         issue: issue,
         source_contract: request.source_contract,
         repo_id: repo_id,
         plot_id: plot_id,
         policy_file: policy_file,
         manifest_evidence: %{
           source_path: export.manifest.source_path,
           sha256: digest,
           bytes: export.manifest.bytes
         },
         approval_evidence: %{
           source_path: export.bundle.source_path,
           sha256: export.bundle.sha256,
           bytes: export.bundle.bytes,
           kind: export.approval.bundle_kind,
           version: export.approval.bundle_version,
           status: export.approval.bundle_status,
           approved_at: export.approval.approved_at,
           approved_by: export.approval.approved_by,
           slice_id: export.approval.selected_slice,
           verdict: export.approval.verdict
         }
       }}
    end
  end

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:execution_request_read_failed, path, reason}}
    end
  end

  defp validate_expected_sha256(expected_sha256)
       when is_binary(expected_sha256) do
    if Regex.match?(@sha256_pattern, expected_sha256) do
      :ok
    else
      {:error, :core_intake_invalid_expected_sha256}
    end
  end

  defp validate_expected_sha256(_expected_sha256),
    do: {:error, :core_intake_invalid_expected_sha256}

  defp validate_repo_id(repo_id) when is_binary(repo_id) do
    if repo_id == "" or String.trim(repo_id) != repo_id or
         byte_size(repo_id) > @max_repo_id_bytes or
         Regex.match?(@control_character_pattern, repo_id) do
      {:error, :core_intake_invalid_repo_id}
    else
      :ok
    end
  end

  defp validate_repo_id(_repo_id), do: {:error, :core_intake_invalid_repo_id}

  defp validate_plot_id(nil), do: :ok

  defp validate_plot_id(plot_id) when is_binary(plot_id) do
    if plot_id == "" or String.trim(plot_id) != plot_id or
         byte_size(plot_id) > @max_plot_id_bytes or
         Regex.match?(@control_character_pattern, plot_id) do
      {:error, :core_intake_invalid_plot_id}
    else
      :ok
    end
  end

  defp validate_plot_id(_plot_id), do: {:error, :core_intake_invalid_plot_id}

  defp validate_export(path) when is_binary(path),
    do: ExportValidator.validate(path)

  defp validate_export(_path), do: {:error, :core_intake_invalid_manifest_path}

  defp verify_sha256(expected_sha256, actual_sha256) do
    if expected_sha256 == actual_sha256 do
      :ok
    else
      {:error, {:core_intake_manifest_sha256_mismatch, expected_sha256, actual_sha256}}
    end
  end

  defp execution_identity(repo_id, digest, nil), do: sha256(repo_id <> <<0>> <> digest)

  defp execution_identity(repo_id, digest, plot_id),
    do: sha256(repo_id <> <<0>> <> digest <> <<0>> <> plot_id)

  defp decode_validated_manifest(%{bytes: bytes}) do
    case Jason.decode(bytes) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _other -> {:error, :core_intake_validated_manifest_invalid}
    end
  end

  # Keep this resolution behavior aligned with Rondo.RunOnce: policy paths are
  # relative to the manifest, nil is allowed, and unreadable files fail closed.
  defp resolve_manifest_policy_file(source_contract) do
    case Map.get(source_contract, :runner_extensions) do
      nil -> {:ok, nil}
      extensions when is_map(extensions) -> resolve_manifest_action_policy(extensions, source_contract)
      other -> {:error, {:invalid_manifest_runner_extensions, other}}
    end
  end

  defp resolve_manifest_action_policy(extensions, source_contract) do
    case Map.get(extensions, "action_policy") do
      nil -> {:ok, nil}
      action_policy when is_map(action_policy) -> resolve_manifest_policy_path(Map.get(action_policy, "policy_file"), source_contract)
      other -> {:error, {:invalid_manifest_runner_extensions, other}}
    end
  end

  defp resolve_manifest_policy_path(nil, _source_contract), do: {:ok, nil}

  defp resolve_manifest_policy_path(value, source_contract) when is_binary(value) do
    resolved = Path.expand(value, Path.dirname(source_contract.path))

    case File.stat(resolved) do
      {:ok, %File.Stat{type: :regular, access: access}} when access in [:read, :read_write] ->
        {:ok, resolved}

      _other ->
        {:error, {:manifest_policy_file_unreadable, resolved}}
    end
  end

  defp resolve_manifest_policy_path(value, _source_contract),
    do: {:error, {:invalid_manifest_policy_file, value}}

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
        {:ok, list_section_value(values)}

      value when is_map(value) ->
        {:ok, json_code_block(value)}

      value when is_binary(value) ->
        {:ok, String.trim(value)}

      nil ->
        {:ok, nil}

      _ ->
        {:error, {:invalid_execution_request_field, key}}
    end
  end

  defp list_section_value(values) do
    if Enum.all?(values, &is_binary/1) do
      values
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("\n", &("- " <> &1))
    else
      json_code_block(values)
    end
  end

  defp json_code_block(value) do
    "```json\n" <> Jason.encode!(value, pretty: true) <> "\n```"
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
