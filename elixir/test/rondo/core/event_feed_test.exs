defmodule Rondo.Core.EventFeedTest do
  use Rondo.TestSupport

  alias Rondo.Core.EventFeed
  alias Rondo.RunEvidence.EventStream
  alias Rondo.RunLedger

  @started ~U[2026-05-10 15:30:00Z]
  @t_dispatch ~U[2026-05-10 15:30:05Z]
  @t_session ~U[2026-05-10 15:30:10Z]
  @t_gates ~U[2026-05-10 15:30:20Z]
  @t_result ~U[2026-05-10 15:30:30Z]
  @t_done ~U[2026-05-10 15:30:40Z]

  defp build_run(root) do
    issue = %{id: "issue-1", identifier: "RON-999", title: "Feed run", state: "In Progress"}

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        now: @started,
        random_suffix: "feedcafe",
        started_at: DateTime.to_iso8601(@started)
      )

    {:ok, ledger} = RunLedger.write_checkpoint(ledger, :dispatch, %{attempt: 1}, timestamp: @t_dispatch)
    :ok = RunLedger.append_agent_event(ledger, %{event: :session_started}, timestamp: @t_session)

    # A stream event that links artifacts, exercising the RON-129 read seam as an
    # evidence source. The duplicate agent-events ref must dedupe against the
    # manifest catalog; the gate results ref is new.
    :ok =
      EventStream.append(ledger.run_dir, %{
        "schema" => EventStream.schema(),
        "event" => "gates_completed",
        "timestamp" => DateTime.to_iso8601(@t_gates),
        "artifacts" => [
          %{"kind" => "agent_events", "path" => "artifacts/agent-events.ndjson"},
          %{"kind" => "gate_results", "path" => "artifacts/gates/results.json"}
        ]
      })

    :ok = RunLedger.append_agent_event(ledger, %{event: :result, usage: %{total_tokens: 5}}, timestamp: @t_result)
    {:ok, ledger} = RunLedger.complete_run(ledger, "completed", %{summary: "done"}, timestamp: @t_done)
    ledger
  end

  test "run.events projects the three rondo.core/v1 families over a run's durable ledger" do
    root = tmp_dir("event-feed")
    ledger = build_run(root)

    request = %{service_id: "svc-1", repo_id: "repo-x", run_id: ledger.run_id}
    assert {:ok, response} = EventFeed.run_events(request, workspace_root: root)

    events = response["events"]
    assert response["next_event_cursor"] == "rondo.core/v1:#{length(events)}"

    # Sequence is dense and 1-based.
    assert Enum.map(events, & &1["sequence"]) == Enum.to_list(1..length(events))

    types = Enum.map(events, & &1["type"]) |> Enum.uniq() |> Enum.sort()
    assert types == ["rondo.run.evidence_recorded", "rondo.run.status_changed", "rondo.service.status_changed"]

    # Service lifecycle at run start.
    assert %{"type" => "rondo.service.status_changed", "service_id" => "svc-1", "status" => "running", "timestamp" => start_ts} = List.first(events)
    assert start_ts == DateTime.to_iso8601(@started)

    # Run status transitions carry repo/run namespace + time context.
    statuses = for e <- events, e["type"] == "rondo.run.status_changed", do: e["status"]
    assert statuses == ["running", "completed"]

    assert Enum.all?(events, fn e ->
             case e["type"] do
               "rondo.service.status_changed" -> match?(%{"service_id" => _, "status" => _, "timestamp" => _}, e)
               "rondo.run.status_changed" -> match?(%{"repo_id" => "repo-x", "run_id" => _, "status" => _, "timestamp" => _}, e)
               "rondo.run.evidence_recorded" -> match?(%{"repo_id" => "repo-x", "run_id" => _, "artifact_kind" => _, "uri" => _, "timestamp" => _}, e)
             end
           end)

    # Evidence: manifest catalog + stream-linked refs, deduped by uri, exposed as
    # run-scoped pointers (never absolute ledger paths).
    uris = for e <- events, e["type"] == "rondo.run.evidence_recorded", do: e["uri"]
    assert "rondo-run://#{ledger.run_id}/artifacts/agent-events.ndjson" in uris
    assert "rondo-run://#{ledger.run_id}/artifacts/gates/results.json" in uris
    assert "rondo-run://#{ledger.run_id}/artifacts/delivery-artifact.json" in uris
    assert uris == Enum.uniq(uris)
    refute Enum.any?(uris, &String.contains?(&1, root))

    # Deterministic chronological ordering.
    timestamps = Enum.map(events, & &1["timestamp"])
    assert timestamps == Enum.sort(timestamps)
  end

  test "cursor semantics replay and tail without relaunching completed work" do
    root = tmp_dir("event-feed-cursor")
    ledger = build_run(root)
    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}

    assert {:ok, full} = EventFeed.run_events(Map.put(request, :event_cursor, EventFeed.initial_cursor()), workspace_root: root)
    total = length(full["events"])
    assert total > 3

    # Resume from a mid cursor returns exactly the tail, and re-reads the same
    # immutable ledger (archived replay) deterministically.
    assert {:ok, resumed} = EventFeed.run_events(Map.put(request, :event_cursor, "rondo.core/v1:2"), workspace_root: root)
    assert Enum.map(resumed["events"], & &1["sequence"]) == Enum.to_list(3..total)
    assert resumed["next_event_cursor"] == "rondo.core/v1:#{total}"

    # Tailing from the head cursor yields no new work.
    assert {:ok, tail} = EventFeed.run_events(Map.put(request, :event_cursor, full["next_event_cursor"]), workspace_root: root)
    assert tail["events"] == []
    assert tail["next_event_cursor"] == full["next_event_cursor"]

    # A blank cursor replays from the beginning.
    assert {:ok, replay} = EventFeed.run_events(Map.put(request, :event_cursor, ""), workspace_root: root)
    assert replay["events"] == full["events"]
  end

  test "run.status reports status, last event, and evidence pointers" do
    root = tmp_dir("event-feed-status")
    ledger = build_run(root)

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    assert {:ok, status} = EventFeed.run_status(request, workspace_root: root)
    assert status["run_id"] == ledger.run_id
    assert status["status"] == "completed"
    assert status["event_cursor"] == "rondo.core/v1:0"
    assert %{"type" => _, "sequence" => _} = status["last_event"]
    assert Enum.any?(status["evidence_pointers"], &match?(%{"artifact_kind" => _, "uri" => _}, &1))
  end

  test "run.dir option resolves a run directly and missing runs report cleanly" do
    root = tmp_dir("event-feed-locate")
    ledger = build_run(root)

    assert {:ok, _response} = EventFeed.run_events(%{repo_id: "repo", run_id: ledger.run_id}, run_dir: ledger.run_dir)
    assert {:error, :run_not_found} = EventFeed.run_events(%{repo_id: "repo", run_id: "does-not-exist"}, workspace_root: root)
    assert {:error, :missing_run_id} = EventFeed.run_events(%{repo_id: "repo"}, workspace_root: root)
  end

  test "already-delivered cursor positions stay stable as an active run appends events" do
    root = tmp_dir("event-feed-stability")
    issue = %{id: "issue-1", identifier: "RON-STABLE", title: "stable", state: "In Progress"}

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        now: @started,
        random_suffix: "stabl001",
        started_at: DateTime.to_iso8601(@started)
      )

    {:ok, ledger} = RunLedger.write_checkpoint(ledger, :dispatch, %{}, timestamp: @t_dispatch)
    :ok = RunLedger.append_agent_event(ledger, %{event: :session_started}, timestamp: @t_session)

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}

    # First poll of the still-active run.
    assert {:ok, poll1} = EventFeed.run_events(request, workspace_root: root)
    prefix = poll1["events"]
    assert prefix != []

    # The run progresses and completes.
    {:ok, _ledger} = RunLedger.complete_run(ledger, "completed", %{summary: "done"}, timestamp: @t_done)

    # A full replay keeps the earlier prefix byte-for-byte (same sequences), and
    # resuming from poll1's cursor returns exactly the newly appended suffix.
    assert {:ok, full} = EventFeed.run_events(request, workspace_root: root)
    assert Enum.take(full["events"], length(prefix)) == prefix

    assert {:ok, poll2} = EventFeed.run_events(Map.put(request, :event_cursor, poll1["next_event_cursor"]), workspace_root: root)
    assert poll2["events"] == Enum.drop(full["events"], length(prefix))
  end

  test "surface and event types match the rondo.core/v1 contract" do
    assert EventFeed.surface() == "rondo.core/v1"

    assert Enum.sort(EventFeed.event_types()) == [
             "rondo.run.evidence_recorded",
             "rondo.run.status_changed",
             "rondo.service.status_changed"
           ]
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
