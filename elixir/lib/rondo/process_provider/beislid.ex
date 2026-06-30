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
      model_routing_hints: "deferred_runtime_resolution",
      proof_requirements: "fixture_metadata",
      probes: "beislid"
    }
  end

  @impl true
  def probe(opts \\ []) do
    case load_artifact(opts) do
      {:ok, artifact} ->
        ProcessProvider.probe_result(:ok, probe_checks(artifact))

      {:error, reason} ->
        ProcessProvider.probe_result(:missing, %{artifact: {:error, reason}})
    end
  end

  @impl true
  def select_gates(opts \\ []) do
    with {:ok, artifact} <- load_artifact(opts) do
      selection = select_artifact_gates(artifact, opts)

      {:ok,
       ProcessProvider.gate_selection_result(selection.gates,
         selected: selection.selected,
         skipped: selection.skipped,
         warnings: selection.warnings,
         changed_files: selection.changed_files,
         diff_source: selection.diff_source,
         metadata: selection.metadata
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
         {:ok, gate_sets} <- normalize_gate_sets(Map.get(payload, "gate_sets", [])),
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
         gate_sets: gate_sets,
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
         stage: string_or_nil(Map.get(gate, "stage")),
         reason: string_or_nil(Map.get(gate, "reason")) || "selected by Beislið process artifact"
       }}
    end
  end

  defp normalize_gate(_gate), do: {:error, {:invalid_artifact_field, "gates"}}

  defp normalize_gate_sets(gate_sets) when is_list(gate_sets) do
    gate_sets
    |> Enum.reduce_while({:ok, []}, fn gate_set, {:ok, acc} ->
      case normalize_gate_set(gate_set) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_gate_sets(_gate_sets), do: {:error, {:invalid_artifact_field, "gate_sets"}}

  defp normalize_gate_set(%{"id" => id, "paths" => paths, "gates" => gates} = gate_set) when is_binary(id) and is_list(paths) do
    id = String.trim(id)
    paths = paths |> Enum.filter(&(is_binary(&1) and String.trim(&1) != "")) |> Enum.map(&String.trim/1)

    if id == "" or paths == [] do
      {:error, {:invalid_artifact_field, "gate_sets"}}
    else
      with {:ok, gates} <- normalize_gates(gates) do
        {:ok,
         %{
           id: id,
           paths: paths,
           gates: gates,
           reason: string_or_nil(Map.get(gate_set, "reason")) || "matched changed-file selector #{id}"
         }}
      end
    end
  end

  defp normalize_gate_set(_gate_set), do: {:error, {:invalid_artifact_field, "gate_sets"}}

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

  defp gates_for_stage(gates, nil), do: gates

  defp gates_for_stage(gates, stage) when is_atom(stage), do: gates_for_stage(gates, Atom.to_string(stage))

  defp gates_for_stage(gates, stage) when is_binary(stage) do
    Enum.filter(gates, fn gate -> gate_selected_for_stage?(gate, stage) end)
  end

  defp gate_selected_for_stage?(gate, stage) do
    case Map.get(gate, :stage) do
      nil -> true
      "shared" -> true
      ^stage -> true
      _other -> false
    end
  end

  defp select_artifact_gates(%{gate_sets: gate_sets} = artifact, opts) when is_list(gate_sets) and gate_sets != [] do
    stage = Keyword.get(opts, :stage)
    changed_files = opts |> Keyword.get(:changed_files, []) |> normalize_changed_files()
    diff_source = opts |> Keyword.get(:changed_files_metadata, %{}) |> Map.get(:source)

    gate_sets = Enum.map(gate_sets, fn gate_set -> %{gate_set | gates: gates_for_stage(gate_set.gates, stage)} end)
    {matched_sets, unmatched_sets} = Enum.split_with(gate_sets, &gate_set_matches?(&1, changed_files))
    {gates, selected} = selected_gates_from_sets(matched_sets)
    unmatched_files = unmatched_changed_files(changed_files, matched_sets)

    %{
      gates: gates,
      selected: selected,
      skipped: artifact.skipped ++ skipped_gate_sets(unmatched_sets),
      warnings: artifact.warnings ++ selector_warnings(unmatched_files),
      changed_files: changed_files,
      diff_source: diff_source,
      metadata:
        gate_metadata(artifact, opts)
        |> Map.merge(%{
          selector_mode: "changed_files",
          matched_selectors: Enum.map(matched_sets, & &1.id),
          unmatched_changed_files: unmatched_files
        })
    }
  end

  defp select_artifact_gates(artifact, opts) do
    changed_files = opts |> Keyword.get(:changed_files, []) |> normalize_changed_files()
    diff_source = opts |> Keyword.get(:changed_files_metadata, %{}) |> Map.get(:source)
    selected_artifact_gates = gates_for_stage(Map.get(artifact, :gates, []), Keyword.get(opts, :stage))
    gates = Enum.map(selected_artifact_gates, &gate_definition/1)

    %{
      gates: gates,
      selected: Enum.map(selected_artifact_gates, &selected_reason/1),
      skipped: Map.get(artifact, :skipped, []),
      warnings: Map.get(artifact, :warnings, []),
      changed_files: changed_files,
      diff_source: diff_source,
      metadata: gate_metadata(artifact, opts)
    }
  end

  defp selected_gates_from_sets(gate_sets) do
    gate_sets
    |> Enum.flat_map(fn gate_set -> Enum.map(gate_set.gates, &{gate_set, &1}) end)
    |> Enum.reduce({[], [], MapSet.new()}, fn {gate_set, gate}, {gates, selected, seen_names} ->
      name = Map.fetch!(gate, :name)

      if MapSet.member?(seen_names, name) do
        {gates, selected, seen_names}
      else
        {gates ++ [gate_definition(gate)], selected ++ [selector_selected_reason(gate_set, gate)], MapSet.put(seen_names, name)}
      end
    end)
    |> then(fn {gates, selected, _seen_names} -> {gates, selected} end)
  end

  defp selector_selected_reason(gate_set, gate) do
    %{name: Map.fetch!(gate, :name), reason: Map.get(gate, :reason) || gate_set.reason <> " (#{Enum.join(gate_set.paths, ", ")})"}
  end

  defp skipped_gate_sets(gate_sets) do
    Enum.map(gate_sets, &%{name: &1.id, reason: "no changed files matched selectors: #{Enum.join(&1.paths, ", ")}"})
  end

  defp selector_warnings(changed_files) do
    Enum.map(changed_files, &%{message: "no provider gate selector matched changed file", path: &1})
  end

  defp unmatched_changed_files(changed_files, matched_sets) do
    Enum.reject(changed_files, fn path -> Enum.any?(matched_sets, &path_matches_gate_set?(path, &1)) end)
  end

  defp gate_set_matches?(gate_set, changed_files), do: Enum.any?(changed_files, &path_matches_gate_set?(&1, gate_set))

  defp path_matches_gate_set?(path, gate_set), do: Enum.any?(gate_set.paths, &path_matches_selector?(path, &1))

  defp path_matches_selector?(path, selector) do
    path = normalize_path(path)
    selector = normalize_path(selector)

    cond do
      String.ends_with?(selector, "/") -> String.starts_with?(path, selector)
      String.contains?(selector, ["*", "?"]) -> Regex.match?(glob_regex(selector), path)
      true -> path == selector or String.starts_with?(path, selector <> "/")
    end
  end

  defp glob_regex(selector) do
    regex =
      selector
      |> Regex.escape()
      |> String.replace("\\*\\*/", "(?:.*/)?")
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")

    Regex.compile!("^" <> regex <> "$")
  end

  defp normalize_changed_files(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_path/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_changed_files(_paths), do: []

  defp normalize_path(path) do
    path
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
  end

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
    - Gate count: #{length(artifact.gates)} flat, #{length(Map.get(artifact, :gate_sets, []))} selector sets
    - Guide/proof metadata: #{guide_status(artifact)}/#{proof_status(artifact)}
    """
  end

  defp probe_checks(artifact) do
    %{
      artifact: :ok,
      gate_selection: :ok,
      changed_file_selectors: changed_file_selector_status(artifact),
      guide_selection: guide_status(artifact),
      proof_requirements: proof_status(artifact),
      model_routing_hints: model_routing_status(artifact),
      action_policy: action_policy_status(artifact)
    }
  end

  defp changed_file_selector_status(%{gate_sets: gate_sets}) when is_list(gate_sets) and gate_sets != [], do: :ok
  defp changed_file_selector_status(_artifact), do: :unsupported

  defp guide_status(%{guides: []}), do: :unsupported
  defp guide_status(%{guides: guides}) when is_list(guides), do: :deferred

  defp proof_status(%{proof_requirements: []}), do: :unsupported
  defp proof_status(%{proof_requirements: _proof_requirements}), do: :ok

  defp action_policy_status(%{action_policy: %{"decision" => decision}}) when decision in ["allow", "ask", "deny"], do: :ok
  defp action_policy_status(%{action_policy: policy}) when map_size(policy) == 0, do: :missing

  defp model_routing_status(%{model_routing_hints: hints}) when is_map(hints) and map_size(hints) > 0, do: :deferred
  defp model_routing_status(_artifact), do: :unsupported

  defp artifact_action_policy_decision(%{action_policy: %{"decision" => decision}}) when decision in ["allow", "ask", "deny"], do: {:ok, decision}
  defp artifact_action_policy_decision(_artifact), do: {:error, :action_policy_unavailable}

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
