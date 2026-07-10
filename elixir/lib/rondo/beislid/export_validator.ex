defmodule Rondo.Beislid.ExportValidator do
  @moduledoc """
  Validates approved Beislið export bundles without invoking producer code.

  The accepted contract is pinned under `priv/contracts/beislid`. Shape is
  checked with the producer's documented JSON Schema subset, then the graph,
  cross-file, and non-empty-list semantics from `validate_export.py` are
  applied in-process.
  """

  alias Rondo.Beislid.SchemaSubset
  alias Rondo.PathSafety

  @bundle_schema_path "contracts/beislid/approved-slice-plan-export-v0.schema.json"
  @slice_schema_path "contracts/beislid/execution-envelope-v0.schema.json"
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @safe_component_pattern ~r/\A[^\x00-\x1F\x7F\/\\]+\z/u

  defmodule Error do
    @moduledoc false

    @enforce_keys [:code, :message, :violations]
    defstruct [:code, :message, :violations]

    @type t :: %__MODULE__{
            code: :invalid_export | :unapproved_export | :unsafe_export_path | :export_changed,
            message: String.t(),
            violations: [Rondo.Beislid.SchemaSubset.violation()]
          }
  end

  @type file_evidence :: %{
          source_path: Path.t(),
          bytes: binary(),
          sha256: String.t()
        }

  @type approval_evidence :: %{
          approved_at: String.t(),
          approved_by: String.t(),
          bundle_kind: String.t(),
          bundle_status: String.t(),
          bundle_version: pos_integer(),
          selected_slice: String.t(),
          verdict: term()
        }

  @type evidence :: %{
          bundle: file_evidence(),
          manifest: file_evidence(),
          approval: approval_evidence(),
          slice_id: String.t()
        }

  @spec validate(Path.t()) :: {:ok, evidence()} | {:error, Error.t()}
  def validate(manifest_path) when is_binary(manifest_path) do
    with {:ok, canonical_manifest_path} <- canonical_selected_manifest(manifest_path),
         {:ok, paths} <- derive_paths(canonical_manifest_path),
         {:ok, bundle_file} <- read_json_file(paths.bundle, "bundle.json"),
         {:ok, manifest_file} <- read_json_file(canonical_manifest_path, "selected-slice.json") do
      validate_loaded(paths, bundle_file, manifest_file)
    end
  end

  def validate(_manifest_path), do: unsafe_error("manifest")

  @spec verify_unchanged(evidence()) :: :ok | {:error, Error.t()}
  def verify_unchanged(%{bundle: bundle, manifest: manifest}) do
    case verify_file_evidence(bundle, "bundle.json") do
      :ok -> verify_file_evidence(manifest, "selected-slice.json")
      {:error, %Error{}} = error -> error
    end
  end

  def verify_unchanged(_evidence), do: changed_error("evidence")

  defp validate_loaded(paths, bundle_file, manifest_file) do
    bundle_schema = SchemaSubset.load!(@bundle_schema_path)
    slice_schema = SchemaSubset.load!(@slice_schema_path)

    schema_contract_violations =
      unsupported_schema_violations(bundle_schema, "bundle-schema") ++
        unsupported_schema_violations(slice_schema, "slice-schema")

    bundle_violations =
      SchemaSubset.validate(bundle_file.payload, bundle_schema, "bundle.json") ++
        validate_bundle_semantics(bundle_file.payload)

    {slice_files, cross_file_violations} =
      validate_slice_files(paths, bundle_file.payload, slice_schema)

    selected_violations =
      validate_selected_manifest(paths, manifest_file, slice_schema, slice_files)

    violations =
      schema_contract_violations ++ bundle_violations ++ cross_file_violations ++ selected_violations

    if violations == [] do
      approval = Map.fetch!(bundle_file.payload, "approval")
      slice_id = paths.slice_id

      {:ok,
       %{
         bundle: evidence(bundle_file),
         manifest: evidence(manifest_file),
         approval: %{
           approved_at: Map.fetch!(approval, "approved_at"),
           approved_by: Map.fetch!(approval, "approved_by"),
           bundle_kind: Map.fetch!(bundle_file.payload, "kind"),
           bundle_status: Map.fetch!(bundle_file.payload, "status"),
           bundle_version: Map.fetch!(bundle_file.payload, "version"),
           selected_slice: slice_id,
           verdict: selected_verdict(approval, slice_id)
         },
         slice_id: slice_id
       }}
    else
      validation_error(violations)
    end
  end

  defp unsupported_schema_violations(schema, root) do
    Enum.map(SchemaSubset.unsupported_keywords(schema), &violation("#{root}.#{&1}", :unsupported_keyword))
  end

  defp validate_bundle_semantics(bundle) when is_map(bundle) do
    validate_supersedes(bundle) ++
      validate_children(bundle) ++
      validate_dependency_graph(bundle) ++
      validate_parallel_groups(bundle)
  end

  defp validate_bundle_semantics(_bundle), do: [violation("bundle.json", :object)]

  defp validate_supersedes(bundle) do
    version = Map.get(bundle, "version")

    case Map.fetch(bundle, "supersedes") do
      :error -> [violation("bundle.json.supersedes", :required)]
      {:ok, value} -> validate_supersedes_value(value, version)
    end
  end

  defp validate_supersedes_value(nil, version) when is_integer(version) and version >= 2,
    do: [violation("bundle.json.supersedes", :version_pairing)]

  defp validate_supersedes_value(nil, _version), do: []

  defp validate_supersedes_value(value, _version) when not is_binary(value),
    do: [violation("bundle.json.supersedes", :sha256)]

  defp validate_supersedes_value(value, version) do
    cond do
      not Regex.match?(@sha256_pattern, value) ->
        [violation("bundle.json.supersedes", :sha256)]

      version == 1 ->
        [violation("bundle.json.supersedes", :version_pairing)]

      true ->
        []
    end
  end

  defp validate_children(bundle) do
    case Map.get(bundle, "children") do
      children when is_list(children) and children != [] ->
        validate_child_ids(child_ids(children))

      _other ->
        [violation("bundle.json.children", :non_empty)]
    end
  end

  defp validate_child_ids(ids) do
    duplicate_violations =
      ids
      |> Enum.frequencies()
      |> Enum.flat_map(&duplicate_child_violation/1)

    component_violations = Enum.flat_map(ids, &unsafe_child_violation/1)
    duplicate_violations ++ component_violations
  end

  defp duplicate_child_violation({_id, count}) when count > 1,
    do: [violation("bundle.json.children", :duplicate)]

  defp duplicate_child_violation({_id, _count}), do: []

  defp unsafe_child_violation(id) do
    if safe_component?(id),
      do: [],
      else: [violation("bundle.json.children", :unsafe_slice_id)]
  end

  defp validate_dependency_graph(bundle) do
    children = child_ids(Map.get(bundle, "children", []))
    known = MapSet.new(children)

    case Map.get(bundle, "dependency_graph") do
      graph when is_map(graph) ->
        validate_graph_entries(graph, known) ++ cycle_violations(graph)

      _other ->
        [violation("bundle.json.dependency_graph", :object)]
    end
  end

  defp validate_graph_entries(graph, known) do
    Enum.flat_map(graph, fn {node, dependencies} ->
      validate_graph_node(node, known) ++ validate_graph_dependencies(node, dependencies, known)
    end)
  end

  defp validate_graph_node(node, known) do
    if MapSet.member?(known, node),
      do: [],
      else: [violation("bundle.json.dependency_graph", :unknown_slice)]
  end

  defp validate_graph_dependencies(node, dependencies, known) when is_list(dependencies) do
    Enum.flat_map(dependencies, &validate_graph_dependency(&1, node, known))
  end

  defp validate_graph_dependencies(_node, _dependencies, _known),
    do: [violation("bundle.json.dependency_graph.entry", :dependency_list)]

  defp validate_graph_dependency(dependency, _node, known) do
    if is_binary(dependency) and MapSet.member?(known, dependency),
      do: [],
      else: [violation("bundle.json.dependency_graph.entry", :unknown_dependency)]
  end

  defp validate_parallel_groups(bundle) do
    case Map.get(bundle, "slice_plan") do
      %{"parallel_groups" => groups} -> validate_parallel_group_entries(groups, bundle)
      _other -> []
    end
  end

  defp validate_parallel_group_entries(groups, bundle) when is_list(groups) do
    case Enum.all?(groups, &is_list/1) do
      true -> validate_parallel_group_lists(groups, bundle)
      false -> [violation("bundle.json.slice_plan.parallel_groups", :list_of_lists)]
    end
  end

  defp validate_parallel_group_entries(_groups, _bundle) do
    [violation("bundle.json.slice_plan.parallel_groups", :list_of_lists)]
  end

  defp validate_parallel_group_lists(groups, bundle) do
    known = MapSet.new(child_ids(Map.get(bundle, "children", [])))
    flattened = Enum.flat_map(groups, & &1)

    membership_violations = Enum.flat_map(flattened, &parallel_membership_violation(&1, known))
    duplicate_violations = parallel_duplicate_violations(flattened)
    dependency_violations = parallel_dependency_violations(groups, bundle, known)

    membership_violations ++ duplicate_violations ++ dependency_violations
  end

  defp parallel_membership_violation(slice_id, known) do
    if is_binary(slice_id) and MapSet.member?(known, slice_id),
      do: [],
      else: [violation("bundle.json.slice_plan.parallel_groups", :unknown_slice)]
  end

  defp parallel_duplicate_violations(flattened) do
    flattened
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {_id, count} when count > 1 ->
        [violation("bundle.json.slice_plan.parallel_groups", :duplicate_slice)]

      {_id, _count} ->
        []
    end)
  end

  defp parallel_dependency_violations(groups, bundle, known) do
    closure = transitive_dependencies(Map.get(bundle, "dependency_graph", %{}))

    groups
    |> Enum.with_index()
    |> Enum.flat_map(fn {group, index} -> parallel_group_dependency_violations(group, index, known, closure) end)
  end

  defp parallel_group_dependency_violations(group, index, known, closure) do
    members = Enum.filter(group, &(is_binary(&1) and MapSet.member?(known, &1)))

    for slice_id <- members,
        other <- members,
        slice_id != other,
        MapSet.member?(Map.get(closure, slice_id, MapSet.new()), other) do
      violation("bundle.json.slice_plan.parallel_groups[#{index}]", :dependent_slices)
    end
  end

  defp validate_slice_files(paths, bundle, slice_schema) do
    child_ids = child_ids(Map.get(bundle, "children", []))

    {files, violations} =
      Enum.reduce(child_ids, {%{}, []}, fn child_id, {files, violations} ->
        if safe_component?(child_id) do
          validate_child_files(paths.slices_dir, child_id, slice_schema, files, violations)
        else
          {files, violations}
        end
      end)

    {files, violations ++ orphan_violations(paths.slices_dir, child_ids)}
  end

  defp validate_child_files(slices_dir, child_id, slice_schema, files, violations) do
    manifest_path = Path.join(slices_dir, child_id <> ".json")
    summary_path = Path.join(slices_dir, child_id <> ".md")

    {files, violations} =
      case read_json_file(manifest_path, "slices.child.json") do
        {:ok, file} ->
          child_violations =
            SchemaSubset.validate(file.payload, slice_schema, "slices.child.json") ++
              validate_slice_semantics(file.payload, child_id, "slices.child.json")

          {Map.put(files, child_id, file), violations ++ child_violations}

        {:error, %Error{violations: child_violations}} ->
          {files, violations ++ child_violations}
      end

    summary_violations =
      case canonical_regular_file(summary_path, "slices.child.md") do
        {:ok, _canonical_path} -> []
        {:error, %Error{violations: child_violations}} -> child_violations
      end

    {files, violations ++ summary_violations}
  end

  defp validate_slice_semantics(manifest, expected_id, root) when is_map(manifest) do
    id_violations =
      case Map.get(manifest, "slice_id") do
        ^expected_id -> []
        _other -> [violation(root <> ".slice_id", :filename_mismatch)]
      end

    prompt_violations =
      if nonempty_string?(Map.get(manifest, "prompt")) or
           nonempty_string?(Map.get(manifest, "body")) do
        []
      else
        [violation(root <> ".prompt", :prompt_or_body)]
      end

    id_violations ++ prompt_violations ++ model_routing_violations(manifest, root)
  end

  defp validate_slice_semantics(_manifest, _expected_id, root),
    do: [violation(root, :object)]

  defp model_routing_violations(manifest, root) do
    with extensions when is_map(extensions) <- Map.get(manifest, "runner_extensions"),
         routing when is_map(routing) <- Map.get(extensions, "model_routing") do
      candidates =
        case Map.get(routing, "candidates") do
          [] -> [violation(root <> ".runner_extensions.model_routing.candidates", :non_empty)]
          _other -> []
        end

      boundary_rules =
        case Map.get(routing, "routing") do
          [] -> [violation(root <> ".runner_extensions.model_routing.routing", :non_empty)]
          _other -> []
        end

      candidates ++ boundary_rules
    else
      _other -> []
    end
  end

  defp validate_selected_manifest(paths, manifest_file, slice_schema, slice_files) do
    selected = Map.get(slice_files, paths.slice_id)

    selection_violations =
      if is_nil(selected),
        do: [violation("selected-slice.json", :not_listed)],
        else: []

    payload_violations =
      SchemaSubset.validate(manifest_file.payload, slice_schema, "selected-slice.json") ++
        validate_slice_semantics(manifest_file.payload, paths.slice_id, "selected-slice.json")

    consistency_violations =
      if selected && selected.bytes != manifest_file.bytes,
        do: [violation("selected-slice.json", :cross_file_mismatch)],
        else: []

    selection_violations ++ payload_violations ++ consistency_violations
  end

  defp orphan_violations(slices_dir, child_ids) do
    known = MapSet.new(Enum.map(child_ids, &(&1 <> ".json")))

    case File.ls(slices_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(Path.extname(&1) == ".json"))
        |> Enum.reject(&MapSet.member?(known, &1))
        |> Enum.map(fn _entry -> violation("slices", :orphan_manifest) end)

      {:error, _reason} ->
        [violation("slices", :unreadable_directory)]
    end
  end

  defp cycle_violations(graph) do
    graph
    |> Map.keys()
    |> Enum.reduce({MapSet.new(), []}, &reduce_cycle_node(&1, &2, graph))
    |> elem(1)
    |> Enum.uniq()
  end

  defp reduce_cycle_node(node, {done, violations}, graph) do
    if MapSet.member?(done, node) do
      {done, violations}
    else
      {visited, cycle?} = visit_graph(node, graph, done, [])
      new_violations = cycle_violation(cycle?)
      {MapSet.union(done, visited), violations ++ new_violations}
    end
  end

  defp cycle_violation(true), do: [violation("bundle.json.dependency_graph", :cycle)]
  defp cycle_violation(false), do: []

  @spec visit_graph(String.t(), map(), MapSet.t(String.t()), [String.t()]) ::
          {MapSet.t(String.t()), boolean()}
  defp visit_graph(node, graph, done, active) do
    cond do
      node in active ->
        {MapSet.new(), true}

      MapSet.member?(done, node) ->
        {MapSet.new(), false}

      true ->
        dependencies =
          case Map.get(graph, node, []) do
            values when is_list(values) -> Enum.filter(values, &Map.has_key?(graph, &1))
            _other -> []
          end

        active = [node | active]

        Enum.reduce(dependencies, {MapSet.new([node]), false}, fn dependency, {visited, cycle?} ->
          {child_visited, child_cycle?} = visit_graph(dependency, graph, done, active)
          {MapSet.union(visited, child_visited), cycle? or child_cycle?}
        end)
    end
  end

  defp transitive_dependencies(graph) when is_map(graph) do
    Map.new(graph, fn {node, _dependencies} ->
      {node, reachable_dependencies(node, graph, MapSet.new())}
    end)
  end

  defp transitive_dependencies(_graph), do: %{}

  @spec reachable_dependencies(String.t(), map(), MapSet.t(String.t())) ::
          MapSet.t(String.t())
  defp reachable_dependencies(node, graph, seen) do
    case Map.get(graph, node, []) do
      dependencies when is_list(dependencies) ->
        Enum.reduce(dependencies, seen, &reduce_reachable_dependency(&1, &2, graph))

      _other ->
        seen
    end
  end

  @spec reduce_reachable_dependency(term(), MapSet.t(String.t()), map()) ::
          MapSet.t(String.t())
  defp reduce_reachable_dependency(dependency, reached, graph) do
    if is_binary(dependency) and not MapSet.member?(reached, dependency) do
      reached = MapSet.put(reached, dependency)
      MapSet.union(reached, reachable_dependencies(dependency, graph, reached))
    else
      reached
    end
  end

  defp derive_paths(canonical_manifest_path) do
    slices_dir = Path.dirname(canonical_manifest_path)
    bundle_dir = Path.dirname(slices_dir)
    slice_id = Path.basename(canonical_manifest_path, ".json")

    if Path.basename(slices_dir) == "slices" and
         Path.extname(canonical_manifest_path) == ".json" and safe_component?(slice_id) do
      {:ok,
       %{
         bundle_dir: bundle_dir,
         bundle: Path.join(bundle_dir, "bundle.json"),
         slices_dir: slices_dir,
         manifest: canonical_manifest_path,
         slice_id: slice_id
       }}
    else
      unsafe_error("manifest")
    end
  end

  defp read_json_file(path, label) do
    with {:ok, canonical_path} <- canonical_regular_file(path, label),
         {:ok, bytes} <- File.read(canonical_path),
         {:ok, payload} <- Jason.decode(bytes),
         true <- is_map(payload) do
      {:ok, %{source_path: canonical_path, bytes: bytes, sha256: sha256(bytes), payload: payload}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> invalid_file_error(label, :invalid_json)
      false -> invalid_file_error(label, :object)
    end
  end

  defp canonical_regular_file(path, label) do
    expanded = Path.expand(path)

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(expanded),
         {:ok, canonical} <- PathSafety.canonicalize(expanded),
         true <- canonical == expanded do
      {:ok, canonical}
    else
      _other -> unsafe_error(label)
    end
  end

  defp canonical_selected_manifest(path) do
    if Path.type(path) == :absolute and Path.expand(path) == path do
      canonical_regular_file(path, "manifest")
    else
      unsafe_error("manifest")
    end
  end

  defp verify_file_evidence(%{source_path: path, bytes: bytes, sha256: digest}, label)
       when is_binary(path) and is_binary(bytes) and is_binary(digest) do
    with {:ok, canonical} <- canonical_regular_file(path, label),
         {:ok, current_bytes} <- File.read(canonical),
         true <- current_bytes == bytes,
         true <- sha256(current_bytes) == digest do
      :ok
    else
      _other -> changed_error(label)
    end
  end

  defp verify_file_evidence(_evidence, label), do: changed_error(label)

  defp evidence(file) do
    Map.take(file, [:source_path, :bytes, :sha256])
  end

  defp selected_verdict(approval, slice_id) do
    case Map.get(approval, "verdicts") do
      verdicts when is_map(verdicts) -> Map.get(verdicts, slice_id)
      _other -> nil
    end
  end

  defp child_ids(children) when is_list(children) do
    Enum.flat_map(children, fn
      %{"id" => id} when is_binary(id) and byte_size(id) > 0 -> [id]
      _other -> []
    end)
  end

  defp child_ids(_children), do: []

  defp safe_component?(value) when is_binary(value) do
    value not in ["", ".", ".."] and String.trim(value) == value and
      Regex.match?(@safe_component_pattern, value)
  end

  defp safe_component?(_value), do: false

  defp nonempty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_string?(_value), do: false

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp violation(path, rule), do: %{path: path, rule: rule}

  defp validation_error(violations) do
    code =
      if Enum.any?(violations, fn violation ->
           String.starts_with?(violation.path, "bundle.json.status") or
             String.starts_with?(violation.path, "bundle.json.approval")
         end) do
        :unapproved_export
      else
        :invalid_export
      end

    message =
      if code == :unapproved_export,
        do: "The export is not approved.",
        else: "The export is invalid."

    {:error, %Error{code: code, message: message, violations: Enum.uniq(violations)}}
  end

  defp invalid_file_error(label, rule) do
    {:error,
     %Error{
       code: :invalid_export,
       message: "The export is invalid.",
       violations: [violation(label, rule)]
     }}
  end

  defp unsafe_error(label) do
    {:error,
     %Error{
       code: :unsafe_export_path,
       message: "The export path is unsafe.",
       violations: [violation(label, :unsafe_path)]
     }}
  end

  defp changed_error(label) do
    {:error,
     %Error{
       code: :export_changed,
       message: "The export changed during admission.",
       violations: [violation(label, :changed)]
     }}
  end
end
