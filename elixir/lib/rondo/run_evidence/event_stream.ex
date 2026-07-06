defmodule Rondo.RunEvidence.EventStream do
  @moduledoc """
  Owns normalized run-event append, read, and projection behavior behind one seam.

  Before this seam, the run ledger, timeline, dashboard event inspector, and
  delivery summaries each understood the event-log file path and the raw event
  shape on their own. This module makes the `rondo.events/v0` NDJSON event log a
  single evidence surface:

    * the canonical schema id and run-dir-relative path,
    * normalization of an in-memory event into the `rondo.events/v0` record,
    * append of a normalized record as one NDJSON line,
    * tolerant read of an event log (missing file and malformed lines degrade to
      an empty stream rather than raising), and
    * projections consumers repeat today: cumulative usage snapshots/deltas and
      artifact-linked events.

  Event artifact links share the RON-128 evidence vocabulary: an artifact ref is
  the `{"kind", "path"}` shape validated by `Rondo.RunEvidence.ArtifactCatalog`.

  Sanitization/redaction stays with the writer (the run ledger) and is injected
  through `:sanitize`/`:sanitize_raw` so the persisted bytes are byte-for-byte
  identical to the previous inline implementation.
  """

  alias Rondo.RunEvidence.ArtifactCatalog

  @schema "rondo.events/v0"
  @relative_path "artifacts/agent-events.ndjson"
  @usage_keys ~w(input_tokens output_tokens total_tokens cache_creation_input_tokens cache_read_input_tokens)

  @type event :: map()

  @doc "Returns the normalized run-event NDJSON schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Returns the run-dir-relative path of the event log."
  @spec relative_path() :: String.t()
  def relative_path, do: @relative_path

  @doc """
  Returns the absolute event-log path for a run.

  Accepts a run dir (the event log is resolved under it) or an explicit path that
  already ends in `.ndjson`. Returns `nil` for anything else.
  """
  @spec path(term()) :: Path.t() | nil
  def path(source) when is_binary(source) do
    if String.ends_with?(source, ".ndjson"), do: source, else: Path.join(source, @relative_path)
  end

  def path(_source), do: nil

  @doc """
  Normalizes an in-memory event into the `rondo.events/v0` record.

  Options:

    * `:timestamp` - the ISO-8601 timestamp to stamp on the record.
    * `:sanitize` - a 1-arity sanitizer applied to scalar/structured fields.
    * `:sanitize_raw` - a 1-arity sanitizer applied to the `raw` sub-tree.

  The sanitizers default to identity so the seam can be exercised without the
  ledger's redaction wiring; the ledger passes its own sanitizers so the
  persisted shape is unchanged.
  """
  @spec normalize_event(event(), keyword()) :: map()
  def normalize_event(event, opts \\ []) when is_map(event) do
    sanitize = Keyword.get(opts, :sanitize, &identity/1)
    sanitize_raw = Keyword.get(opts, :sanitize_raw, &identity/1)
    timestamp = Keyword.get(opts, :timestamp)
    accounted_usage = fetch(event, :accounted_usage)

    %{
      "schema" => @schema,
      "timestamp" => timestamp,
      "event" => event |> fetch(:event) |> event_kind(),
      "adapter" => sanitize.(fetch(event, :adapter)),
      "run_ref" => sanitize.(fetch(event, :run_ref)),
      "session_id" => sanitize.(fetch(event, :session_id)),
      "usage" => sanitize.(fetch(event, :usage)),
      "raw" => event |> fetch_raw() |> sanitize_raw.()
    }
    |> maybe_put_accounted_usage(sanitize, accounted_usage)
  end

  @doc """
  Appends a normalized record to an event log as one NDJSON line.

  `target` may be a run dir or an explicit `.ndjson` path. Missing parent
  directories are created.
  """
  @spec append(term(), map()) :: :ok | {:error, term()}
  def append(target, payload) when is_map(payload) do
    case path(target) do
      nil ->
        {:error, :invalid_event_log_path}

      file ->
        with :ok <- File.mkdir_p(Path.dirname(file)),
             {:ok, json} <- Jason.encode(payload) do
          File.write(file, json <> "\n", [:append])
        end
    end
  end

  @doc """
  Reads an event log into a list of normalized event maps.

  A missing log and malformed NDJSON lines degrade to an empty/partial stream
  instead of raising. `source` may be a run dir or an explicit `.ndjson` path.
  """
  @spec read(term()) :: [event()]
  def read(source) do
    case path(source) do
      nil ->
        []

      file ->
        case File.read(file) do
          {:ok, contents} -> decode_lines(contents)
          {:error, _reason} -> []
        end
    end
  end

  @doc "Returns the cumulative usage snapshot recorded on a single event."
  @spec usage_snapshot(term()) :: map()
  def usage_snapshot(event) do
    accounted = fetch(event, :accounted_usage)
    usage = fetch(event, :usage)

    cond do
      is_map(accounted) -> normalize_usage(accounted)
      is_map(usage) -> normalize_usage(usage)
      true -> %{}
    end
  end

  @doc "Returns the cumulative usage snapshot for each event in order."
  @spec usage_snapshots([event()]) :: [map()]
  def usage_snapshots(events) when is_list(events), do: Enum.map(events, &usage_snapshot/1)

  @doc """
  Projects per-event token deltas from repeated cumulative usage snapshots.

  Usage snapshots are cumulative, so consumers that show per-turn spend must
  diff consecutive snapshots. A repeated identical snapshot yields a zero delta,
  and a snapshot that omits a key carries the last known cumulative value
  forward so a partial snapshot never reads as a negative delta.
  """
  @spec cumulative_usage_deltas([event()]) :: [map()]
  def cumulative_usage_deltas(events) when is_list(events) do
    {deltas, _prev} =
      Enum.reduce(events, {[], %{}}, fn event, {acc, prev} ->
        snapshot = usage_snapshot(event)
        merged = Map.merge(prev, snapshot)
        delta = Map.new(merged, fn {key, value} -> {key, max(value - Map.get(prev, key, 0), 0)} end)
        {[delta | acc], merged}
      end)

    Enum.reverse(deltas)
  end

  @doc """
  Returns the artifact refs linked from a single event.

  Refs are read from the event's `artifacts` field and from `raw.artifacts`, then
  filtered through the shared RON-128 artifact vocabulary so only valid
  `{kind, path}` refs are surfaced.
  """
  @spec artifact_refs(term()) :: [map()]
  def artifact_refs(event) do
    (as_list(fetch(event, :artifacts)) ++ as_list(fetch(fetch_raw(event), :artifacts)))
    |> Enum.filter(&ArtifactCatalog.valid?/1)
  end

  @doc "Returns the events that carry at least one valid artifact ref."
  @spec artifact_linked_events([event()]) :: [event()]
  def artifact_linked_events(events) when is_list(events) do
    Enum.filter(events, &(artifact_refs(&1) != []))
  end

  defp decode_lines(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.map(&decode_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) -> event
      _other -> nil
    end
  end

  defp normalize_usage(usage) do
    usage
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      string_key = to_string(key)

      if string_key in @usage_keys and is_integer(value) do
        Map.put(acc, string_key, value)
      else
        acc
      end
    end)
  end

  defp maybe_put_accounted_usage(payload, _sanitize, nil), do: payload

  defp maybe_put_accounted_usage(payload, sanitize, accounted_usage) do
    Map.put(payload, "accounted_usage", sanitize.(accounted_usage))
  end

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp fetch(_map, _key), do: nil

  defp fetch_raw(event) when is_map(event), do: Map.get(event, :raw, Map.get(event, "raw", %{}))
  defp fetch_raw(_event), do: %{}

  defp as_list(value) when is_list(value), do: value
  defp as_list(_value), do: []

  defp event_kind(nil), do: "unknown"
  defp event_kind(value) when is_atom(value), do: Atom.to_string(value)
  defp event_kind(value) when is_binary(value), do: value
  defp event_kind(value), do: inspect(value)

  defp identity(value), do: value
end
