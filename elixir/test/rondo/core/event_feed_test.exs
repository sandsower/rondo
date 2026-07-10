defmodule Rondo.Core.EventFeedTest do
  use Rondo.TestSupport

  alias Rondo.Core.EventFeed
  alias Rondo.RunEvidence.CoreEventIndex
  alias Rondo.RunEvidence.EventStream
  alias Rondo.RunLedger

  @started ~U[2026-05-10 15:30:00Z]
  @t_dispatch ~U[2026-05-10 15:30:05Z]
  @t_session ~U[2026-05-10 15:30:10Z]
  @t_gates ~U[2026-05-10 15:30:20Z]
  @t_result ~U[2026-05-10 15:30:30Z]
  @t_done ~U[2026-05-10 15:30:40Z]

  defp build_run(root, repo_id \\ "repo") do
    issue = %{id: "issue-1", identifier: "RON-999", title: "Feed run", state: "In Progress"}

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        repo_id: repo_id,
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
      RunLedger.append_agent_event(
        ledger,
        %{
          event: :gates_completed,
          artifacts: [
            %{"kind" => "agent_events", "path" => "artifacts/agent-events.ndjson"},
            %{"kind" => "gate_results", "path" => "artifacts/gates/results.json"}
          ]
        },
        timestamp: @t_gates
      )

    :ok = RunLedger.append_agent_event(ledger, %{event: :result, usage: %{total_tokens: 5}}, timestamp: @t_result)
    {:ok, ledger} = RunLedger.complete_run(ledger, "completed", %{summary: "done"}, timestamp: @t_done)
    ledger
  end

  test "run.events projects the three rondo.core/v1 families over a run's durable ledger" do
    root = tmp_dir("event-feed")
    ledger = build_run(root, "repo-x")

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

    assert {:error, :invalid_cursor} =
             EventFeed.run_events(
               Map.put(
                 request,
                 :event_cursor,
                 "rondo.core/v1:#{total + 1}"
               ),
               workspace_root: root
             )

    # Omitting the cursor replays from the beginning.
    assert {:ok, replay} = EventFeed.run_events(request, workspace_root: root)
    assert replay["events"] == full["events"]
  end

  test "invalid cursor syntax is rejected instead of replaying from zero" do
    root = tmp_dir("event-feed-invalid-cursor")
    ledger = build_run(root)
    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}

    for cursor <- [
          "",
          "7",
          "rondo.core/v1:-1",
          "rondo.core/v1:2tail",
          "rondo.core/v1:" <> String.duplicate("9", 21),
          "other.core/v1:2",
          -1,
          %{}
        ] do
      assert {:error, :invalid_cursor} =
               EventFeed.run_events(Map.put(request, :event_cursor, cursor), workspace_root: root)
    end
  end

  test "run.events uses bounded multi-page responses and advances by represented events" do
    root = tmp_dir("event-feed-pages")
    ledger = build_run(root)
    payload = String.duplicate("page-payload-", 600)

    artifacts =
      for index <- 1..180 do
        %{
          "kind" => "bulk-#{index}",
          "path" => "artifacts/#{index}-#{payload}.json",
          "recorded_at" => DateTime.to_iso8601(@t_session)
        }
      end

    append_manifest_artifacts(ledger, artifacts)

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    pages = collect_pages(root, request)

    assert length(pages) > 1
    assert Enum.all?(Enum.drop(pages, -1), &(&1["has_more"] == true))
    assert List.last(pages)["has_more"] == false

    {_offset, events} =
      Enum.reduce(pages, {0, []}, fn page, {offset, events} ->
        assert page["surface"] == "rondo.core/v1"
        assert page["repo_id"] == "repo"
        assert page["run_id"] == ledger.run_id
        assert length(page["events"]) <= 100
        assert byte_size(Jason.encode!(page)) <= 512 * 1024

        next_offset = cursor_offset(page["next_event_cursor"])
        assert next_offset - offset == length(page["events"])
        assert page["has_more"] == false or next_offset > offset

        {next_offset, events ++ page["events"]}
      end)

    assert Enum.map(events, & &1["sequence"]) == Enum.to_list(1..length(events))
    assert Enum.count(events, &(&1["type"] == "rondo.run.evidence_recorded")) >= 180
    assert Enum.all?(projected_strings(events), &(byte_size(&1) <= 1_024))
    assert events |> Jason.encode!() |> byte_size() < 256_000
  end

  test "oversized events become bounded diagnostics without stalling the cursor" do
    root = tmp_dir("event-feed-oversized-event")
    ledger = build_run(root)
    marker = String.duplicate("OVERSIZED-SECRET-MARKER", 35_000)

    append_manifest_artifacts(ledger, [
      %{
        "kind" => marker,
        "path" => "artifacts/#{marker}.json",
        "recorded_at" => DateTime.to_iso8601(@t_result)
      }
    ])

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    pages = collect_pages(root, request)
    events = Enum.flat_map(pages, & &1["events"])

    diagnostic =
      Enum.find(events, fn event ->
        event["type"] == "rondo.run.evidence_recorded" and event["payload_omitted"] == true
      end)

    assert diagnostic["namespace"] == %{"repo_id" => "repo", "run_id" => ledger.run_id}
    assert diagnostic["reason"] == "event_exceeds_observation_budget"
    assert byte_size(Jason.encode!(diagnostic)) < 1_024
    refute Jason.encode!(pages) =~ "OVERSIZED-SECRET-MARKER"

    final_cursor = pages |> List.last() |> Map.fetch!("next_event_cursor") |> cursor_offset()
    assert final_cursor == length(events)
  end

  test "run.status bounds last_event and evidence summaries while paged events stay complete" do
    root = tmp_dir("event-feed-bounded-status")
    ledger = build_run(root)
    marker = String.duplicate("STATUS-EVIDENCE-MARKER", 300)
    last_marker = String.duplicate("LAST-EVENT-MARKER", 700)

    artifacts =
      for index <- 1..64 do
        %{
          "kind" => "status-#{index}",
          "path" => "artifacts/#{index}-#{marker}.json",
          "recorded_at" => DateTime.to_iso8601(@t_result)
        }
      end ++
        [
          %{
            "kind" => last_marker,
            "path" => "artifacts/#{last_marker}.json",
            "recorded_at" => "2099-05-10T16:00:00Z"
          }
        ]

    append_manifest_artifacts(ledger, artifacts)
    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}

    assert {:ok, status} = EventFeed.run_status(request, workspace_root: root)
    assert status["surface"] == "rondo.core/v1"
    assert status["repo_id"] == "repo"
    assert status["run_id"] == ledger.run_id
    assert length(status["evidence_pointers"]) <= 32
    assert status["last_event"]["type"] == "rondo.run.evidence_recorded"
    assert status["last_event"]["payload_omitted"] == true
    assert byte_size(Jason.encode!(status)) < 128_000
    refute Jason.encode!(status) =~ "STATUS-EVIDENCE-MARKER"
    refute Jason.encode!(status) =~ "LAST-EVENT-MARKER"

    pages = collect_pages(root, request)
    events = Enum.flat_map(pages, & &1["events"])
    serialized_events = Jason.encode!(events)
    refute serialized_events =~ "STATUS-EVIDENCE-MARKER"
    refute serialized_events =~ "LAST-EVENT-MARKER"
    assert Enum.all?(projected_strings(events), &(byte_size(&1) <= 1_024))
  end

  test "evidence paths become validated run-relative or opaque Rondo-owned URIs" do
    root = tmp_dir("event-feed-evidence-uri")
    ledger = build_run(root)

    append_manifest_artifacts(ledger, [
      %{"kind" => "absolute", "path" => "/TOP-SECRET/ledger.json"},
      %{"kind" => "traversal", "path" => "../../TOP-SECRET/ledger.json"},
      %{"kind" => "legacy", "path" => "file:///TOP-SECRET/ledger.json"},
      %{"kind" => "safe", "path" => "artifacts/safe report.json"}
    ])

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    pages = collect_pages(root, request)
    evidence = pages |> Enum.flat_map(& &1["events"]) |> Enum.filter(&(&1["type"] == "rondo.run.evidence_recorded"))

    for kind <- ["absolute", "traversal", "legacy"] do
      event = Enum.find(evidence, &(&1["artifact_kind"] == kind))
      assert event["uri"] =~ ~r/^rondo-run:\/\/[^\/]+\/opaque\/[0-9a-f]{64}$/
      refute event["uri"] =~ "TOP-SECRET"
      refute event["uri"] =~ ".."
      refute event["uri"] =~ "file://"
    end

    safe = Enum.find(evidence, &(&1["artifact_kind"] == "safe"))
    assert safe["uri"] == "rondo-run://#{ledger.run_id}/artifacts/safe%20report.json"
  end

  test "manifest artifact ordering uses immutable recorded_at or run-start fallback" do
    root = tmp_dir("event-feed-artifact-order")
    ledger = build_run(root)

    append_manifest_artifacts(ledger, [
      %{"kind" => "late", "path" => "artifacts/late.json", "recorded_at" => DateTime.to_iso8601(@t_result)},
      %{"kind" => "early", "path" => "artifacts/early.json", "recorded_at" => DateTime.to_iso8601(@t_session)}
    ])

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    events = root |> collect_pages(request) |> Enum.flat_map(& &1["events"])
    early = Enum.find_index(events, &(&1["artifact_kind"] == "early"))
    late = Enum.find_index(events, &(&1["artifact_kind"] == "late"))

    assert early < late
    assert Enum.at(events, early)["timestamp"] == DateTime.to_iso8601(@t_session)
    assert Enum.at(events, late)["timestamp"] == DateTime.to_iso8601(@t_result)
  end

  test "an active artifact prefix stays byte-for-byte stable after terminalization" do
    root = tmp_dir("event-feed-artifact-prefix")
    issue = %{id: "issue-prefix", identifier: "RON-PREFIX", title: "prefix", state: "In Progress"}

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        repo_id: "repo",
        now: @started,
        random_suffix: "prefix01",
        started_at: DateTime.to_iso8601(@started)
      )

    {:ok, ledger} = RunLedger.write_checkpoint(ledger, :dispatch, %{}, timestamp: @t_dispatch)
    File.mkdir_p!(Path.join(ledger.run_dir, "artifacts"))
    File.write!(Path.join(ledger.run_dir, "artifacts/prefix.txt"), "prefix")
    {:ok, ledger} = RunLedger.link_artifacts(ledger, [%{"kind" => "prefix", "path" => "artifacts/prefix.txt"}])

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    assert {:ok, active} = EventFeed.run_events(request, workspace_root: root)
    prefix = active["events"]
    assert Enum.any?(prefix, &(&1["artifact_kind"] == "prefix"))

    completed_at = DateTime.utc_now() |> DateTime.add(1, :second)

    {:ok, _ledger} =
      RunLedger.complete_run(
        ledger,
        "completed",
        %{summary: "done"},
        timestamp: completed_at
      )

    completed = root |> collect_pages(request) |> Enum.flat_map(& &1["events"])

    assert Enum.take(completed, length(prefix)) == prefix
  end

  test "same-second terminalization appends status after an already-delivered artifact prefix" do
    root = tmp_dir("event-feed-same-second-terminal")
    issue = %{id: "issue-same-second", identifier: "RON-SAME", title: "same second", state: "In Progress"}

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        repo_id: "repo",
        now: @started,
        random_suffix: "samesecond",
        started_at: DateTime.to_iso8601(@started)
      )

    {:ok, ledger} =
      RunLedger.link_artifacts(ledger, [
        %{"kind" => "same_second", "path" => "artifacts/same-second.json"}
      ])

    set_manifest_artifact_recorded_at(
      ledger,
      "same_second",
      DateTime.to_iso8601(@t_done)
    )

    :ok =
      RunLedger.append_agent_event(
        ledger,
        %{
          event: :result,
          artifacts: [
            %{
              "kind" => "stream_same_second",
              "path" => "artifacts/stream-same-second.json"
            }
          ]
        },
        timestamp: @t_done
      )

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    assert {:ok, active} = EventFeed.run_events(request, workspace_root: root)
    prefix = active["events"]

    assert Enum.map(Enum.take(prefix, -2), & &1["artifact_kind"]) == [
             "same_second",
             "stream_same_second"
           ]

    {:ok, _ledger} =
      RunLedger.complete_run(ledger, "completed", %{summary: "done"}, timestamp: @t_done)

    assert {:ok, completed} = EventFeed.run_events(request, workspace_root: root)
    assert Enum.take(completed["events"], length(prefix)) == prefix

    assert {:ok, resumed} =
             EventFeed.run_events(
               Map.put(request, :event_cursor, active["next_event_cursor"]),
               workspace_root: root
             )

    assert [
             %{
               "type" => "rondo.run.status_changed",
               "status" => "completed"
             }
             | _later_events
           ] = resumed["events"]
  end

  test "legacy checkpoint and stream prefix survives the first ordered stream append" do
    root = tmp_dir("event-feed-legacy-mixed-cutover")
    issue = %{id: "issue-legacy-mixed", identifier: "RON-LEGACY-MIXED", title: "legacy mixed", state: "In Progress"}

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        repo_id: "repo",
        now: @started,
        random_suffix: "legmixed",
        started_at: DateTime.to_iso8601(@started)
      )

    {:ok, ledger} =
      RunLedger.pause_run(ledger, %{reason: "visible checkpoint"}, timestamp: @t_gates)

    :ok =
      EventStream.append(ledger.run_dir, %{
        "schema" => EventStream.schema(),
        "event" => "artifact",
        "timestamp" => DateTime.to_iso8601(@t_session),
        "artifacts" => [
          %{"kind" => "legacy_stream", "path" => "artifacts/legacy-stream.json"}
        ]
      })

    downgrade_to_legacy(ledger)

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    assert {:ok, before} = EventFeed.run_events(request, workspace_root: root)
    prefix = before["events"]

    :ok =
      RunLedger.append_agent_event(
        ledger,
        %{
          event: :artifact,
          artifacts: [
            %{"kind" => "ordered_stream", "path" => "artifacts/ordered-stream.json"}
          ]
        },
        timestamp: @t_result
      )

    assert {:ok, after_append} = EventFeed.run_events(request, workspace_root: root)
    assert Enum.take(after_append["events"], length(prefix)) == prefix

    assert {:ok, resumed} =
             EventFeed.run_events(
               Map.put(request, :event_cursor, before["next_event_cursor"]),
               workspace_root: root
             )

    assert resumed["events"] == Enum.drop(after_append["events"], length(prefix))
    assert Enum.map(resumed["events"], & &1["artifact_kind"]) == ["ordered_stream"]
  end

  test "timestamp-reordered legacy artifact catalog survives its first ordered mutation" do
    root = tmp_dir("event-feed-legacy-artifact-cutover")
    issue = %{id: "issue-legacy-artifacts", identifier: "RON-LEGACY-ARTIFACTS", title: "legacy artifacts", state: "In Progress"}

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        repo_id: "repo",
        now: @started,
        random_suffix: "legartfs",
        started_at: DateTime.to_iso8601(@started)
      )

    append_manifest_artifacts(ledger, [
      %{"kind" => "legacy_late", "path" => "artifacts/legacy-late.json", "recorded_at" => DateTime.to_iso8601(@t_result)},
      %{"kind" => "legacy_early", "path" => "artifacts/legacy-early.json", "recorded_at" => DateTime.to_iso8601(@t_session)}
    ])

    downgrade_to_legacy(ledger)

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    assert {:ok, before} = EventFeed.run_events(request, workspace_root: root)
    prefix = before["events"]

    assert Enum.find_index(prefix, &(&1["artifact_kind"] == "legacy_early")) <
             Enum.find_index(prefix, &(&1["artifact_kind"] == "legacy_late"))

    {:ok, _ledger} =
      RunLedger.link_artifacts(ledger, [
        %{"kind" => "ordered", "path" => "artifacts/ordered.json"}
      ])

    assert {:ok, after_link} = EventFeed.run_events(request, workspace_root: root)
    assert Enum.take(after_link["events"], length(prefix)) == prefix

    assert {:ok, resumed} =
             EventFeed.run_events(
               Map.put(request, :event_cursor, before["next_event_cursor"]),
               workspace_root: root
             )

    assert resumed["events"] == Enum.drop(after_link["events"], length(prefix))
    assert Enum.map(resumed["events"], & &1["artifact_kind"]) == ["ordered"]
  end

  test "stream-first evidence promotion preserves its visible position and timestamp" do
    root = tmp_dir("event-feed-stream-promotion")
    issue = %{id: "issue-stream-promotion", identifier: "RON-STREAM-PROMOTION", title: "stream promotion", state: "In Progress"}

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        repo_id: "repo",
        now: @started,
        random_suffix: "strpromo",
        started_at: DateTime.to_iso8601(@started)
      )

    :ok =
      RunLedger.append_agent_event(
        ledger,
        %{
          event: :artifact,
          artifacts: [
            %{"kind" => "stream_first", "path" => "artifacts/promoted.json"}
          ]
        },
        timestamp: @t_session
      )

    {:ok, ledger} =
      RunLedger.pause_run(ledger, %{reason: "visible checkpoint"}, timestamp: @t_gates)

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    assert {:ok, before} = EventFeed.run_events(request, workspace_root: root)
    prefix = before["events"]

    promoted_before = Enum.find(prefix, &(&1["uri"] == "rondo-run://#{ledger.run_id}/artifacts/promoted.json"))
    assert promoted_before["artifact_kind"] == "stream_first"
    assert promoted_before["timestamp"] == DateTime.to_iso8601(@t_session)

    {:ok, _ledger} =
      RunLedger.link_artifacts(ledger, [
        %{"kind" => "manifest_promotion", "path" => "artifacts/promoted.json"}
      ])

    assert {:ok, after_promotion} = EventFeed.run_events(request, workspace_root: root)
    assert after_promotion["events"] == prefix
    assert after_promotion["next_event_cursor"] == before["next_event_cursor"]
  end

  test "legacy synthetic terminal status stays before artifacts linked later" do
    root = tmp_dir("event-feed-synthetic-terminal-cutover")
    issue = %{id: "issue-synthetic-terminal", identifier: "RON-SYNTHETIC-TERMINAL", title: "synthetic terminal", state: "In Progress"}

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        repo_id: "repo",
        now: @started,
        random_suffix: "syntterm",
        started_at: DateTime.to_iso8601(@started)
      )

    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()

    legacy_terminal =
      manifest
      |> Map.put("status", "completed")
      |> put_in(["timestamps", "updated_at"], DateTime.to_iso8601(@t_done))
      |> put_in(["timestamps", "finished_at"], DateTime.to_iso8601(@t_done))
      |> strip_observation_metadata()

    File.write!(ledger.manifest_path, Jason.encode!(legacy_terminal))

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    assert {:ok, before} = EventFeed.run_events(request, workspace_root: root)
    prefix = before["events"]
    assert List.last(prefix)["status"] == "completed"

    assert {:ok, projected} = CoreEventIndex.project(legacy_terminal, ledger.run_dir)

    synthetic_terminal =
      Enum.find(projected, &(&1["identity"] == "run:terminal:completed"))

    assert synthetic_terminal["status"] == "completed"
    refute Map.has_key?(synthetic_terminal, "aliases")

    {:ok, _ledger} =
      RunLedger.link_artifacts(ledger, [
        %{"kind" => "after_terminal", "path" => "artifacts/after-terminal.json"}
      ])

    assert {:ok, after_link} = EventFeed.run_events(request, workspace_root: root)
    assert Enum.take(after_link["events"], length(prefix)) == prefix

    assert {:ok, resumed} =
             EventFeed.run_events(
               Map.put(request, :event_cursor, before["next_event_cursor"]),
               workspace_root: root
             )

    assert resumed["events"] == Enum.drop(after_link["events"], length(prefix))

    assert Enum.map(resumed["events"], & &1["artifact_kind"]) == [
             "after_terminal",
             "delivery_artifact"
           ]
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

  test "all projected strings stay below the cross-client preservation limit" do
    root = tmp_dir("event-feed-string-bounds")
    ledger = build_run(root)
    secret = String.duplicate("PROJECTED-SECRET-", 400)

    append_manifest_artifacts(ledger, [
      %{
        "kind" => secret,
        "path" => "artifacts/#{secret}.json",
        "recorded_at" => secret
      }
    ])

    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()

    manifest =
      manifest
      |> Map.put("status", secret)
      |> put_in(["timestamps", "updated_at"], secret)

    File.write!(ledger.manifest_path, Jason.encode!(manifest))

    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}
    assert {:ok, events} = EventFeed.run_events(request, workspace_root: root)
    assert {:ok, status} = EventFeed.run_status(request, workspace_root: root)

    assert status["status"] == "unknown"
    assert Enum.all?(projected_strings(events), &(byte_size(&1) <= 1_024))
    assert Enum.all?(projected_strings(status), &(byte_size(&1) <= 1_024))
    refute Jason.encode!(events) =~ "PROJECTED-SECRET"
    refute Jason.encode!(status) =~ "PROJECTED-SECRET"
  end

  test "bounded exact run ids stay exact while expanded evidence URIs use an opaque component" do
    root = tmp_dir("event-feed-bounded-run-id")
    ledger = build_run(root)
    run_id = String.duplicate(":", 512)
    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()

    index =
      manifest["core_event_feed_v1"]
      |> Map.put("run_id", run_id)
      |> Map.update!("events", fn descriptors ->
        Enum.map(descriptors, fn
          %{"type" => "evidence", "uri" => uri} = descriptor ->
            path = String.replace_prefix(uri, "rondo-run://#{ledger.run_id}/", "")
            rebound_uri = CoreEventIndex.evidence_uri(run_id, path)

            descriptor
            |> Map.put("uri", rebound_uri)
            |> Map.put("identity", "evidence:" <> rebound_uri)

          descriptor ->
            descriptor
        end)
      end)

    manifest = manifest |> Map.put("run_id", run_id) |> Map.put("core_event_feed_v1", index)
    File.write!(ledger.manifest_path, Jason.encode!(manifest))

    request = %{service_id: "svc", repo_id: "repo", run_id: run_id}
    assert {:ok, response} = EventFeed.run_events(request, workspace_root: root)
    assert response["run_id"] == run_id

    evidence =
      Enum.filter(
        response["events"],
        &(&1["type"] == "rondo.run.evidence_recorded")
      )

    assert evidence != []
    assert Enum.all?(evidence, &String.starts_with?(&1["uri"], "rondo-run://opaque-"))
    assert Enum.all?(projected_strings(response), &(byte_size(&1) <= 1_024))
  end

  test "external lookup requires an exact repository/run pair and rejects direct run dirs" do
    root = tmp_dir("event-feed-locate")
    ledger = build_run(root)

    assert {:ok, _response} =
             EventFeed.run_events(%{repo_id: "repo", run_id: ledger.run_id},
               workspace_root: root
             )

    assert {:error, :run_not_found} =
             EventFeed.run_events(%{repo_id: "other-repo", run_id: ledger.run_id},
               workspace_root: root
             )

    assert {:error, :external_run_dir_not_allowed} =
             EventFeed.run_events(%{repo_id: "repo", run_id: ledger.run_id},
               workspace_root: tmp_dir("event-feed-empty"),
               run_dir: ledger.run_dir
             )

    assert {:error, :external_run_dir_not_allowed} =
             EventFeed.run_status(%{repo_id: "repo", run_id: ledger.run_id},
               workspace_root: tmp_dir("event-feed-status-empty"),
               run_dir: ledger.run_dir
             )

    assert {:error, :run_not_found} = EventFeed.run_events(%{repo_id: "repo", run_id: "does-not-exist"}, workspace_root: root)
    assert {:error, :missing_run_id} = EventFeed.run_events(%{repo_id: "repo"}, workspace_root: root)
    assert {:error, :missing_repo_id} = EventFeed.run_events(%{run_id: ledger.run_id}, workspace_root: root)
    assert {:error, :run_not_found} = EventFeed.run_events(%{repo_id: "repo", run_id: "*"}, workspace_root: root)

    assert {:error, :invalid_repo_id} =
             EventFeed.run_events(
               %{repo_id: String.duplicate("r", 513), run_id: ledger.run_id},
               workspace_root: root
             )

    assert {:error, :invalid_run_id} =
             EventFeed.run_events(
               %{repo_id: "repo", run_id: String.duplicate("r", 513)},
               workspace_root: root
             )

    assert {:error, :invalid_service_id} =
             EventFeed.run_events(
               %{
                 service_id: String.duplicate("s", 513),
                 repo_id: "repo",
                 run_id: ledger.run_id
               },
               workspace_root: root
             )
  end

  test "a present malformed or mismatched Core event index fails closed" do
    root = tmp_dir("event-feed-corrupt-index-shape")
    ledger = build_run(root)
    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}

    for corrupt_index <- [
          "malformed",
          %{"version" => 2, "run_id" => ledger.run_id, "events" => []},
          %{"version" => 1, "run_id" => "another-run", "events" => []}
        ] do
      put_core_event_index(ledger, corrupt_index)

      assert {:error, {:core_event_index_corrupt, _reason}} =
               EventFeed.run_events(request, workspace_root: root)

      assert {:error, {:core_event_index_corrupt, _reason}} =
               EventFeed.run_status(request, workspace_root: root)
    end
  end

  test "unsupported descriptor types fail closed instead of crashing the feed" do
    root = tmp_dir("event-feed-corrupt-index-type")
    ledger = build_run(root)
    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}

    update_core_event_index(ledger, fn index ->
      update_in(index, ["events", Access.at(0)], &Map.put(&1, "type", "future_type"))
    end)

    assert {:error, {:core_event_index_corrupt, {:invalid_descriptor, 0, {:unsupported_type, "future_type"}}}} =
             EventFeed.run_events(request, workspace_root: root)
  end

  test "invalid descriptor aliases and immutable fields fail closed" do
    root = tmp_dir("event-feed-corrupt-index-descriptor")
    ledger = build_run(root)

    index = core_event_index(ledger)

    corrupt_indexes = [
      update_in(index, ["events", Access.at(0)], &Map.put(&1, "aliases", "not-a-list")),
      update_in(index, ["events", Access.at(0)], &Map.delete(&1, "timestamp")),
      update_in(index, ["events", Access.at(0)], &Map.put(&1, "unexpected", "mutable"))
    ]

    Enum.each(corrupt_indexes, fn corrupt_index ->
      assert {:error, {:core_event_index_corrupt, _reason}} =
               CoreEventIndex.project(
                 ledger.manifest |> Map.put("core_event_feed_v1", corrupt_index),
                 ledger.run_dir
               )
    end)
  end

  test "terminal checkpoint aliases are mandatory and corruption preserves cursor positions" do
    root = tmp_dir("event-feed-terminal-alias-integrity")
    ledger = build_run(root)
    request = %{service_id: "svc", repo_id: "repo", run_id: ledger.run_id}

    assert {:ok, baseline} = EventFeed.run_events(request, workspace_root: root)
    valid_index = core_event_index(ledger)

    terminal_index =
      Enum.find_index(valid_index["events"], fn descriptor ->
        descriptor["type"] == "run_status" and
          descriptor["status"] == "completed" and
          String.starts_with?(descriptor["identity"], "checkpoint:")
      end)

    assert is_integer(terminal_index)

    terminal_descriptor = Enum.at(valid_index["events"], terminal_index)
    assert terminal_descriptor["aliases"] == ["run:terminal:completed"]

    corrupt_descriptors = [
      Map.delete(terminal_descriptor, "aliases"),
      Map.put(terminal_descriptor, "aliases", []),
      Map.put(terminal_descriptor, "aliases", ["run:terminal:failed"])
    ]

    Enum.each(corrupt_descriptors, fn corrupt_descriptor ->
      corrupt_index = put_in(valid_index, ["events", Access.at(terminal_index)], corrupt_descriptor)
      put_core_event_index(ledger, corrupt_index)

      assert {:error, {:core_event_index_corrupt, {:invalid_descriptor, ^terminal_index, :invalid_aliases}}} =
               EventFeed.run_events(request, workspace_root: root)

      put_core_event_index(ledger, valid_index)
      assert {:ok, replay} = EventFeed.run_events(request, workspace_root: root)
      assert replay == baseline
    end)
  end

  test "already-delivered cursor positions stay stable as an active run appends events" do
    root = tmp_dir("event-feed-stability")
    issue = %{id: "issue-1", identifier: "RON-STABLE", title: "stable", state: "In Progress"}

    {:ok, ledger} =
      RunLedger.create_run(issue,
        workspace_root: root,
        repo_id: "repo",
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

  defp append_manifest_artifacts(ledger, artifacts) do
    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
    updated = Map.update(manifest, "artifacts", artifacts, &(&1 ++ artifacts))
    File.write!(ledger.manifest_path, Jason.encode!(updated))
  end

  defp set_manifest_artifact_recorded_at(ledger, kind, recorded_at) do
    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()

    artifacts =
      Enum.map(manifest["artifacts"], fn artifact ->
        if artifact["kind"] == kind,
          do: Map.put(artifact, "recorded_at", recorded_at),
          else: artifact
      end)

    File.write!(ledger.manifest_path, Jason.encode!(Map.put(manifest, "artifacts", artifacts)))
  end

  defp core_event_index(ledger) do
    ledger.manifest_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("core_event_feed_v1")
  end

  defp put_core_event_index(ledger, index) do
    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!()
    File.write!(ledger.manifest_path, Jason.encode!(Map.put(manifest, "core_event_feed_v1", index)))
  end

  defp update_core_event_index(ledger, update) do
    put_core_event_index(ledger, update.(core_event_index(ledger)))
  end

  defp downgrade_to_legacy(ledger) do
    manifest = ledger.manifest_path |> File.read!() |> Jason.decode!() |> strip_observation_metadata()
    File.write!(ledger.manifest_path, Jason.encode!(manifest))

    ledger.run_dir
    |> Path.join("checkpoints/*.json")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      checkpoint = path |> File.read!() |> Jason.decode!() |> strip_observation_metadata()
      File.write!(path, Jason.encode!(checkpoint))
    end)

    event_path = EventStream.path(ledger.run_dir)

    if File.exists?(event_path) do
      rewritten =
        event_path
        |> File.stream!()
        |> Enum.map_join("\n", fn line ->
          line
          |> Jason.decode!()
          |> strip_observation_metadata()
          |> Jason.encode!()
        end)

      File.write!(event_path, if(rewritten == "", do: "", else: rewritten <> "\n"))
    end
  end

  defp strip_observation_metadata(value) when is_map(value) do
    value
    |> Map.drop([
      "core_event_feed_v1",
      "observation_order",
      "next_observation_order",
      "observation_index"
    ])
    |> Map.new(fn {key, item} -> {key, strip_observation_metadata(item)} end)
  end

  defp strip_observation_metadata(value) when is_list(value),
    do: Enum.map(value, &strip_observation_metadata/1)

  defp strip_observation_metadata(value), do: value

  defp collect_pages(root, request), do: collect_pages(root, request, nil, [], 20)

  defp collect_pages(_root, _request, _cursor, _pages, 0), do: flunk("event paging did not settle")

  defp collect_pages(root, request, cursor, pages, remaining) do
    paged_request = if cursor, do: Map.put(request, :event_cursor, cursor), else: request
    assert {:ok, page} = EventFeed.run_events(paged_request, workspace_root: root)
    pages = [page | pages]

    if page["has_more"] == true do
      assert page["events"] != []
      assert page["next_event_cursor"] != cursor
      collect_pages(root, request, page["next_event_cursor"], pages, remaining - 1)
    else
      Enum.reverse(pages)
    end
  end

  defp cursor_offset("rondo.core/v1:" <> encoded), do: String.to_integer(encoded)

  defp projected_strings(value) when is_binary(value), do: [value]
  defp projected_strings(value) when is_list(value), do: Enum.flat_map(value, &projected_strings/1)

  defp projected_strings(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&projected_strings/1)

  defp projected_strings(_value), do: []
end
