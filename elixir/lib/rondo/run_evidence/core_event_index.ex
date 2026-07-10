defmodule Rondo.RunEvidence.CoreEventIndex do
  @moduledoc """
  Owns the append-only projection index for the public `rondo.core/v1` feed.

  Legacy ledgers are projected with the historical timestamp-and-tier ordering
  exactly once, under the run lock, and that visible prefix is frozen as compact
  source-neutral descriptors in the manifest. Later source records only append
  unseen descriptors. The index therefore preserves cursor positions even when
  an evidence reference moves from the event stream into the manifest catalog.
  """

  alias Rondo.RunEvidence.ArtifactCatalog
  alias Rondo.RunEvidence.EventStream

  @manifest_key "core_event_feed_v1"
  @version 1
  @terminal_statuses ~w(completed failed terminated)
  @status_checkpoint_kinds %{
    "interrupt_created" => "paused",
    "completed" => "completed",
    "failed" => "failed",
    "terminated" => "terminated"
  }
  @timestamp_max_bytes 128
  @external_identifier_max_bytes 512
  @external_string_max_bytes 1_024
  @descriptor_string_max_bytes 1_048_576
  @run_statuses ~w(running paused completed failed terminated)
  @descriptor_common_fields ~w(identity type)
  @descriptor_fields %{
    "service_status" => ~w(identity aliases type status timestamp),
    "run_status" => ~w(identity aliases type status timestamp),
    "evidence" => ~w(identity aliases type artifact_kind uri timestamp)
  }

  @type descriptor :: map()
  @type corruption_reason :: term()
  @type result(value) :: {:ok, value} | {:error, {:core_event_index_corrupt, corruption_reason()}}

  @doc "Returns a manifest with a valid index, freezing the legacy projection when needed."
  @spec ensure(map(), Path.t()) :: result(map())
  def ensure(manifest, run_dir) when is_map(manifest) and is_binary(run_dir) do
    case Map.fetch(manifest, @manifest_key) do
      :error -> build_legacy_index(manifest, run_dir)
      {:ok, _present} -> refresh(manifest, run_dir)
    end
  end

  @doc "Initializes a new run manifest with the same projection index used by upgraded runs."
  @spec initialize(map(), Path.t()) :: result(map())
  def initialize(manifest, run_dir), do: ensure(manifest, run_dir)

  @doc "Appends source records not yet represented by the durable projection index."
  @spec refresh(map(), Path.t()) :: result(map())
  def refresh(manifest, run_dir) when is_map(manifest) and is_binary(run_dir) do
    case Map.fetch(manifest, @manifest_key) do
      :error ->
        build_legacy_index(manifest, run_dir)

      {:ok, existing} ->
        with :ok <- validate_index(existing, manifest),
             indexed <- Map.fetch!(existing, "events"),
             appended <- append_unseen(indexed, legacy_projection(manifest, run_dir)),
             :ok <- validate_descriptors(appended) do
          {:ok, Map.put(manifest, @manifest_key, %{existing | "events" => appended})}
        else
          {:error, reason} -> corruption(reason)
        end
    end
  end

  @doc "Returns the durable prefix plus a deterministic unindexed recovery tail."
  @spec project(map(), Path.t()) :: result([descriptor()])
  def project(manifest, run_dir) when is_map(manifest) and is_binary(run_dir) do
    case Map.fetch(manifest, @manifest_key) do
      :error ->
        projection = legacy_projection(manifest, run_dir)

        case validate_descriptors(projection) do
          :ok -> {:ok, projection}
          {:error, reason} -> corruption(reason)
        end

      {:ok, existing} ->
        with :ok <- validate_index(existing, manifest),
             indexed <- Map.fetch!(existing, "events"),
             projection <- append_unseen(indexed, legacy_projection(manifest, run_dir)),
             :ok <- validate_descriptors(projection) do
          {:ok, projection}
        else
          {:error, reason} -> corruption(reason)
        end
    end
  end

  @doc "Builds the stable evidence identity and wire URI for a run-relative source path."
  @spec evidence_uri(String.t(), term()) :: String.t() | nil
  def evidence_uri(_run_id, nil), do: nil

  def evidence_uri(run_id, path) when is_binary(run_id) and is_binary(path) do
    if safe_run_relative_path?(path) do
      encoded_path = path |> Path.split() |> Enum.map_join("/", &encode_uri_component/1)
      uri = "rondo-run://#{evidence_run_component(run_id)}/#{encoded_path}"

      if byte_size(uri) <= @external_string_max_bytes,
        do: uri,
        else: opaque_evidence_uri(run_id, path)
    else
      opaque_evidence_uri(run_id, path)
    end
  end

  def evidence_uri(_run_id, _path), do: nil

  defp index(events, manifest),
    do: %{"version" => @version, "run_id" => Map.get(manifest, "run_id"), "events" => events}

  defp build_legacy_index(manifest, run_dir) do
    events = legacy_projection(manifest, run_dir)
    value = index(events, manifest)

    case validate_index(value, manifest) do
      :ok -> {:ok, Map.put(manifest, @manifest_key, value)}
      {:error, reason} -> corruption(reason)
    end
  end

  defp validate_index(index, manifest) when is_map(index) do
    with :ok <- validate_index_fields(index),
         :ok <- validate_version(Map.get(index, "version")),
         :ok <- validate_run_id(Map.get(index, "run_id"), Map.get(manifest, "run_id")),
         events when is_list(events) <- Map.get(index, "events"),
         :ok <- validate_descriptors(events) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      events when not is_list(events) -> {:error, :invalid_events}
    end
  end

  defp validate_index(_index, _manifest), do: {:error, :invalid_shape}

  defp validate_index_fields(index) do
    if Map.keys(index) |> Enum.sort() == ["events", "run_id", "version"] do
      :ok
    else
      {:error, :invalid_index_fields}
    end
  end

  defp validate_version(@version), do: :ok
  defp validate_version(version) when is_integer(version), do: {:error, {:unsupported_version, version}}
  defp validate_version(_version), do: {:error, :invalid_version}

  defp validate_run_id(run_id, run_id) when is_binary(run_id), do: :ok

  defp validate_run_id(index_run_id, manifest_run_id)
       when is_binary(index_run_id) and is_binary(manifest_run_id),
       do: {:error, {:run_id_mismatch, manifest_run_id, index_run_id}}

  defp validate_run_id(_index_run_id, _manifest_run_id), do: {:error, :invalid_run_id}

  defp validate_descriptors(events) when is_list(events) do
    events
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {descriptor, index}, {:ok, seen} ->
      with :ok <- validate_descriptor(descriptor),
           identities <- descriptor_identities(descriptor),
           :ok <- validate_unique_identities(identities, seen) do
        {:cont, {:ok, Enum.reduce(identities, seen, &MapSet.put(&2, &1))}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_descriptor, index, reason}}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_descriptor(descriptor) when is_map(descriptor) do
    type = Map.get(descriptor, "type")

    with :ok <- validate_descriptor_keys(descriptor, type),
         :ok <- validate_identity(Map.get(descriptor, "identity")),
         :ok <- validate_aliases(Map.get(descriptor, "aliases", []), descriptor) do
      validate_descriptor_type(type, descriptor)
    end
  end

  defp validate_descriptor(_descriptor), do: {:error, :invalid_shape}

  defp validate_descriptor_keys(descriptor, type) do
    with true <- Enum.all?(Map.keys(descriptor), &is_binary/1),
         {:ok, allowed} <- Map.fetch(@descriptor_fields, type),
         [] <- @descriptor_common_fields -- Map.keys(descriptor),
         [] <- required_type_fields(type) -- Map.keys(descriptor),
         [] <- Map.keys(descriptor) -- allowed do
      :ok
    else
      false -> {:error, :non_string_field}
      :error -> {:error, {:unsupported_type, type}}
      missing when is_list(missing) -> {:error, {:invalid_fields, Enum.sort(missing)}}
    end
  end

  defp required_type_fields("service_status"), do: ~w(status timestamp)
  defp required_type_fields("run_status"), do: ~w(status timestamp)
  defp required_type_fields("evidence"), do: ~w(artifact_kind uri timestamp)

  defp validate_descriptor_type("service_status", descriptor) do
    with "service:started" <- Map.get(descriptor, "identity"),
         "running" <- Map.get(descriptor, "status"),
         :ok <- validate_timestamp(Map.get(descriptor, "timestamp")) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_service_status}
    end
  end

  defp validate_descriptor_type("run_status", descriptor) do
    status = Map.get(descriptor, "status")
    identity = Map.get(descriptor, "identity")

    with true <- status in @run_statuses,
         true <- valid_run_status_identity?(identity, status),
         :ok <- validate_timestamp(Map.get(descriptor, "timestamp")) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_run_status}
    end
  end

  defp validate_descriptor_type("evidence", descriptor) do
    uri = Map.get(descriptor, "uri")

    with :ok <- validate_string(Map.get(descriptor, "artifact_kind"), @descriptor_string_max_bytes),
         :ok <- validate_evidence_uri(uri),
         true <- Map.get(descriptor, "identity") == "evidence:" <> uri,
         :ok <- validate_timestamp(Map.get(descriptor, "timestamp")) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_evidence}
    end
  end

  defp validate_descriptor_type(type, _descriptor), do: {:error, {:unsupported_type, type}}

  defp validate_identity(identity), do: validate_string(identity, @descriptor_string_max_bytes)

  defp validate_aliases(aliases, descriptor) when is_list(aliases) do
    expected_aliases = expected_aliases(descriptor)

    cond do
      not Enum.all?(aliases, &(validate_identity(&1) == :ok)) -> {:error, :invalid_aliases}
      aliases != Enum.uniq(aliases) -> {:error, :duplicate_aliases}
      aliases != expected_aliases -> {:error, :invalid_aliases}
      true -> :ok
    end
  end

  defp validate_aliases(_aliases, _descriptor), do: {:error, :invalid_aliases}

  defp expected_aliases(%{
         "type" => "run_status",
         "status" => status,
         "identity" => "checkpoint:" <> _digest
       })
       when status in @terminal_statuses,
       do: [terminal_identity(status)]

  defp expected_aliases(_descriptor), do: []

  defp validate_unique_identities(identities, seen) do
    cond do
      identities != Enum.uniq(identities) -> {:error, :duplicate_identity}
      Enum.any?(identities, &MapSet.member?(seen, &1)) -> {:error, :duplicate_identity}
      true -> :ok
    end
  end

  defp valid_run_status_identity?("run:started", "running"), do: true

  defp valid_run_status_identity?("checkpoint:" <> digest, status)
       when status in ~w(paused completed failed terminated),
       do: byte_size(digest) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp valid_run_status_identity?("run:terminal:" <> status, status)
       when status in @terminal_statuses,
       do: true

  defp valid_run_status_identity?(_identity, _status), do: false

  defp validate_evidence_uri(uri) do
    with :ok <- validate_string(uri, @external_string_max_bytes),
         true <- String.starts_with?(uri, "rondo-run://") do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_evidence_uri}
    end
  end

  defp validate_timestamp(timestamp) do
    if safe_timestamp(timestamp) == timestamp,
      do: :ok,
      else: {:error, :invalid_timestamp}
  end

  defp validate_string(value, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes do
    if String.valid?(value) and not Regex.match?(~r/[[:cntrl:]]/u, value),
      do: :ok,
      else: {:error, :invalid_string}
  end

  defp validate_string(_value, _max_bytes), do: {:error, :invalid_string}

  defp corruption(reason), do: {:error, {:core_event_index_corrupt, reason}}

  defp legacy_projection(manifest, run_dir) do
    manifest
    |> projection_candidates(run_dir)
    |> Enum.sort_by(&legacy_order_key/1)
    |> Enum.map(&strip_sort_metadata/1)
  end

  defp projection_candidates(manifest, run_dir) do
    checkpoints = checkpoints(manifest, run_dir)

    service_candidates(manifest) ++
      run_candidates(manifest, checkpoints) ++ evidence_candidates(manifest, run_dir)
  end

  defp service_candidates(manifest) do
    case started_at(manifest) do
      nil ->
        []

      timestamp ->
        [
          staged(
            %{
              "identity" => "service:started",
              "type" => "service_status",
              "status" => "running",
              "timestamp" => timestamp
            },
            0,
            0,
            timestamp
          )
        ]
    end
  end

  defp run_candidates(manifest, checkpoints) do
    started = started_at(manifest)

    initial =
      if started do
        [
          staged(
            %{
              "identity" => "run:started",
              "type" => "run_status",
              "status" => "running",
              "timestamp" => started
            },
            1,
            0,
            started
          )
        ]
      else
        []
      end

    transitions =
      Enum.flat_map(checkpoints, fn checkpoint ->
        case Map.get(@status_checkpoint_kinds, Map.get(checkpoint, "kind")) do
          nil ->
            []

          status ->
            [
              staged(
                %{
                  "identity" => checkpoint_identity(checkpoint),
                  "aliases" => terminal_aliases(status),
                  "type" => "run_status",
                  "status" => status,
                  "timestamp" => checkpoint_timestamp(checkpoint, manifest)
                },
                1,
                checkpoint_seq(checkpoint),
                checkpoint_timestamp(checkpoint, manifest)
              )
            ]
        end
      end)

    initial ++ transitions ++ synthetic_terminal(manifest, transitions)
  end

  defp synthetic_terminal(manifest, transitions) do
    status = Map.get(manifest, "status")

    cond do
      status not in @terminal_statuses ->
        []

      Enum.any?(transitions, &(Map.get(&1, "status") == status)) ->
        []

      true ->
        timestamp = finished_at(manifest) || started_at(manifest)

        [
          staged(
            %{
              "identity" => terminal_identity(status),
              "type" => "run_status",
              "status" => status,
              "timestamp" => timestamp
            },
            1,
            1_000_000,
            timestamp
          )
        ]
    end
  end

  defp evidence_candidates(manifest, run_dir) do
    manifest_refs = manifest |> Map.get("artifacts", []) |> normalize_refs(manifest)
    stream_refs = run_dir |> EventStream.read() |> EventStream.artifact_linked_events() |> stream_refs()
    default_timestamp = started_at(manifest)
    run_id = Map.get(manifest, "run_id")

    (manifest_refs ++ stream_refs)
    |> Enum.reduce({[], MapSet.new(), 0}, fn {ref, timestamp}, {acc, seen, index} ->
      uri = evidence_uri(run_id, Map.get(ref, "path"))

      if is_nil(uri) or MapSet.member?(seen, uri) do
        {acc, seen, index}
      else
        timestamp = timestamp || default_timestamp

        descriptor =
          staged(
            %{
              "identity" => "evidence:" <> uri,
              "type" => "evidence",
              "artifact_kind" => Map.get(ref, "kind"),
              "uri" => uri,
              "timestamp" => timestamp
            },
            2,
            index,
            timestamp
          )

        {[descriptor | acc], MapSet.put(seen, uri), index + 1}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp normalize_refs(artifacts, manifest) when is_list(artifacts) do
    started = started_at(manifest)

    artifacts
    |> Enum.filter(&(is_map(&1) and ArtifactCatalog.valid?(&1)))
    |> Enum.map(&{stringify_ref(&1), immutable_recorded_at(&1, started)})
  end

  defp normalize_refs(_artifacts, _manifest), do: []

  defp stream_refs(events) do
    Enum.flat_map(events, fn event ->
      timestamp = Map.get(event, "timestamp")
      event |> EventStream.artifact_refs() |> Enum.map(&{stringify_ref(&1), timestamp})
    end)
  end

  defp stringify_ref(ref) do
    %{
      "kind" => Map.get(ref, "kind") || Map.get(ref, :kind),
      "path" => Map.get(ref, "path") || Map.get(ref, :path)
    }
  end

  defp checkpoints(manifest, run_dir) do
    indexed =
      case Map.get(manifest, "checkpoints") do
        checkpoints when is_list(checkpoints) -> checkpoints
        _other -> []
      end

    indexed_paths = MapSet.new(indexed, &Map.get(&1, "path"))

    recovered =
      run_dir
      |> Path.join("checkpoints/*.json")
      |> Path.wildcard()
      |> Enum.map(&checkpoint_from_file(run_dir, &1))
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(indexed_paths, Map.get(&1, "path"))))
      |> Enum.sort_by(&{checkpoint_seq(&1), Map.get(&1, "path", "")})

    indexed ++ recovered
  end

  defp checkpoint_from_file(run_dir, path) do
    with {:ok, contents} <- File.read(path),
         {:ok, checkpoint} when is_map(checkpoint) <- Jason.decode(contents),
         seq when is_integer(seq) <- Map.get(checkpoint, "seq"),
         kind when is_binary(kind) <- Map.get(checkpoint, "kind"),
         timestamp when is_binary(timestamp) <- Map.get(checkpoint, "timestamp") do
      %{
        "seq" => seq,
        "kind" => kind,
        "path" => Path.relative_to(path, run_dir),
        "timestamp" => timestamp
      }
    else
      _invalid -> nil
    end
  end

  defp append_unseen(indexed, candidates) do
    seen = Enum.reduce(indexed, MapSet.new(), &put_descriptor_identities(&2, &1))

    {_seen, appended} =
      Enum.reduce(candidates, {seen, indexed}, fn descriptor, {known, acc} ->
        if descriptor_seen?(known, descriptor) do
          {known, acc}
        else
          {put_descriptor_identities(known, descriptor), acc ++ [descriptor]}
        end
      end)

    appended
  end

  defp descriptor_seen?(seen, descriptor) do
    descriptor
    |> descriptor_identities()
    |> Enum.any?(&MapSet.member?(seen, &1))
  end

  defp put_descriptor_identities(seen, descriptor) do
    Enum.reduce(descriptor_identities(descriptor), seen, &MapSet.put(&2, &1))
  end

  defp descriptor_identities(descriptor) do
    [Map.get(descriptor, "identity") | List.wrap(Map.get(descriptor, "aliases"))]
    |> Enum.filter(&is_binary/1)
  end

  defp checkpoint_identity(checkpoint) do
    source = Map.get(checkpoint, "path") || "seq:#{checkpoint_seq(checkpoint)}"
    "checkpoint:" <> sha256(source)
  end

  defp terminal_aliases(status) when status in @terminal_statuses,
    do: [terminal_identity(status)]

  defp terminal_aliases(_status), do: []

  defp terminal_identity(status), do: "run:terminal:" <> status

  defp staged(descriptor, tier, sub, timestamp) do
    descriptor
    |> Map.put(:_tier, tier)
    |> Map.put(:_sub, sub)
    |> Map.put(:_timestamp, timestamp)
  end

  defp legacy_order_key(descriptor) do
    {
      sortable_timestamp(Map.get(descriptor, :_timestamp)),
      Map.get(descriptor, :_tier, 9),
      Map.get(descriptor, :_sub, 0)
    }
  end

  defp strip_sort_metadata(descriptor),
    do: Map.drop(descriptor, [:_tier, :_sub, :_timestamp])

  defp immutable_recorded_at(ref, fallback),
    do: safe_timestamp(Map.get(ref, "recorded_at")) || fallback

  defp started_at(manifest),
    do:
      safe_timestamp(get_in(manifest, ["timestamps", "started_at"])) ||
        safe_timestamp(get_in(manifest, ["timestamps", "created_at"]))

  defp finished_at(manifest),
    do: safe_timestamp(get_in(manifest, ["timestamps", "finished_at"]))

  defp updated_at(manifest),
    do: safe_timestamp(get_in(manifest, ["timestamps", "updated_at"]))

  defp checkpoint_timestamp(checkpoint, manifest),
    do: safe_timestamp(Map.get(checkpoint, "timestamp")) || updated_at(manifest)

  defp checkpoint_seq(checkpoint) do
    case Map.get(checkpoint, "seq") do
      seq when is_integer(seq) -> seq
      _other -> 0
    end
  end

  defp safe_timestamp(value)
       when is_binary(value) and byte_size(value) <= @timestamp_max_bytes do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> value
      _invalid -> nil
    end
  end

  defp safe_timestamp(_value), do: nil

  defp sortable_timestamp(nil), do: 0

  defp sortable_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _invalid -> 0
    end
  end

  defp sortable_timestamp(_timestamp), do: 0

  defp safe_run_relative_path?(path) do
    segments = Path.split(path)

    path != "" and Path.type(path) == :relative and URI.parse(path).scheme == nil and
      not String.contains?(path, "\\") and not Regex.match?(~r/[[:cntrl:]]/u, path) and
      segments != [] and Enum.all?(segments, &(&1 not in [".", ".."]))
  end

  defp opaque_evidence_uri(run_id, source) do
    digest = sha256(source)
    "rondo-run://#{evidence_run_component(run_id)}/opaque/#{digest}"
  end

  defp evidence_run_component(run_id) do
    encoded = encode_uri_component(run_id)

    if byte_size(encoded) <= @external_identifier_max_bytes,
      do: encoded,
      else: "opaque-" <> sha256(run_id)
  end

  defp encode_uri_component(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
