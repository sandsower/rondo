# ADR 0001: Transport for the rondo.core/v1 run event feed

Status: amended by RON-149
Date: 2026-07-06

## Context

RON-166 implements the event half of the provisional `rondo.core/v1` execution
contract (spec: teotl `contracts/execution.md`).
The contract defines a `run.events` operation - request `service_id`, `repo_id`,
`run_id`, `event_cursor`; response `events`, `next_event_cursor` - and three
event families: `rondo.service.status_changed`, `rondo.run.status_changed`, and
`rondo.run.evidence_recorded`.

The contract deliberately leaves transport open:

> Transport is not fixed yet. A Rondo CLI, local BEAM service API, HTTP endpoint,
> or standalone Rondo command may satisfy the contract if it exposes the same
> concepts and passes the conformance runner.

We must pick a transport for the first implementation. Constraints and context:

- The herd is **local**: coordinator (crust) and rondo core run on the same host
  against the same `.rondo_runs` ledger tree. There is no remote/multi-host
  requirement yet.
- Standalone rondo must remain a **first-class consumer**; crust must not be the
  only supported coordinator.
- The feed must support **cursor replay** for archived runs and **tailing** for
  active runs, without relaunching completed work.
- The feed is **read-only** over durable ledger state.

## Decision

**Local BEAM API as the core, with CLI and loopback HTTP transports.**

- `Rondo.Core.EventFeed` is the reusable local BEAM API. It builds the contract
  event stream from the durable run ledger (manifest + the `rondo.events/v0`
  NDJSON log read through the RON-129 `Rondo.RunEvidence.EventStream` seam) and
  implements `run.events` and `run.status`.
- `mix rondo.run_events` is the CLI transport over that API. It takes only
  contract concepts as flags (`--repo-id`, `--run-id`, `--service-id`,
  `--cursor`) and prints the `run.events`/`run.status` JSON response on stdout.
- The RON-149 Core intake bridge adds loopback-only HTTP submission, status,
  and event routes over the same BEAM API.
  The HTTP surface rejects non-loopback peers before parsing request bodies and
  keeps evidence identifiers opaque.

A minimal external consumer (`elixir/examples/run_events_tail.py`) tails a run
end to end using only the CLI and contract concepts.

## Rationale

- **One projection, two local transports.** The CLI remains the simplest
  standalone transport, while the existing optional Rondo HTTP service gives
  Crust a durable operator boundary without invoking a Rondo subprocess.
  Both transports reuse the same ledger-backed projection and cursor semantics.
- **In-process coordinators keep the BEAM API.** A coordinator already on the
  BEAM (or a future HTTP/file-tail adapter) can call `Rondo.Core.EventFeed`
  directly; the CLI is a thin shell over it, so no logic is trapped in the
  transport.
- **Standalone-first.** The CLI ships with rondo and depends on nothing from
  crust, satisfying the "not crust-only" ownership boundary.
- **Read-only and stateless.** Each call rebuilds the stream from the append-only
  ledger, so there is no session/connection state to manage and completed work
  is never relaunched.

## Alternatives considered

- **Remote HTTP endpoint.** Rejected: the Core surface has no remote trust or
  authentication contract.
  RON-149 accepts only the existing optional listener with strict loopback peer
  enforcement.
- **File-tail (consumer reads the NDJSON directly).** Rejected: it would force
  consumers to understand ledger paths and raw `rondo.events/v0` shapes - exactly
  the coupling RON-129 removed. The contract also forbids inferring ledger/
  artifact layout from ids.
- **Pure local BEAM API only (no CLI).** Rejected as the *first* consumer surface:
  an out-of-BEAM coordinator or a shell script could not consume it. The CLI is
  the lowest-common-denominator transport; the BEAM API remains available.

## Cursor semantics

Events are projected into one deterministically ordered sequence numbered
`1..N`. `event_cursor` is the opaque token `rondo.core/v1:<offset>` carrying the
count already consumed. `run.events` returns events after that offset plus a
`next_event_cursor`. The ledger is append-only, so the delivered prefix is
stable: a consumer tails by re-issuing `run.events` with the last
`next_event_cursor`, and replays an archived run from `initial_cursor/0`
(`rondo.core/v1:0`). Archived (completed) runs are immutable, so replay is fully
deterministic.

## Event mapping (rondo.events/v0 + manifest -> rondo.core/v1)

- `rondo.run.status_changed` <- run-ledger lifecycle: an initial `running` at
  `started_at`, plus manifest checkpoints (`interrupt_created` -> `paused`,
  `completed`/`failed`/`terminated`), with a deterministic backfill from
  `finished_at` for older ledgers that lack a terminal checkpoint.
- `rondo.run.evidence_recorded` <- the manifest artifact catalog (RON-128
  `Rondo.RunEvidence.ArtifactCatalog`) unioned with artifact-linked events from
  the `rondo.events/v0` stream (RON-129 seam), deduped by `uri`. Evidence is
  exposed only as run-scoped `rondo-run://` pointers. Unsafe, absolute, or
  oversized source paths degrade to bounded opaque hashes, so consumers never
  infer ledger/workspace layout.
- `rondo.service.status_changed` <- a run-scoped `running` marker at run start.
  Full service lifecycle is `service.status` territory, out of `run.events`
  scope; this keeps at least one event of each contract family available.

Every emitted event carries `type`, `sequence`, `timestamp`, and a `namespace`
block plus the contract-required fields for its family, which is sufficient
namespace and time context for deterministic display/replay.
