defmodule Rondo.ProcessProvider.Failure do
  @moduledoc """
  Shared formatter for actionable process-provider failures.
  """

  alias Rondo.Config

  @type payload :: %{
          required(:provider_kind) => String.t(),
          required(:phase) => String.t(),
          required(:reason_code) => String.t(),
          required(:reason) => String.t(),
          required(:message) => String.t(),
          optional(:artifact_path) => String.t() | nil,
          optional(:artifact_source) => atom() | String.t() | nil,
          optional(:required) => boolean(),
          optional(:raw_reason) => term()
        }

  @spec payload(module() | atom() | String.t(), atom() | String.t(), term(), keyword()) :: payload()
  def payload(provider, phase, reason, opts \\ []) do
    provider_kind = provider_kind(provider)
    artifact_context = artifact_context(provider, opts)
    required? = Keyword.get(opts, :required, false)
    phase_label = phase_label(phase)
    reason_code = reason_code(reason, phase_label)
    {artifact_path, artifact_source} = reason_artifact_context(reason)
    artifact_path = artifact_path || Map.get(artifact_context, :artifact_path)
    artifact_source = artifact_source || Map.get(artifact_context, :artifact_source)

    %{
      provider_kind: provider_kind,
      phase: phase_label,
      required: required?,
      reason_code: reason_code,
      reason: reason_text(reason),
      raw_reason: reason_text(reason),
      artifact_path: artifact_path,
      artifact_source: artifact_source,
      message: message(provider_kind, phase_label, reason_code, reason, artifact_path, required?)
    }
    |> drop_nil_values()
  end

  @spec provider_kind(module() | atom() | String.t()) :: String.t()
  def provider_kind(provider) when is_atom(provider) do
    if function_exported?(provider, :id, 0) do
      provider.id()
    else
      provider
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
    end
  end

  def provider_kind(provider) when is_binary(provider), do: provider

  def provider_kind(provider), do: inspect(provider)

  defp artifact_context(provider, opts) do
    if is_atom(provider) and Code.ensure_loaded?(provider) and function_exported?(provider, :artifact_context, 1) do
      provider.artifact_context(opts)
    else
      artifact_context_from_opts(opts)
    end
  end

  defp artifact_context_from_opts(opts) do
    source_contract = Keyword.get(opts, :source_contract, %{}) || %{}

    cond do
      path = source_contract_process_provider_path(source_contract) ->
        %{artifact_path: path, artifact_source: :source_contract_process_provider}

      path = source_contract_path(source_contract) ->
        %{artifact_path: path, artifact_source: :source_contract_path}

      path = Config.process_provider_artifact_path() ->
        %{artifact_path: path, artifact_source: :config}

      true ->
        %{artifact_path: nil, artifact_source: nil}
    end
  end

  defp source_contract_process_provider_path(source_contract) when is_map(source_contract) do
    source_contract
    |> map_value(:process_provider)
    |> case do
      provider when is_map(provider) -> map_value(provider, :artifact_path)
      _other -> nil
    end
  end

  defp source_contract_path(source_contract) when is_map(source_contract) do
    map_value(source_contract, :manifest_path) || map_value(source_contract, :path)
  end

  defp map_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp phase_label(phase) when is_atom(phase), do: Atom.to_string(phase)
  defp phase_label(phase) when is_binary(phase), do: phase
  defp phase_label(phase), do: to_string(phase)

  defp reason_code(%{checks: checks} = probe, phase) when is_map(checks) do
    artifact_reason_code(checks) || action_policy_reason_code(checks) || probe_reason_code(probe, phase)
  end

  defp reason_code({:artifact_error, _source, _path, reason}, phase), do: reason_code(reason, phase)
  defp reason_code({:error, reason}, phase), do: reason_code(reason, phase)
  defp reason_code({:probe_failed, probe}, phase), do: reason_code(probe, phase)
  defp reason_code({:read_failed, _path, _reason}, _phase), do: "process_provider_read_failed"
  defp reason_code({:invalid_json, _path, _message}, _phase), do: "process_provider_invalid_json"
  defp reason_code({:unsupported_artifact_schema, _schema}, _phase), do: "process_provider_unsupported_artifact_schema"
  defp reason_code({:artifact_not_approved, _status}, _phase), do: "process_provider_artifact_not_approved"
  defp reason_code({:invalid_artifact_id, _details}, _phase), do: "process_provider_invalid_artifact_id"
  defp reason_code(:invalid_artifact_id, _phase), do: "process_provider_invalid_artifact_id"
  defp reason_code(:invalid_artifact, _phase), do: "process_provider_invalid_artifact"
  defp reason_code(:missing_artifact_path, _phase), do: "process_provider_missing_artifact_path"
  defp reason_code({:invalid_artifact_field, field}, _phase), do: "process_provider_invalid_artifact_field_#{slug(field)}"
  defp reason_code(:action_policy_unavailable, _phase), do: "process_provider_action_policy_unavailable"
  defp reason_code({:action_policy_guidance_required, _interrupt}, _phase), do: "process_provider_action_policy_requires_approval"
  defp reason_code({:action_policy_denied, _envelope}, _phase), do: "process_provider_action_policy_denied"
  defp reason_code({:action_policy_requires_approval, _envelope}, _phase), do: "process_provider_action_policy_requires_approval"
  defp reason_code({:process_provider_failed, _payload}, _phase), do: "process_provider_failed"
  defp reason_code({:process_provider_required_failed, _payload}, _phase), do: "process_provider_required_failed"
  defp reason_code(_reason, phase), do: "process_provider_#{slug(phase)}_failed"

  defp artifact_reason_code(checks) do
    case Map.get(checks, :artifact) || Map.get(checks, "artifact") do
      {:error, reason} -> reason_code(reason, :artifact)
      _other -> nil
    end
  end

  defp action_policy_reason_code(checks) do
    case Map.get(checks, :action_policy) || Map.get(checks, "action_policy") do
      :missing -> "process_provider_action_policy_unavailable"
      "missing" -> "process_provider_action_policy_unavailable"
      :ok -> nil
      "ok" -> nil
      _other -> nil
    end
  end

  defp probe_reason_code(%{status: status}, phase) do
    "process_provider_#{slug(phase)}_#{slug(status)}"
  end

  defp reason_artifact_context(%{checks: checks}) when is_map(checks) do
    reason_artifact_context(Map.get(checks, :artifact) || Map.get(checks, "artifact"))
  end

  defp reason_artifact_context({:error, reason}), do: reason_artifact_context(reason)
  defp reason_artifact_context({:artifact_error, source, path, _reason}) when is_binary(path), do: {path, source}
  defp reason_artifact_context({:read_failed, path, _reason}) when is_binary(path), do: {path, nil}
  defp reason_artifact_context({:invalid_json, path, _message}) when is_binary(path), do: {path, nil}
  defp reason_artifact_context({:artifact_error, source, path, _reason}) when is_nil(path), do: {nil, source}
  defp reason_artifact_context({:read_failed, _path, _reason}), do: {nil, nil}
  defp reason_artifact_context({:invalid_json, _path, _message}), do: {nil, nil}
  defp reason_artifact_context(_reason), do: {nil, nil}

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text({:artifact_error, _source, _path, reason}), do: reason_text(reason)
  defp reason_text({:error, reason}), do: reason_text(reason)
  defp reason_text(reason), do: inspect(reason)

  defp message(provider_kind, phase, reason_code, reason, artifact_path, required?) do
    provider_label = display_provider_kind(provider_kind)
    reason_text = reason_text(reason)
    artifact_text = artifact_path || "missing"
    subject = if(required?, do: "Required #{provider_label} process provider", else: "#{provider_label} process provider")

    message_for_reason_code(reason_code, subject, reason_text, artifact_text, phase)
  end

  defp message_for_reason_code("process_provider_missing_artifact_path", subject, _reason_text, _artifact_text, _phase) do
    "#{subject} has no configured artifact path; set process_provider.artifact_path in WORKFLOW.md."
  end

  defp message_for_reason_code("process_provider_read_failed", subject, reason_text, artifact_text, _phase) do
    "#{subject} could not read artifact_path=#{artifact_text}: #{reason_text}"
  end

  defp message_for_reason_code("process_provider_invalid_json", subject, reason_text, artifact_text, _phase) do
    "#{subject} found invalid JSON at artifact_path=#{artifact_text}: #{reason_text}"
  end

  defp message_for_reason_code("process_provider_unsupported_artifact_schema", subject, reason_text, artifact_text, _phase) do
    "#{subject} artifact at artifact_path=#{artifact_text} uses an unsupported schema: #{reason_text}"
  end

  defp message_for_reason_code("process_provider_artifact_not_approved", subject, reason_text, artifact_text, _phase) do
    "#{subject} artifact at artifact_path=#{artifact_text} was not approved: #{reason_text}"
  end

  defp message_for_reason_code("process_provider_action_policy_unavailable", subject, _reason_text, artifact_text, _phase) do
    "#{subject} artifact at artifact_path=#{artifact_text} has no usable action_policy; check the approved artifact and its action_policy decision."
  end

  defp message_for_reason_code("process_provider_action_policy_denied", subject, reason_text, artifact_text, _phase) do
    "#{subject} artifact at artifact_path=#{artifact_text} was rejected by action policy: #{reason_text}"
  end

  defp message_for_reason_code("process_provider_action_policy_requires_approval", subject, reason_text, artifact_text, _phase) do
    "#{subject} artifact at artifact_path=#{artifact_text} requires approval: #{reason_text}"
  end

  defp message_for_reason_code(code, subject, reason_text, artifact_text, phase) when is_binary(code) do
    if String.starts_with?(code, "process_provider_invalid_artifact_field_") do
      field = String.replace_prefix(code, "process_provider_invalid_artifact_field_", "")
      "#{subject} artifact at artifact_path=#{artifact_text} failed validation for #{field}: #{reason_text}"
    else
      "#{subject} failed during #{phase} for artifact_path=#{artifact_text}: #{reason_text}"
    end
  end

  defp display_provider_kind("beislid"), do: "Beislið"
  defp display_provider_kind(kind), do: kind

  defp slug(value) when is_atom(value), do: value |> Atom.to_string() |> slug()

  defp slug(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "unknown"
      other -> other
    end
  end

  defp slug(value), do: value |> to_string() |> slug()

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
