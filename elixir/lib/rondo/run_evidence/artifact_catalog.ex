defmodule Rondo.RunEvidence.ArtifactCatalog do
  @moduledoc """
  Catalogs run-ledger artifact references behind a small lookup and normalization seam.

  The run ledger remains the source of truth for persisted manifest artifacts.
  This module owns the repeated artifact-ref details that consumers otherwise
  duplicate: valid ref shape, kind/path lookup, present/missing status checks,
  exportability flags, and identity-based upserts.
  """

  @type artifact_ref :: map()
  @type artifact_source :: [artifact_ref()] | map()

  @doc "Returns true when a value has the minimum artifact ref shape."
  @spec valid?(term()) :: boolean()
  def valid?(%{"kind" => kind, "path" => path}) when is_binary(kind) and is_binary(path), do: true
  def valid?(%{kind: kind, path: path}) when is_binary(kind) and is_binary(path), do: true
  def valid?(_artifact), do: false

  @doc "Normalizes an artifact ref and fills in status when absent."
  @spec normalize(artifact_ref(), Path.t()) :: artifact_ref()
  def normalize(%{} = artifact, run_dir) do
    artifact = stringify_keys(artifact)
    status = Map.get(artifact, "status") || status(artifact, run_dir)
    Map.put(artifact, "status", status)
  end

  @doc "Returns an artifact ref status from its path relative to a run dir."
  @spec status(artifact_ref(), Path.t()) :: String.t()
  def status(%{"path" => path}, run_dir) when is_binary(path) do
    full_path = if Path.type(path) == :relative, do: Path.join(run_dir, path), else: path

    if File.exists?(full_path), do: "present", else: "missing"
  end

  def status(_artifact, _run_dir), do: "missing"

  @doc "Finds the first artifact ref with the given kind."
  @spec find(artifact_source(), atom() | String.t()) :: artifact_ref() | nil
  def find(source, kind), do: source |> find_all(kind) |> List.first()

  @doc "Finds all artifact refs with the given kind."
  @spec find_all(artifact_source(), atom() | String.t()) :: [artifact_ref()]
  def find_all(source, kind) do
    kind = kind_to_string(kind)
    Enum.filter(refs(source), &(Map.get(&1, "kind") == kind || Map.get(&1, :kind) == kind))
  end

  @doc "Returns the path for the first artifact ref with the given kind."
  @spec path(artifact_source(), atom() | String.t()) :: Path.t() | nil
  def path(source, kind) do
    case find(source, kind) do
      %{"path" => path} when is_binary(path) -> path
      %{path: path} when is_binary(path) -> path
      _other -> nil
    end
  end

  @doc "Returns whether an artifact ref is allowed to be exported."
  @spec exportable?(term()) :: boolean()
  def exportable?(%{"exportable" => false}), do: false
  def exportable?(%{exportable: false}), do: false
  def exportable?(_artifact), do: true

  @doc "Upserts an artifact by `{kind, path}` identity."
  @spec upsert(term(), artifact_ref()) :: [artifact_ref()]
  def upsert(artifacts, artifact) when is_list(artifacts) and is_map(artifact) do
    case artifact_identity(artifact) do
      nil ->
        artifacts

      identity ->
        upsert_by_identity(artifacts, artifact, identity)
    end
  end

  def upsert(_artifacts, artifact) when is_map(artifact), do: [artifact]
  def upsert(artifacts, _artifact) when is_list(artifacts), do: artifacts
  def upsert(_artifacts, _artifact), do: []

  defp refs(artifacts) when is_list(artifacts), do: artifacts
  defp refs(%{"artifacts" => artifacts}) when is_list(artifacts), do: artifacts
  defp refs(%{artifacts: artifacts}) when is_list(artifacts), do: artifacts
  defp refs(_source), do: []

  defp upsert_by_identity(artifacts, artifact, identity) do
    {artifacts, inserted?} =
      Enum.reduce(artifacts, {[], false}, fn existing, {kept, inserted?} ->
        upsert_step(existing, artifact, identity, kept, inserted?)
      end)

    if inserted?, do: artifacts, else: artifacts ++ [artifact]
  end

  defp upsert_step(existing, artifact, identity, kept, false) do
    if artifact_identity(existing) == identity, do: {kept ++ [artifact], true}, else: {kept ++ [existing], false}
  end

  defp upsert_step(existing, _artifact, identity, kept, true) do
    if artifact_identity(existing) == identity, do: {kept, true}, else: {kept ++ [existing], true}
  end

  defp artifact_identity(artifact) when is_map(artifact) do
    kind = Map.get(artifact, "kind") || Map.get(artifact, :kind)
    path = Map.get(artifact, "path") || Map.get(artifact, :path)

    if is_binary(kind) and is_binary(path), do: {kind, path}, else: nil
  end

  defp artifact_identity(_artifact), do: nil

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp kind_to_string(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_to_string(kind), do: to_string(kind)
end
