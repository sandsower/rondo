defmodule Rondo.Core.EventFeed do
  @moduledoc """
  Implements the event half of the provisional `rondo.core/v1` execution contract.

  This routes rondo's internal `rondo.events/v0` run evidence (read through the
  RON-129 `Rondo.RunEvidence.EventStream` seam) plus the durable run-ledger
  manifest into the externally consumable `rondo.core/v1` event families named
  by the contract:

    * `rondo.service.status_changed` - the rondo core service lifecycle,
    * `rondo.run.status_changed` - run lifecycle transitions, and
    * `rondo.run.evidence_recorded` - evidence/artifact pointers.

  The feed is built entirely from durable ledger state under
  `<workspace_root>/.rondo_runs/<identifier>/<run_id>/`, so the same code path
  serves active runs (append-only ledger, tailed by re-reading) and archived
  runs (immutable ledger, replayed deterministically) without relaunching any
  completed work.

  Cursor semantics: events are projected into one deterministically ordered
  sequence numbered `1..N`. `event_cursor` is an opaque token carrying the count
  already consumed; `run.events` returns the events after that offset plus a
  `next_event_cursor`. Because the ledger is append-only, the already-delivered
  prefix is stable, so a consumer tails by re-issuing `run.events` with the last
  `next_event_cursor` and replays an archived run from `initial_cursor/0`.

  Transport is intentionally out of this module: `Rondo.Core.EventFeed` is the
  local BEAM API, and `mix rondo.run_events` is the CLI transport over it. See
  `docs/adr/0001-run-event-feed-transport.md`.

  Standalone rondo is a first-class consumer: nothing here depends on crust.
  """

  alias Rondo.Core.RunLocator
  alias Rondo.RunEvidence.CoreEventIndex

  @surface "rondo.core/v1"
  @cursor_prefix "rondo.core/v1:"
  @cursor_digits ~r/\A[0-9]+\z/

  # Keep Core responses comfortably below the Rust client's 1 MiB body cap.
  # Count and byte bounds are both fixed server policy, not caller input.
  @page_max_events 100
  @page_max_bytes 512 * 1024
  @event_max_bytes 128 * 1024
  @diagnostic_namespace_max_value_bytes 512
  @external_identifier_max_bytes 512
  @external_string_max_bytes 1_024
  @status_max_last_event_bytes 8 * 1024
  @status_max_evidence_pointers 32
  @status_max_evidence_pointer_bytes 2 * 1024

  @service_status_changed "rondo.service.status_changed"
  @run_status_changed "rondo.run.status_changed"
  @run_evidence_recorded "rondo.run.evidence_recorded"

  # Manifest checkpoint kinds that represent an externally visible run status.
  @type request :: map()
  @type contract_event :: map()

  @doc "Returns the contract surface id implemented by this feed."
  @spec surface() :: String.t()
  def surface, do: @surface

  @doc "Returns the `rondo.core/v1` event family types emitted by this feed."
  @spec event_types() :: [String.t()]
  def event_types, do: [@service_status_changed, @run_status_changed, @run_evidence_recorded]

  @doc "Returns the replay-from-start cursor a `run.submit` response would carry."
  @spec initial_cursor() :: String.t()
  def initial_cursor, do: encode_cursor(0)

  @doc "Parses an opaque event cursor without accepting partial or foreign syntax."
  @spec parse_cursor(term()) :: {:ok, non_neg_integer()} | {:error, :invalid_cursor}
  def parse_cursor(nil), do: {:ok, 0}
  def parse_cursor(offset) when is_integer(offset) and offset >= 0, do: {:ok, offset}

  def parse_cursor(@cursor_prefix <> encoded) do
    if byte_size(encoded) <= 20 and Regex.match?(@cursor_digits, encoded) do
      {:ok, String.to_integer(encoded)}
    else
      {:error, :invalid_cursor}
    end
  end

  def parse_cursor(_cursor), do: {:error, :invalid_cursor}

  @doc """
  Implements the contract `run.events` operation.

  Request concepts: `service_id`, `repo_id`, `run_id`, `event_cursor` (string or
  atom keys accepted). Returns a bounded page with `events`,
  `next_event_cursor`, and `has_more`, or `{:error, reason}`.

  Options:

    * `:workspace_root` - workspace root to search (defaults to the configured
      root).
  """
  @spec run_events(request(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_events(request, opts \\ []) do
    with {:ok, ctx} <- context(request),
         {:ok, offset} <- parse_cursor(ctx.event_cursor),
         {:ok, run_dir, manifest} <- load(ctx, opts),
         {:ok, all} <- project(manifest, run_dir, ctx) do
      if offset <= length(all) do
        events = page_events(all, offset, ctx)
        next = offset + length(events)
        has_more = next < length(all)

        {:ok, events_response(ctx, events, encode_cursor(next), has_more)}
      else
        {:error, :invalid_cursor}
      end
    end
  end

  @doc """
  Implements the contract `run.status` observation.

  Returns `{:ok, %{"run_id", "status", "last_event", "evidence_pointers",
  "event_cursor"}}`. `event_cursor` is the replay cursor a fresh consumer uses to
  stream this run from the beginning.
  """
  @spec run_status(request(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_status(request, opts \\ []) do
    with {:ok, ctx} <- context(request),
         {:ok, run_dir, manifest} <- load(ctx, opts),
         {:ok, all} <- project(manifest, run_dir, ctx) do
      response = %{
        "surface" => @surface,
        "repo_id" => ctx.repo_id,
        "run_id" => ctx.run_id,
        "status" => external_status(Map.get(manifest, "status")),
        "last_event" => bounded_event(List.last(all), @status_max_last_event_bytes),
        "evidence_pointers" => bounded_evidence_pointers(all, ctx.run_id),
        "event_cursor" => initial_cursor()
      }

      {:ok, bound_projected_value(response)}
    end
  end

  defp context(request) when is_map(request) do
    service_id = value(request, :service_id) || "rondo-core"
    repo_id = value(request, :repo_id)
    run_id = value(request, :run_id)

    with :ok <- validate_external_identifier(service_id, :service_id),
         :ok <- validate_external_identifier(repo_id, :repo_id),
         :ok <- validate_external_identifier(run_id, :run_id) do
      {:ok,
       %{
         service_id: service_id,
         repo_id: repo_id,
         run_id: run_id,
         event_cursor: value(request, :event_cursor)
       }}
    end
  end

  defp context(_request), do: {:error, :invalid_request}

  defp load(ctx, opts) do
    if Keyword.has_key?(opts, :run_dir) do
      {:error, :external_run_dir_not_allowed}
    else
      locator_opts = Keyword.take(opts, [:workspace_root])

      with {:ok, located} <-
             RunLocator.locate(ctx.repo_id, ctx.run_id, locator_opts) do
        {:ok, located.run_dir, located.manifest}
      end
    end
  end

  defp project(manifest, run_dir, ctx) do
    with {:ok, descriptors} <- CoreEventIndex.project(manifest, run_dir) do
      events =
        descriptors
        |> Enum.with_index(1)
        |> Enum.map(fn {descriptor, sequence} -> render_descriptor(descriptor, ctx, sequence) end)

      {:ok, events}
    end
  end

  defp page_events(all, offset, ctx) do
    total = length(all)

    all
    |> Enum.drop(offset)
    |> Enum.take(@page_max_events)
    |> Enum.reduce_while([], fn event, accepted ->
      event = bounded_event(event, @event_max_bytes)
      candidate = accepted ++ [event]
      next_cursor = encode_cursor(offset + length(candidate))
      has_more = offset + length(candidate) < total
      response = events_response(ctx, candidate, next_cursor, has_more)

      cond do
        encoded_size(response) <= @page_max_bytes -> {:cont, candidate}
        accepted == [] -> {:halt, [replacement_event(event)]}
        true -> {:halt, accepted}
      end
    end)
  end

  defp events_response(ctx, events, next_cursor, has_more) do
    bound_projected_value(%{
      "surface" => @surface,
      "repo_id" => ctx.repo_id,
      "run_id" => ctx.run_id,
      "events" => events,
      "next_event_cursor" => next_cursor,
      "has_more" => has_more
    })
  end

  defp bounded_event(nil, _max_bytes), do: nil

  defp bounded_event(event, max_bytes) when is_map(event) do
    if encoded_size(event) <= max_bytes, do: event, else: replacement_event(event)
  end

  defp replacement_event(event) do
    %{
      "type" => event_value(event, "type"),
      "sequence" => event_value(event, "sequence"),
      "payload_omitted" => true,
      "reason" => "event_exceeds_observation_budget"
    }
    |> maybe_put_namespace(bounded_namespace(event_value(event, "namespace")))
  end

  defp bounded_namespace(namespace) when is_map(namespace) do
    bounded =
      namespace
      |> Map.take(["repo_id", "run_id", "service_id"])
      |> Enum.filter(fn {_key, value} ->
        is_binary(value) and byte_size(value) <= @diagnostic_namespace_max_value_bytes
      end)
      |> Map.new()

    if map_size(bounded) == 0, do: nil, else: bounded
  end

  defp bounded_namespace(_namespace), do: nil

  defp maybe_put_namespace(event, nil), do: event
  defp maybe_put_namespace(event, namespace), do: Map.put(event, "namespace", namespace)

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> @page_max_bytes + 1
    end
  end

  defp render_descriptor(descriptor, ctx, sequence) do
    descriptor
    |> Map.drop(["aliases", "identity"])
    |> render_descriptor_type(ctx)
    |> Map.put("sequence", sequence)
    |> Map.put("namespace", descriptor_namespace(descriptor, ctx))
  end

  defp render_descriptor_type(%{"type" => "service_status"} = descriptor, ctx) do
    descriptor
    |> Map.put("type", @service_status_changed)
    |> Map.put("service_id", ctx.service_id)
  end

  defp render_descriptor_type(%{"type" => "run_status"} = descriptor, ctx) do
    descriptor
    |> Map.put("type", @run_status_changed)
    |> Map.put("repo_id", ctx.repo_id)
    |> Map.put("run_id", ctx.run_id)
  end

  defp render_descriptor_type(%{"type" => "evidence"} = descriptor, ctx) do
    descriptor
    |> Map.put("type", @run_evidence_recorded)
    |> Map.put("repo_id", ctx.repo_id)
    |> Map.put("run_id", ctx.run_id)
  end

  defp descriptor_namespace(%{"type" => "service_status"}, ctx),
    do: %{"service_id" => ctx.service_id}

  defp descriptor_namespace(_descriptor, ctx),
    do: %{"repo_id" => ctx.repo_id, "run_id" => ctx.run_id}

  defp bounded_evidence_pointers(events, run_id) do
    events
    |> Enum.filter(&(Map.get(&1, "type") == @run_evidence_recorded))
    |> Enum.map(&%{"artifact_kind" => Map.get(&1, "artifact_kind"), "uri" => Map.get(&1, "uri")})
    |> Enum.take(@status_max_evidence_pointers)
    |> Enum.map(&bounded_evidence_pointer(&1, run_id))
  end

  defp bounded_evidence_pointer(pointer, run_id) do
    if encoded_size(pointer) <= @status_max_evidence_pointer_bytes do
      pointer
    else
      %{
        "artifact_kind" => "payload_omitted",
        "uri" => opaque_evidence_uri(run_id, Jason.encode!(pointer))
      }
    end
  end

  defp opaque_evidence_uri(run_id, source) do
    digest = :sha256 |> :crypto.hash(source) |> Base.encode16(case: :lower)
    "rondo-run://#{evidence_run_component(run_id)}/opaque/#{digest}"
  end

  defp evidence_run_component(run_id) do
    encoded = encode_uri_component(run_id)

    if byte_size(encoded) <= @external_identifier_max_bytes do
      encoded
    else
      "opaque-" <> sha256(run_id)
    end
  end

  defp encode_uri_component(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp encode_cursor(offset) when is_integer(offset) and offset >= 0, do: @cursor_prefix <> Integer.to_string(offset)

  defp value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil

  defp event_value(event, key) when is_map(event), do: Map.get(event, key)
  defp event_value(_event, _key), do: nil

  defp validate_external_identifier(nil, field),
    do: {:error, missing_identifier_error(field)}

  defp validate_external_identifier(value, field) when is_binary(value) do
    if String.valid?(value) and value != "" and value == String.trim(value) and
         byte_size(value) <= @external_identifier_max_bytes and
         not Regex.match?(~r/[[:cntrl:]]/u, value) do
      :ok
    else
      {:error, invalid_identifier_error(field)}
    end
  end

  defp validate_external_identifier(_value, field),
    do: {:error, invalid_identifier_error(field)}

  defp missing_identifier_error(:service_id), do: :missing_service_id
  defp missing_identifier_error(:repo_id), do: :missing_repo_id
  defp missing_identifier_error(:run_id), do: :missing_run_id
  defp invalid_identifier_error(:service_id), do: :invalid_service_id
  defp invalid_identifier_error(:repo_id), do: :invalid_repo_id
  defp invalid_identifier_error(:run_id), do: :invalid_run_id

  defp external_status(status)
       when status in ~w(running paused completed failed terminated handed_off aborted),
       do: status

  defp external_status(_status), do: "unknown"

  defp bound_projected_value(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @external_string_max_bytes,
      do: value,
      else: "rondo-omitted:sha256:" <> sha256(value)
  end

  defp bound_projected_value(value) when is_list(value),
    do: Enum.map(value, &bound_projected_value/1)

  defp bound_projected_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, bound_projected_value(item)} end)

  defp bound_projected_value(value), do: value

  defp sha256(value),
    do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
