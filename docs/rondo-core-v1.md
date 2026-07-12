# Rondo Core v1 single-manifest API

This document defines the local operator and HTTP contract for submitting one approved execution manifest to `rondo.core/v1` and observing the resulting durable run.
Beislið remains responsible for authoring and approving exported envelopes, while Rondo owns admission, execution, supervision, run evidence, and replay.

## Availability and trust boundary

The Core API is available only when Rondo starts its configured HTTP service.
Every Core route accepts peers from IPv4 `127.0.0.0/8` or IPv6 `::1` and rejects every other peer with HTTP 403 and `loopback_required`.
The endpoint performs this loopback check before request-body parsing, controller dispatch, or orchestrator invocation, so malformed or oversized remote payloads are rejected without being parsed.
The surface is intended for trusted same-host operators and is not a remote execution API.
Callers identify runs only through the returned opaque service, repository, run, cursor, and evidence values, and the API accepts no ledger-directory parameter.

## Verify service identity and readiness

`GET /api/v1/health` returns the exact identity of the current Rondo process before a lifecycle owner adopts it.
The route is loopback-only and exposes no workflow, workspace, ledger, log, or filesystem path.

```json
{
  "surface": "rondo.core/v1",
  "runtime_version": "0.1.0",
  "instance_id": "019b8941-4a0c-7ad5-b7ef-cb3c45e4a819",
  "service_mode": "trackerless_core",
  "ready": true,
  "active_run_count": 0
}
```

`instance_id` is an immutable random UUID generated once for the life of the BEAM process.
Lifecycle owners must treat stored endpoint and process metadata only as hints until `surface`, `runtime_version`, `instance_id`, and `service_mode` match the live response.
`ready` is true only while the coupled execution orchestrator can answer readiness queries.
`active_run_count` is a point-in-time report of currently executing Rondo-owned runs.
Lifecycle owners use it to refuse shutdown while observed work is active, but it is advisory because this version has no atomic drain fence preventing a new admission immediately after the health read.

## Trackerless Core service mode

`rondo core --port 0 --ready-file <path> --logs-root <path> --workspace-root <path>` starts the execution service without a tracker workflow or tracker polling loop.
The command binds the normal HTTP service to literal loopback on a dynamically allocated port and atomically writes the private readiness document only after the endpoint and exact process identity are live.
The readiness document adds `base_url` to the health fields so the lifecycle owner can perform an independent live handshake before publishing its own runtime descriptor.
Trackerless Core mode retains the coupled task supervisor and durable startup recovery boundary.
It does not start tracker-only workflow, dashboard, presenter, or status children and does not run tracker cleanup or reconciliation.
Normal Rondo daemon startup remains `tracker_daemon` mode and preserves its existing tracker behavior.
Trackerless admission validates Core execution settings such as the agent command and capacity, but it does not require tracker kind, tracker credentials, tracker project identity, or a tracker repository URL.
When no workflow file exists, Core uses the built-in execution defaults; when a workflow file exists but is malformed or contains an invalid Core execution setting, admission fails closed.
The normal daemon continues to require and validate its complete tracker configuration.

## Submit one approved manifest

`POST /api/v1/execution-requests` accepts exactly one selected child manifest from an approved `approved-slice-plan-export-v0` bundle.

```json
{
  "manifest_path": "/canonical/repository/.beislid/exports/bundle/slices/slice.json",
  "manifest_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "repo_id": "opaque-caller-repository-id",
  "plot_id": "opaque-caller-plot-id"
}
```

`manifest_path` must resolve to the canonical regular non-symlink `approved-slice-v1` child whose filename matches its slice identifier and whose sibling bundle validates as approved.
`manifest_sha256` must be exactly 64 lowercase hexadecimal characters and must match the exact selected-manifest bytes.
`repo_id` must be a nonempty exact identifier without surrounding whitespace, and Rondo preserves it without normalization.
`plot_id` is optional for standalone callers and uses the same bounded opaque-identifier rules.
When supplied, Rondo persists and echoes it without inferring meaning from the manifest, ticket, branch, or path.
Rondo validates the complete bundle and selected child relationship even though this surface admits only one child for execution.

A newly accepted run returns HTTP 202 with `deduplicated` set to `false`.
An idempotent replay of an already accepted repository, manifest-digest, and Plot tuple returns HTTP 200 with `deduplicated` set to `true` and never starts a second run.
The same repository and digest under another Plot creates an independent run.

```json
{
  "surface": "rondo.core/v1",
  "service_id": "rondo-core",
  "repo_id": "opaque-caller-repository-id",
  "plot_id": "opaque-caller-plot-id",
  "run_id": "opaque-rondo-run-id",
  "status": "running",
  "event_cursor": "rondo.core/v1:0",
  "deduplicated": false
}
```

The response always echoes the exact accepted `repo_id` and any supplied `plot_id`, and every identifier remains opaque to the caller.
The `status` field reports the current durable state, so a deduplicated terminal run can return `completed`, `failed`, `terminated`, or `paused` instead of `running`.

## Durable admission and acknowledgment

Each execution request records a durable admission phase of `admitting`, `accepted`, or `rejected`.
Deduplication considers only accepted runs, and capacity rejection occurs before a second run ledger is created.
Rondo rereads and digest-checks the validated bundle and selected manifest immediately before acceptance, then freezes both exact byte sequences with their digests, approval identity, bundle version, and selected-slice evidence.
Rondo does not acknowledge acceptance until the run ledger, frozen intake evidence, dispatch checkpoint, supervised worker, running entry, and accepted state are established.
A freeze, checkpoint, or spawn failure marks the unacknowledged attempt rejected, which lets a retry create a new attempt instead of deduplicating to incomplete state.
An accepted run remains the idempotent result after it reaches a terminal state.

## Read current status

`GET /api/v1/runs/{run_id}?repo_id={repo_id}` reads one exact repository and run pair from durable evidence.

```json
{
  "surface": "rondo.core/v1",
  "repo_id": "opaque-caller-repository-id",
  "plot_id": "opaque-caller-plot-id",
  "run_id": "opaque-rondo-run-id",
  "status": "running",
  "last_event": null,
  "evidence_pointers": [
    {
      "artifact_kind": "execution_request",
      "uri": "rondo-run://opaque-evidence"
    }
  ],
  "event_cursor": "rondo.core/v1:0"
}
```

The response requires exact `surface`, `repo_id`, and `run_id` echoes, projects any Plot identity from durable admission state, and exposes only a bounded evidence summary.
Evidence pointers are opaque Rondo-owned URIs that never reveal absolute ledger or workspace paths, and callers must not parse them to infer storage layout.
The status cursor is the replay-from-start cursor for the paged event feed.

## Read paged events

`GET /api/v1/runs/{run_id}/events?repo_id={repo_id}&cursor={event_cursor}` reads the next server-bounded page after an optional cursor.

```json
{
  "surface": "rondo.core/v1",
  "repo_id": "opaque-caller-repository-id",
  "plot_id": "opaque-caller-plot-id",
  "run_id": "opaque-rondo-run-id",
  "events": [],
  "next_event_cursor": "rondo.core/v1:0",
  "has_more": false
}
```

The response requires exact `surface`, `repo_id`, and `run_id` echoes and carries any durable Plot identity on the page and each run-scoped event namespace.
Each cursor is an opaque strict `rondo.core/v1:<decimal>` token, and malformed or foreign cursor syntax returns `invalid_request` instead of replaying from zero.
`next_event_cursor` advances by exactly the number of represented events in the page, and the caller continues with that cursor while `has_more` is `true`.
Artifact events retain immutable ledger-recorded ordering timestamps, so an already delivered cursor prefix does not shift when a run finishes.
An oversized individual event is replaced at the same sequence position by a bounded sanitized diagnostic, which preserves cursor progress.
Every serialized Core response remains below the client safety limit of 1 MiB.

## Execution ownership and restart behavior

Manifest-backed Core runs are trackerless and never fetch tracker context, reconcile tracker state, transition a tracker issue, or schedule tracker retries.
Rondo owns the worker, workspace, capacity slot, run ledger, terminal evidence, and observation feed after acceptance.
A caller disconnect, observation timeout, or abandoned polling session does not stop or cancel the accepted run.
The Orchestrator and its task supervisor share a `one_for_all` supervision boundary, so an Orchestrator restart first stops the workers it owns.
Startup reconciles every durable running ledger without a surviving owner to `terminated` with the stable reason `orchestrator_restart` before serving new submissions.
Restart reconciliation is idempotent and fails startup closed when Rondo cannot persist known orphan evidence safely.
This version provides at-most-once execution with explicit terminal evidence rather than adopting an uncertain worker after restart.

## Stable errors

Every error response uses the sanitized envelope `{"error":{"code":"stable_code","message":"safe operator message"}}`.
Error messages never contain manifest contents, bundle contents, absolute ledger paths, or internal exception terms.

- HTTP 400 uses `invalid_request` for malformed fields, missing identifiers, invalid cursor syntax, or an invalid lowercase digest shape.
- HTTP 403 uses `loopback_required` when the peer is outside the accepted loopback ranges.
- HTTP 404 uses `run_not_found` when the exact repository and run pair does not exist.
- HTTP 409 uses `digest_conflict` when the submitted digest does not match the manifest bytes.
- HTTP 422 uses `invalid_manifest` when the selected manifest or bundle shape is invalid.
- HTTP 422 uses `unapproved_manifest` when the bundle or selected child does not carry valid approval.
- HTTP 429 uses `capacity_exhausted` when a new run cannot be admitted without exceeding configured capacity.
- HTTP 503 uses `orchestrator_unavailable` when submission cannot reach a healthy orchestrator.
- HTTP 503 uses `core_unavailable` when status or event observation cannot read a healthy Core feed.

## Deferred operations

This version intentionally has no cancellation operation, because cancellation requires a separate policy, terminal-state, and evidence contract.
This version admits one selected manifest and does not schedule a whole bundle, dependency graph, parallel group, or supersede chain.
Seamless worker continuation across Orchestrator restarts and admission across multiple Rondo service instances require separate ownership and lease designs.
