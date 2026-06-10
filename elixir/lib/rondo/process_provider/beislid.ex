defmodule Rondo.ProcessProvider.Beislid do
  @moduledoc """
  Fixture-backed Beislið ProcessProvider adapter.

  This adapter consumes explicit, approved Beislið process artifacts when they are
  supplied through an execution request source contract or `WORKFLOW.md`. It does
  not implement the future Beislið exporter/runtime; it only maps reviewable
  exported process metadata onto Rondo's existing ProcessProvider callbacks.
  """

  @behaviour Rondo.ProcessProvider

  alias Rondo.{Config, Linear.Issue, ProcessProvider}
  alias Rondo.ProcessProvider.Native

  @artifact_schema "beislid-process-artifact-v1"

  @impl true
  def id, do: "beislid"

  @impl true
  def capabilities do
    %{
      gate_selection: "fixture",
      guide_selection: "deferred_metadata",
      action_policy: "fixture_decision",
      model_routing_hints: "unsupported_required_hints",
      proof_requirements: "fixture_metadata",
      probes: "beislid"
    }
  end

  @impl true
  def probe(opts \\ []) do
    case load_artifact(opts) do
      {:ok, artifact} ->
        checks = probe_checks(artifact)
        status = if blocking_checks?(checks), do: :unsupported, else: :ok
        ProcessProvider.probe_result(status, checks)

      {:error, reason} ->
        ProcessProvider.probe_result(:missing, %{artifact: {:error, reason}})
    end
  end

  @impl true
  def select_gates(opts \\ []) do
    with {:ok, artifact} <- load_artifact(opts),
         :ok <- ensure_no_blocking_required_constraints(artifact) do
      gates = Enum.map(Map.get(artifact, :gates, []), &gate_definition/1)

      {:ok,
       ProcessProvider.gate_selection_result(gates,
         selected: Enum.map(Map.get(artifact, :gates, []), &selected_reason/1),
         skipped: Map.get(artifact, :skipped, []),
         warnings: Map.get(artifact, :warnings, []),
         metadata: gate_metadata(artifact, opts)
       )}
    end
  end

  @impl true
  def select_guides(opts \\ []) do
    case load_artifact(opts) do
      {:ok, artifact} -> {:ok, Map.get(artifact, :guides, [])}
      {:error, _reason} -> {:ok, []}
    end
  end

  @impl true
  def prompt(%Issue{} = issue, opts \\ []) do
    native_prompt = Native.prompt(issue, opts)

    case load_artifact(opts) do
      {:ok, artifact} -> native_prompt <> beislid_context(artifact)
      {:error, _reason} -> native_prompt
    end
  end

  @impl true
  def model_routing_hints(opts \\ []) do
    case load_artifact(opts) do
      {:ok, artifact} -> Map.get(artifact, :model_routing_hints, %{})
      {:error, _reason} -> %{}
    end
  end

  @impl true
  def proof_requirements(opts \\ []) do
    case load_artifact(opts) do
      {:ok, artifact} -> {:ok, Map.get(artifact, :proof_requirements, [])}
      {:error, _reason} -> {:ok, []}
    end
  end

  @impl true
  def evaluate_action_policy(action, classes, opts \\ []) do
    with {:ok, artifact} <- load_artifact(opts),
         {:ok, decision} <- artifact_action_policy_decision(artifact) do
      {:ok,
       %{
         "decision" => decision,
         "action" => action,
         "classes" => classes,
         "mode" => Keyword.get(opts, :mode, Config.action_policy_run_mode()),
         "provider" => id()
       }}
    end
  end

  @spec action_policy_available?(keyword()) :: boolean()
  def action_policy_available?(opts \\ []) do
    case load_artifact(opts) do
      {:ok, artifact} -> action_policy_status(artifact) == :ok
      {:error, _reason} -> false
    end
  end

  defp load_artifact(opts) do
    opts
    |> artifact_candidates()
    |> load_first_artifact()
  end

  defp artifact_candidates(opts) do
    source_contract = Keyword.get(opts, :source_contract, %{}) || %{}

    [
      {:source_contract_process_provider, source_contract_process_provider_path(source_contract)},
      {:source_contract_path, source_contract_path(source_contract)},
      {:config, Config.process_provider_artifact_path()}
    ]
    |> Enum.filter(fn {_source, path} -> is_binary(path) and String.trim(path) != "" end)
  end

  defp load_first_artifact([]), do: {:error, :missing_artifact_path}

  defp load_first_artifact([{:source_contract_path, path} | rest]) do
    case read_artifact(path) do
      {:ok, %{"schema" => @artifact_schema} = payload} -> normalize_artifact(payload, path, :source_contract_path)
      {:ok, _payload} -> load_first_artifact(rest)
      {:error, _reason} -> load_first_artifact(rest)
    end
  end

  defp load_first_artifact([{:source_contract_process_provider, path} | _rest]) do
    with {:ok, payload} <- read_artifact(path) do
      normalize_artifact(payload, path, :source_contract_process_provider)
    end
  end

  defp load_first_artifact([{source, path} | rest]) do
    case read_artifact(path) do
      {:ok, payload} -> normalize_artifact(payload, path, source)
      {:error, reason} -> if(rest == [], do: {:error, reason}, else: load_first_artifact(rest))
    end
  end

  defp read_artifact(path) do
    expanded_path = Path.expand(path)

    with {:ok, json} <- File.read(expanded_path),
         {:ok, payload} <- Jason.decode(json) do
      {:ok, payload}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, expanded_path, Exception.message(error)}}
      {:error, reason} -> {:error, {:read_failed, expanded_path, reason}}
    end
  end

  defp normalize_artifact(%{"schema" => @artifact_schema, "id" => id, "status" => "approved"} = payload, path, source)
       when is_binary(id) do
    with {:ok, gates} <- normalize_gates(Map.get(payload, "gates", [])),
         {:ok, skipped} <- normalize_reasons(Map.get(payload, "skipped", [])),
         {:ok, warnings} <- normalize_warnings(Map.get(payload, "warnings", [])),
         {:ok, guides} <- normalize_maps(Map.get(payload, "guides", []), "guides"),
         {:ok, proof_requirements} <- normalize_maps(Map.get(payload, "proof_requirements", []), "proof_requirements"),
         {:ok, action_policy} <- normalize_action_policy(Map.get(payload, "action_policy", :missing)) do
      {:ok,
       %{
         id: id,
         path: Path.expand(path),
         source: source,
         gates: gates,
         skipped: skipped,
         warnings: warnings,
         guides: guides,
         proof_requirements: proof_requirements,
         metadata: normalize_metadata(Map.get(payload, "metadata", %{})),
         model_routing_hints: normalize_metadata(Map.get(payload, "model_routing_hints", %{})),
         action_policy: action_policy
       }}
    end
  end

  defp normalize_artifact(%{"schema" => @artifact_schema, "status" => "approved"}, _path, _source), do: {:error, :invalid_artifact_id}
  defp normalize_artifact(%{"schema" => @artifact_schema, "status" => status}, _path, _source), do: {:error, {:artifact_not_approved, status}}
  defp normalize_artifact(%{"schema" => schema}, _path, _source), do: {:error, {:unsupported_artifact_schema, schema}}
  defp normalize_artifact(_payload, _path, _source), do: {:error, :invalid_artifact}

  defp normalize_gates(gates) when is_list(gates) do
    gates
    |> Enum.reduce_while({:ok, []}, fn gate, {:ok, acc} ->
      case normalize_gate(gate) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_gates(_gates), do: {:error, {:invalid_artifact_field, "gates"}}

  defp normalize_gate(%{"name" => name, "command" => command} = gate) when is_binary(name) and is_binary(command) do
    name = String.trim(name)
    command = String.trim(command)

    if name == "" or command == "" do
      {:error, {:invalid_artifact_field, "gates"}}
    else
      {:ok,
       %{
         name: name,
         command: command,
         timeout_ms: positive_integer(Map.get(gate, "timeout_ms"), Config.gates() |> default_gate_timeout()),
         action_id: string_or_nil(Map.get(gate, "action_id")),
         action_classes: string_list(Map.get(gate, "action_classes"), ["read"]),
         reason: string_or_nil(Map.get(gate, "reason")) || "selected by Beislið process artifact"
       }}
    end
  end

  defp normalize_gate(_gate), do: {:error, {:invalid_artifact_field, "gates"}}

  defp normalize_reasons(reasons) when is_list(reasons) do
    reasons
    |> Enum.reduce_while({:ok, []}, fn
      %{"name" => name, "reason" => reason}, {:ok, acc} when is_binary(name) and is_binary(reason) ->
        {:cont, {:ok, acc ++ [%{name: name, reason: reason}]}}

      other, {:ok, acc} when is_map(other) ->
        with {:ok, name} <- optional_string_field(other, "name", "item"),
             {:ok, reason} <- optional_string_field(other, "reason", "skipped by Beislið process artifact") do
          {:cont, {:ok, acc ++ [%{name: name, reason: reason}]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _other, {:ok, _acc} ->
        {:halt, {:error, {:invalid_artifact_field, "skipped"}}}
    end)
  end

  defp normalize_reasons(_reasons), do: {:error, {:invalid_artifact_field, "skipped"}}

  defp normalize_warnings(warnings) when is_list(warnings) do
    warnings
    |> Enum.reduce_while({:ok, []}, fn
      %{"message" => message}, {:ok, acc} when is_binary(message) ->
        {:cont, {:ok, acc ++ [%{message: message}]}}

      _other, {:ok, _acc} ->
        {:halt, {:error, {:invalid_artifact_field, "warnings"}}}
    end)
  end

  defp normalize_warnings(_warnings), do: {:error, {:invalid_artifact_field, "warnings"}}

  defp normalize_maps(values, field) when is_list(values) do
    if Enum.all?(values, &is_map/1), do: {:ok, values}, else: {:error, {:invalid_artifact_field, field}}
  end

  defp normalize_maps(_values, field), do: {:error, {:invalid_artifact_field, field}}

  defp normalize_action_policy(:missing), do: {:ok, %{}}
  defp normalize_action_policy(policy) when map_size(policy) == 0, do: {:ok, %{}}
  defp normalize_action_policy(%{"decision" => decision} = policy) when decision in ["allow", "ask", "deny"], do: {:ok, policy}
  defp normalize_action_policy(_policy), do: {:error, {:invalid_artifact_field, "action_policy"}}

  defp normalize_metadata(value) when is_map(value), do: value
  defp normalize_metadata(_value), do: %{}

  defp gate_definition(gate) do
    Map.take(gate, [:name, :command, :timeout_ms, :action_id, :action_classes])
  end

  defp selected_reason(gate), do: %{name: Map.fetch!(gate, :name), reason: Map.fetch!(gate, :reason)}

  defp gate_metadata(artifact, opts) do
    artifact.metadata
    |> atom_key_metadata()
    |> Map.merge(%{provider: id(), artifact_id: artifact.id, source: Atom.to_string(artifact.source), path: artifact.path})
    |> maybe_put(:stage, Keyword.get(opts, :stage))
  end

  defp beislid_context(artifact) do
    """

    ## Beislið process context

    - Artifact: #{artifact.id}
    - Source: #{artifact.source}
    - Gate count: #{length(artifact.gates)}
    - Guide/proof metadata: #{guide_status(artifact)}/#{proof_status(artifact)}
    """
  end

  defp probe_checks(artifact) do
    %{
      artifact: :ok,
      gate_selection: :ok,
      guide_selection: guide_status(artifact),
      proof_requirements: proof_status(artifact),
      action_policy: action_policy_status(artifact)
    }
    |> maybe_put_blocking(artifact)
  end

  defp guide_status(%{guides: []}), do: :unsupported
  defp guide_status(%{guides: guides}) when is_list(guides), do: :deferred

  defp proof_status(%{proof_requirements: []}), do: :unsupported
  defp proof_status(%{proof_requirements: _proof_requirements}), do: :ok

  defp action_policy_status(%{action_policy: %{"decision" => decision}}) when decision in ["allow", "ask", "deny"], do: :ok
  defp action_policy_status(%{action_policy: policy}) when map_size(policy) == 0, do: :missing

  defp artifact_action_policy_decision(%{action_policy: %{"decision" => decision}}) when decision in ["allow", "ask", "deny"], do: {:ok, decision}
  defp artifact_action_policy_decision(_artifact), do: {:error, :action_policy_unavailable}

  defp maybe_put_blocking(checks, artifact) do
    if required_model_hint?(artifact) do
      Map.put(checks, :blocking, %{model_routing_hints: :unsupported_required_capability})
    else
      checks
    end
  end

  defp ensure_no_blocking_required_constraints(artifact) do
    if required_model_hint?(artifact) do
      {:error, {:unsupported_required_capability, :model_routing_hints}}
    else
      :ok
    end
  end

  defp blocking_checks?(checks), do: map_size(Map.get(checks, :blocking, %{})) > 0

  defp required_model_hint?(%{model_routing_hints: hints}) when is_map(hints) do
    Map.get(hints, "required") == true or Map.get(hints, "mode") == "require"
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

  defp optional_string_field(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_artifact_field, "skipped"}}
      :error -> {:ok, default}
    end
  end

  defp string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_or_nil(_value), do: nil

  defp string_list(values, default) when is_list(values) do
    values = Enum.filter(values, &(is_binary(&1) and String.trim(&1) != ""))
    if values == [], do: default, else: values
  end

  defp string_list(_values, default), do: default

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp default_gate_timeout([%{timeout_ms: timeout_ms} | _]) when is_integer(timeout_ms), do: timeout_ms
  defp default_gate_timeout(_gates), do: 60_000

  defp atom_key_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn
      {"artifact_ref", value} -> {:artifact_ref, value}
      {"source_kind", value} -> {:source_kind, value}
      {key, value} -> {key, value}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
