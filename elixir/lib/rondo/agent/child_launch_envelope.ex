defmodule Rondo.Agent.ChildLaunchEnvelope do
  @moduledoc """
  Effective capability and credential boundary for one child invocation.

  Runtime values may contain provider credentials. Use `sanitized/1` for every
  log, event, checkpoint, or manifest projection.
  """

  @enforce_keys [
    :decision,
    :reason,
    :run_mode,
    :dispatch_origin,
    :adapter,
    :model_provider,
    :isolation_baseline,
    :required_isolation_baseline,
    :home_path,
    :environment,
    :effective_actions,
    :bypass
  ]
  defstruct schema: "rondo.child_launch/v1",
            decision: nil,
            reason: nil,
            run_mode: nil,
            dispatch_origin: nil,
            adapter: nil,
            model_provider: nil,
            source_contract_digest: nil,
            requested_actions: %{},
            effective_actions: %{},
            isolation_baseline: nil,
            required_isolation_baseline: nil,
            home_path: nil,
            home_mode: :synthetic_run_scoped,
            environment: %{},
            credential_classes: [:provider_auth],
            bypass: %{}

  @type t :: %__MODULE__{}

  @spec sanitized(t()) :: map()
  def sanitized(%__MODULE__{} = envelope) do
    %{
      "schema" => envelope.schema,
      "decision" => safe_string(envelope.decision),
      "reason" => safe_string(envelope.reason),
      "run_mode" => safe_string(envelope.run_mode),
      "dispatch_origin" => safe_string(envelope.dispatch_origin),
      "adapter" => safe_string(envelope.adapter),
      "model_provider" => safe_string(envelope.model_provider),
      "source_contract_digest" => envelope.source_contract_digest,
      "requested_action_summary" => summarize_requested_actions(envelope.requested_actions),
      "effective_actions" => stringify_action_values(envelope.effective_actions),
      "isolation_baseline" => safe_string(envelope.isolation_baseline),
      "required_isolation_baseline" => safe_string(envelope.required_isolation_baseline),
      "home_mode" => safe_string(envelope.home_mode),
      "environment_names" => envelope.environment |> Map.keys() |> Enum.sort(),
      "credential_classes" => Enum.map(envelope.credential_classes, &to_string/1),
      "bypass" => stringify_action_values(envelope.bypass)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp summarize_requested_actions(actions) when is_map(actions) do
    Map.new(actions, fn
      {key, values} when is_list(values) -> {to_string(key), length(values)}
      {key, _value} -> {to_string(key), true}
    end)
  end

  defp summarize_requested_actions(_actions), do: %{}

  defp stringify_action_values(values) when is_map(values) do
    Map.new(values, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_atom(value), do: to_string(value)
  defp stringify_value(value), do: value

  defp safe_string(nil), do: nil
  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_atom(value), do: to_string(value)
  defp safe_string(_value), do: "invalid"
end
