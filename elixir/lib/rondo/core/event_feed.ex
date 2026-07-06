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

  alias Rondo.{Config, RunLedger}
  alias Rondo.RunEvidence.EventStream

  @surface "rondo.core/v1"
  @cursor_prefix "rondo.core/v1:"

  @service_status_changed "rondo.service.status_changed"
  @run_status_changed "rondo.run.status_changed"
  @run_evidence_recorded "rondo.run.evidence_recorded"

  # Manifest checkpoint kinds that represent an externally visible run status.
  @status_checkpoint_kinds %{
    "interrupt_created" => "paused",
    "completed" => "completed",
    "failed" => "failed",
    "terminated" => "terminated"
  }
  @terminal_statuses ~w(completed failed terminated)

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

  @doc """
  Implements the contract `run.events` operation.

  Request concepts: `service_id`, `repo_id`, `run_id`, `event_cursor` (string or
  atom keys accepted). Returns `{:ok, %{"events" => [...], "next_event_cursor" =>
  cursor}}` or `{:error, reason}`.

  Options:

    * `:run_dir` - resolve against this run dir instead of locating by run id.
    * `:workspace_root` - workspace root to search (defaults to the configured
      root).
  """
  @spec run_events(request(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_events(request, opts \\ []) do
    with {:ok, ctx} <- context(request),
         {:ok, run_dir, manifest} <- load(ctx, opts) do
      all = project(manifest, run_dir, ctx)
      offset = parse_cursor(ctx.event_cursor)
      events = Enum.drop(all, offset)
      next = offset + length(events)

      {:ok, %{"events" => events, "next_event_cursor" => encode_cursor(next)}}
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
         {:ok, run_dir, manifest} <- load(ctx, opts) do
      all = project(manifest, run_dir, ctx)

      {:ok,
       %{
         "run_id" => ctx.run_id,
         "status" => Map.get(manifest, "status"),
         "last_event" => List.last(all),
         "evidence_pointers" => evidence_pointers(all),
         "event_cursor" => initial_cursor()
       }}
    end
  end

  defp context(request) when is_map(request) do
    run_id = value(request, :run_id)

    if is_binary(run_id) and run_id != "" do
      {:ok,
       %{
         service_id: value(request, :service_id) || "rondo-core",
         repo_id: value(request, :repo_id),
         run_id: run_id,
         event_cursor: value(request, :event_cursor)
       }}
    else
      {:error, :missing_run_id}
    end
  end

  defp context(_request), do: {:error, :invalid_request}

  defp load(ctx, opts) do
    with {:ok, run_dir} <- locate(ctx, opts),
         {:ok, manifest} <- RunLedger.load_manifest(run_dir) do
      {:ok, run_dir, manifest}
    end
  end

  # Locates the durable run dir. An explicit `:run_dir` wins; otherwise the run
  # id is resolved under the workspace `.rondo_runs` tree, which holds both
  # active and archived (completed) runs.
  defp locate(ctx, opts) do
    case Keyword.get(opts, :run_dir) do
      run_dir when is_binary(run_dir) ->
        {:ok, run_dir}

      _ ->
        workspace_root = opts |> Keyword.get(:workspace_root, Config.workspace_root()) |> Path.expand()

        [workspace_root, ".rondo_runs", "*", ctx.run_id, "manifest.json"]
        |> Path.join()
        |> Path.wildcard()
        |> case do
          [manifest_path | _] -> {:ok, Path.dirname(manifest_path)}
          [] -> {:error, :run_not_found}
        end
    end
  end

  defp fill_context(ctx, manifest) do
    repo_id = ctx.repo_id || default_repo_id(manifest)
    %{ctx | repo_id: repo_id}
  end

  defp default_repo_id(manifest) do
    get_in(manifest, ["repo", "workspace_root"]) || get_in(manifest, ["issue", "identifier"]) || Map.get(manifest, "run_id")
  end

  defp project(manifest, run_dir, ctx) do
    ctx = fill_context(ctx, manifest)

    (service_status_events(manifest, ctx) ++
       run_status_events(manifest, ctx) ++
       evidence_events(manifest, run_dir, ctx))
    |> Enum.sort_by(&order_key/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {event, sequence} -> finalize(event, sequence) end)
  end

  defp service_status_events(manifest, ctx) do
    started = started_at(manifest)

    if started do
      [
        staged(
          %{
            "type" => @service_status_changed,
            "service_id" => ctx.service_id,
            "status" => "running",
            "timestamp" => started
          },
          0,
          0,
          started
        )
      ]
    else
      []
    end
  end

  defp run_status_events(manifest, ctx) do
    started = started_at(manifest)

    initial =
      if started do
        [run_status_event(ctx, "running", started, 0)]
      else
        []
      end

    transitions =
      manifest
      |> Map.get("checkpoints", [])
      |> Enum.flat_map(fn checkpoint ->
        kind = Map.get(checkpoint, "kind")

        case Map.get(@status_checkpoint_kinds, kind) do
          nil ->
            []

          status ->
            [run_status_event(ctx, status, checkpoint_timestamp(checkpoint, manifest), checkpoint_seq(checkpoint))]
        end
      end)

    initial ++ transitions ++ synthetic_terminal(manifest, ctx, transitions)
  end

  # Older ledgers may record a terminal manifest status without a matching
  # terminal checkpoint. Backfill one deterministically from `finished_at`.
  defp synthetic_terminal(manifest, ctx, transitions) do
    status = Map.get(manifest, "status")

    cond do
      status not in @terminal_statuses -> []
      Enum.any?(transitions, &(&1.status == status)) -> []
      true -> [run_status_event(ctx, status, finished_at(manifest) || started_at(manifest), 1_000_000)]
    end
  end

  defp run_status_event(ctx, status, timestamp, sub) do
    staged(
      %{
        "type" => @run_status_changed,
        "repo_id" => ctx.repo_id,
        "run_id" => ctx.run_id,
        "status" => status,
        "timestamp" => timestamp
      },
      1,
      sub,
      timestamp
    )
    |> Map.put(:status, status)
  end

  defp evidence_events(manifest, run_dir, ctx) do
    manifest_refs = manifest |> Map.get("artifacts", []) |> normalize_refs(manifest)
    stream_refs = run_dir |> EventStream.read() |> EventStream.artifact_linked_events() |> stream_refs()

    # A stable fallback (run start) keeps cursor positions from shifting as an
    # active run's `updated_at` advances between polls.
    default_ts = started_at(manifest)

    (manifest_refs ++ stream_refs)
    |> Enum.reduce({[], MapSet.new(), 0}, fn {ref, ts}, {acc, seen, index} ->
      uri = evidence_uri(ctx.run_id, Map.get(ref, "path"))
      kind = Map.get(ref, "kind")

      if is_nil(uri) or MapSet.member?(seen, uri) do
        {acc, seen, index}
      else
        event =
          staged(
            %{
              "type" => @run_evidence_recorded,
              "repo_id" => ctx.repo_id,
              "run_id" => ctx.run_id,
              "artifact_kind" => kind,
              "uri" => uri,
              "timestamp" => ts || default_ts
            },
            2,
            index,
            ts || default_ts
          )

        {[event | acc], MapSet.put(seen, uri), index + 1}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Manifest artifacts carry no per-ref timestamp, so assign a stable one that
  # does not move between polls: the always-present agent-events log is anchored
  # at run start, and completion-time artifacts at `finished_at` (set once, then
  # immutable). This keeps already-delivered cursor positions stable.
  defp normalize_refs(artifacts, manifest) when is_list(artifacts) do
    started = started_at(manifest)
    finished = finished_at(manifest)

    artifacts
    |> Enum.filter(&(is_map(&1) and is_binary(Map.get(&1, "kind")) and is_binary(Map.get(&1, "path"))))
    |> Enum.map(fn ref ->
      timestamp =
        cond do
          Map.get(ref, "kind") == "agent_events" -> started
          not is_nil(finished) -> finished
          true -> started
        end

      {ref, timestamp}
    end)
  end

  defp normalize_refs(_artifacts, _manifest), do: []

  defp stream_refs(events) do
    Enum.flat_map(events, fn event ->
      ts = Map.get(event, "timestamp")
      event |> EventStream.artifact_refs() |> Enum.map(&{stringify_ref(&1), ts})
    end)
  end

  defp stringify_ref(ref) do
    %{"kind" => Map.get(ref, "kind") || Map.get(ref, :kind), "path" => Map.get(ref, "path") || Map.get(ref, :path)}
  end

  defp evidence_pointers(events) do
    events
    |> Enum.filter(&(Map.get(&1, "type") == @run_evidence_recorded))
    |> Enum.map(&%{"artifact_kind" => Map.get(&1, "artifact_kind"), "uri" => Map.get(&1, "uri")})
  end

  defp evidence_uri(_run_id, nil), do: nil

  defp evidence_uri(run_id, path) when is_binary(path) do
    if Path.type(path) == :absolute, do: "file://" <> path, else: "rondo-run://" <> run_id <> "/" <> path
  end

  # Staged events carry transient sort metadata under atom keys that are stripped
  # by `finalize/2`, so the emitted contract event is string-keyed only.
  defp staged(event, tier, sub, timestamp) do
    event
    |> Map.put(:_tier, tier)
    |> Map.put(:_sub, sub)
    |> Map.put(:_ts, timestamp)
  end

  defp order_key(event) do
    {sortable_ts(Map.get(event, :_ts)), Map.get(event, :_tier, 9), Map.get(event, :_sub, 0)}
  end

  defp finalize(event, sequence) do
    event
    |> Map.drop([:_tier, :_sub, :_ts, :status])
    |> Map.put("sequence", sequence)
    |> Map.put("namespace", namespace(event))
  end

  defp namespace(event) do
    %{"repo_id" => Map.get(event, "repo_id"), "run_id" => Map.get(event, "run_id"), "service_id" => Map.get(event, "service_id")}
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp started_at(manifest), do: get_in(manifest, ["timestamps", "started_at"]) || get_in(manifest, ["timestamps", "created_at"])
  defp finished_at(manifest), do: get_in(manifest, ["timestamps", "finished_at"])
  defp updated_at(manifest), do: get_in(manifest, ["timestamps", "updated_at"])

  defp checkpoint_timestamp(checkpoint, manifest), do: Map.get(checkpoint, "timestamp") || updated_at(manifest)

  defp checkpoint_seq(checkpoint) do
    case Map.get(checkpoint, "seq") do
      seq when is_integer(seq) -> seq
      _ -> 0
    end
  end

  defp encode_cursor(offset) when is_integer(offset) and offset >= 0, do: @cursor_prefix <> Integer.to_string(offset)

  defp parse_cursor(nil), do: 0
  defp parse_cursor(offset) when is_integer(offset) and offset >= 0, do: offset

  defp parse_cursor(cursor) when is_binary(cursor) do
    cursor
    |> String.trim_leading(@cursor_prefix)
    |> Integer.parse()
    |> case do
      {offset, _rest} when offset >= 0 -> offset
      _ -> 0
    end
  end

  defp parse_cursor(_cursor), do: 0

  defp sortable_ts(nil), do: 0

  defp sortable_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _ -> 0
    end
  end

  defp sortable_ts(_ts), do: 0

  defp value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
end
