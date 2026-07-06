# Proposed teotl conformance assets for the rondo.core/v1 run event feed (RON-166)

These files are the **proposed content** for the teotl conformance home at
`teotl/conformance/execution/`. They are authored here inside the rondo worktree
because the teotl repo is out of RON-166's write scope. A human should place them
under `teotl/conformance/execution/` (merging with the existing seed assets).

## What is here

- `schemas/rondo-core-run-events-v1.schema.json` - a JSON Schema for the
  `run.events` response payload and the three `rondo.core/v1` event families
  (`rondo.service.status_changed`, `rondo.run.status_changed`,
  `rondo.run.evidence_recorded`). This complements the existing
  `rondo-core-service-v1.schema.json`, which describes the *contract descriptor*;
  this new schema describes the *event payloads a consumer actually receives*.
- `fixtures/run-events-archived-replay.json` - a full `run.events` response
  captured from a completed (archived) run replayed from the zero cursor. Shows
  one event of every family and the `next_event_cursor`.
- `fixtures/run-events-resume.json` - the same run resumed from
  `event_cursor: "rondo.core/v1:2"`, showing that a cursor returns exactly the
  tail and that re-reading an immutable archived run is deterministic.
- `fixtures/run-status.json` - a `run.status` response for the same run.

The fixtures were produced by the reference implementation (`mix rondo.run_events`
over `Rondo.Core.EventFeed`) and then given a canonical `run_id`
(`RUN-sample-0001`) and `repo_id` (`sample-repo`) so they are stable conformance
inputs.

## Suggested conformance check

The first authoritative runner (per `contracts/execution.md`) should:

1. Start an isolated rondo core, submit a minimal run, let it finish.
2. Call `run.events` from the zero cursor and validate every event against
   `rondo-core-run-events-v1.schema.json`.
3. Assert exactly one event of each of the three families is present, that
   `next_event_cursor` matches `^rondo\.core/v1:\d+$`, and that resuming from a
   mid cursor returns the correct tail (matching `run-events-resume.json`'s
   shape) without relaunching the run.
4. Confirm no `uri` leaks an absolute workspace/ledger path (run-scoped
   `rondo-run://` pointers only, or `file://` for pre-absolute artifacts).
