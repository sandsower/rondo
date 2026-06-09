# RON-10 Delivery Artifact Execution Envelope v0

## Envelope Metadata

- **Schema:** `execution-envelope-v0`
- **Envelope ID:** `ron-10-delivery-artifact-v0`
- **Source ticket:** RON-27
- **Target implementation ticket:** RON-10 — "[GH #60] [P1] Add output bundle / delivery artifact for completed runs"
- **Status:** approved for AFK implementation of RON-10
- **Created:** 2026-06-09
- **Owning component:** Rondo
- **Related source plan:** `execution-envelope-v0` Phase 4 / Rondo delivery artifact envelope

## Goal

Implement Rondo support for a predictable completed-run delivery artifact that packages the reviewable output of a run without requiring humans, Beislið, or future reconciliation tooling to scrape logs.

The artifact must make completed Rondo runs consumable by:

- a human reviewing what happened,
- Beislið reconciliation that needs structured run output,
- future export bundles that package run evidence for handoff.

## Ownership Boundaries

- **Rondo owns** execution state, run IDs, run ledger manifests/checkpoints, gate/proof artifact links, archive links, and the delivery artifact emitted for completed runs.
- **Beislið owns** work-contract semantics, slice planning, proof requirement semantics, and future reconciliation behavior.
- **Memento owns** curated memory and durable lessons. The delivery artifact may surface memory lesson candidates, but it must not write to Memento directly.
- **Teotl is not a dependency** for this implementation. Do not add installer/bootstrap UX, runtime services, or Teotl-specific naming in RON-10.

## RON-10 Scope

RON-10 should add a stable delivery artifact shape for completed Rondo runs.

The implementation should:

1. Emit a delivery artifact for every successfully completed run.
2. Link to proof and raw logs by path/reference instead of embedding raw proof/log content by default.
3. Allow an export bundle to include the delivery artifact.
4. Preserve backward compatibility for existing run ledgers and archives that do not have a delivery artifact yet.
5. Cover shape, redaction, portability, and backward compatibility with tests.

## Non-Goals

- Do not implement Beislið reconciliation.
- Do not write memory lessons directly to Memento.
- Do not embed raw logs, full prompts, diffs, or reasoning content by default.
- Do not redesign the run ledger, archive format, gate runner, or process provider contract beyond what is necessary to reference existing evidence.
- Do not require Beislið #58/#59 or any future slice-export work to exist.

## Delivery Artifact Contract

A completed-run delivery artifact is a structured JSON-compatible object linked from the run ledger manifest and suitable for inclusion in an export bundle.

Recommended artifact path inside a run ledger:

```text
artifacts/delivery-artifact.json
```

Recommended manifest artifact link:

```json
{
  "kind": "delivery_artifact",
  "path": "artifacts/delivery-artifact.json"
}
```

### Required Top-Level Fields

```json
{
  "schema": "rondo-delivery-artifact-v0",
  "run": {},
  "source": {},
  "summary": {},
  "outputs": {},
  "proof": {},
  "interrupts": [],
  "human_decisions": [],
  "risks": [],
  "deferred_work": [],
  "memory_lesson_candidates": [],
  "redaction": {},
  "portability": {}
}
```

### `run`

Identifies the completed Rondo attempt.

Required fields:

- `run_id` — Rondo run ledger ID.
- `status` — terminal status, expected `completed` for RON-10 emission.
- `issue` — issue snapshot with at least `id`, `identifier`, `title`, `url`, and `labels` when available.
- `started_at` — ISO-8601 timestamp when available.
- `finished_at` — ISO-8601 timestamp when available.
- `run_dir` — optional local path. Include only when useful for local operators; see portability rules.

Example:

```json
{
  "run_id": "RON-10-20260609T120000Z-a1b2c3d4",
  "status": "completed",
  "issue": {
    "id": "bb18d57a-3bc7-436b-991b-b1bca9658b88",
    "identifier": "RON-10",
    "title": "[GH #60] [P1] Add output bundle / delivery artifact for completed runs",
    "url": "https://linear.app/teotl/issue/RON-10/gh-60-p1-add-output-bundle-delivery-artifact-for-completed-runs",
    "labels": ["Feature"]
  },
  "started_at": "2026-06-09T12:00:00Z",
  "finished_at": "2026-06-09T12:15:00Z"
}
```

### `source`

Pins the input contract or envelope that caused the run.

Required fields:

- `contract_schema` — source schema name when available, such as `rondo-execution-request-v1`, `approved-slice-v1`, or `linear-ticket`.
- `contract_id` — slice ID, issue identifier, or stable source ID.
- `contract_path` — local manifest path when the run came from a manifest.
- `contract_sha256` — SHA-256 of the exact source manifest/envelope when available.
- `envelope_schema` — optional, e.g. `execution-envelope-v0`.
- `envelope_id` — optional, e.g. `ron-10-delivery-artifact-v0`.
- `envelope_sha256` — optional SHA-256 of the approved execution envelope when available.
- `parent_contract` — optional parent contract metadata preserved from existing `source_contract` metadata.

Hash expectations:

- If Rondo runs from a local execution-request manifest, copy existing `source_contract.sha256` into `source.contract_sha256`.
- If a future runner passes an approved execution envelope, record the envelope schema/id/hash in the envelope fields.
- If no hash exists, set the hash field to `null` rather than inventing a value.

### `summary`

Human-readable completed-run outcome without requiring log scraping.

Required fields:

- `title` — short completion title.
- `status` — summary status, expected `completed`.
- `final_report` — sanitized final report or concise completion summary when available.
- `changed_files` — list of changed file paths when available.
- `commits` — list of local or pushed commit SHAs when available.
- `verification_summary` — brief proof outcome summary.

The `final_report` must be safe to display in Linear, terminal dashboards, and export bundles. It must not include full prompts, secret-bearing values, raw diffs, or private chain-of-thought/reasoning content.

### `outputs`

Links to artifacts created by the run.

Recommended fields:

- `branch` — branch name used for the run.
- `pr` — PR URL/number/state when available.
- `patch` — relative path to patch artifact when available.
- `archive` — bundle-relative archive path when the archive is included in the bundle; omit, redact, or mark local-only rather than copying absolute local paths into portable artifacts.
- `run_ledger_manifest` — usually `manifest.json` relative to the run directory.
- `agent_events` — relative path to sanitized agent event NDJSON when available.
- `export_bundle` — export bundle path when available.

Paths inside the run ledger should be relative to `run_dir` by default so bundles remain portable. Absolute local filesystem paths may appear in existing run-ledger archive links, but the delivery artifact must not claim normal portability for those links. If an absolute path cannot be rewritten into the bundle, either omit/redact it or set `portability.requires_local_workspace: true` with a clear note.

### `proof`

Summarizes proof status and links to evidence.

Required fields:

- `status` — `pass`, `fail`, `timeout`, `error`, `skipped`, or `unknown`.
- `requirements` — proof requirement summaries when available.
- `gate_results` — list of gate result references.
- `review` — optional clean-eval/review links or statuses when available.

Gate result references should link to existing structured artifacts, for example:

```json
{
  "name": "elixir-ci",
  "status": "pass",
  "results_path": "artifacts/gates/turn-0001/results.json",
  "stdout_path": "artifacts/gates/turn-0001/0001-elixir-ci-stdout.log",
  "stderr_path": "artifacts/gates/turn-0001/0001-elixir-ci-stderr.log"
}
```

The delivery artifact should not embed raw stdout/stderr by default.

### `interrupts`

Records any human interrupts that occurred during the run.

Each interrupt should include:

- `reason`
- `state`
- `question`
- `selected_response` when resolved
- `resume` seeds when available
- `artifact_paths` for gate or policy evidence when available

Completed runs with no interrupts should use an empty list.

### `human_decisions`

Records explicit human approvals/declines that affected the run, including action-policy `ask` outcomes.

Each decision should include:

- `action`
- `classes`
- `decision`
- `human_outcome`
- `side_effect_status`
- `timestamp` when available

Do not include secrets, auth headers, raw command output, or unredacted policy payloads.

### `risks`

Lists known residual risks at completion.

Each risk should include:

- `id`
- `severity` — `low`, `medium`, `high`, or `unknown`
- `description`
- `mitigation` or `follow_up`

Use an empty list when no risks are known.

### `deferred_work`

Lists intentionally deferred follow-up.

Each item should include:

- `description`
- `reason`
- `suggested_ticket` or `related_ticket` when available

Do not hide required acceptance work here. Deferred work is for accepted non-goals or follow-up outside the approved envelope.

### `memory_lesson_candidates`

Lists possible durable learning candidates for a separate Memento flow.

Each candidate should include:

- `title`
- `why_it_matters`
- `evidence_path` when available

Rondo must not write these directly to Memento as part of RON-10.

### `redaction`

Describes redaction behavior applied to the artifact.

Required fields:

- `policy` — short policy name or `rondo-delivery-artifact-v0-default`.
- `raw_logs_embedded` — expected `false` by default.
- `secret_fields_redacted` — expected `true`.
- `content_fields_summarized` — expected `true` for prompts, diffs, full messages, and raw outputs.
- `notes` — optional human-readable caveats.

The artifact should follow existing Rondo run-ledger sanitizer intent: secret-looking keys and content-heavy keys are redacted or summarized unless explicitly safe.

### `portability`

Documents whether the artifact can be moved outside the original workspace.

Required fields:

- `path_base` — `run_dir` for relative run-ledger paths.
- `uses_relative_paths` — expected `true` for bundled artifacts.
- `requires_local_workspace` — `false` for normal review, `true` only for paths that cannot be bundled.
- `external_links` — list of Linear/GitHub/PR URLs when available.
- `bundle_notes` — instructions for export bundle inclusion.

## Example Delivery Artifact

```json
{
  "schema": "rondo-delivery-artifact-v0",
  "run": {
    "run_id": "RON-10-20260609T120000Z-a1b2c3d4",
    "status": "completed",
    "issue": {
      "id": "bb18d57a-3bc7-436b-991b-b1bca9658b88",
      "identifier": "RON-10",
      "title": "[GH #60] [P1] Add output bundle / delivery artifact for completed runs",
      "url": "https://linear.app/teotl/issue/RON-10/gh-60-p1-add-output-bundle-delivery-artifact-for-completed-runs",
      "labels": ["Feature"]
    },
    "started_at": "2026-06-09T12:00:00Z",
    "finished_at": "2026-06-09T12:15:00Z"
  },
  "source": {
    "contract_schema": "linear-ticket",
    "contract_id": "RON-10",
    "contract_path": null,
    "contract_sha256": null,
    "envelope_schema": "execution-envelope-v0",
    "envelope_id": "ron-10-delivery-artifact-v0",
    "envelope_sha256": null,
    "parent_contract": null
  },
  "summary": {
    "title": "Delivery artifact support implemented",
    "status": "completed",
    "final_report": "Added completed-run delivery artifact generation and linked it from the run ledger manifest.",
    "changed_files": [
      "lib/rondo/run_ledger.ex",
      "test/rondo/run_ledger_test.exs",
      "docs/run_ledger.md",
      "README.md"
    ],
    "commits": [],
    "verification_summary": "elixir-ci passed"
  },
  "outputs": {
    "branch": "vic/ron-10-gh-60-p1-add-output-bundle-delivery-artifact-for-completed",
    "pr": null,
    "patch": null,
    "archive": "artifacts/archive/run.json",
    "run_ledger_manifest": "manifest.json",
    "agent_events": "artifacts/agent-events.ndjson",
    "export_bundle": null
  },
  "proof": {
    "status": "pass",
    "requirements": [
      {
        "id": "elixir-ci",
        "kind": "command_gate",
        "command": "cd elixir && make all"
      }
    ],
    "gate_results": [
      {
        "name": "elixir-ci",
        "status": "pass",
        "results_path": "artifacts/gates/turn-0001/results.json"
      }
    ],
    "review": null
  },
  "interrupts": [],
  "human_decisions": [],
  "risks": [],
  "deferred_work": [],
  "memory_lesson_candidates": [],
  "redaction": {
    "policy": "rondo-delivery-artifact-v0-default",
    "raw_logs_embedded": false,
    "secret_fields_redacted": true,
    "content_fields_summarized": true,
    "notes": "Raw logs are linked by artifact path rather than embedded."
  },
  "portability": {
    "path_base": "run_dir",
    "uses_relative_paths": true,
    "requires_local_workspace": false,
    "external_links": [
      "https://linear.app/teotl/issue/RON-10/gh-60-p1-add-output-bundle-delivery-artifact-for-completed-runs"
    ],
    "bundle_notes": "Include delivery-artifact.json plus referenced relative artifact paths when creating a handoff bundle."
  }
}
```

## Implementation Guidance for RON-10

Recommended minimal implementation path:

1. Add a delivery artifact builder near the existing run-ledger boundary, either in `Rondo.RunLedger` or a small focused module called by it.
2. Write `artifacts/delivery-artifact.json` when a run completes successfully.
3. Link the artifact from `manifest.json` using `kind: "delivery_artifact"`.
4. Reuse existing manifest, checkpoint, gate, archive, and sanitized agent-event data; do not invent a second source of truth.
5. Keep old manifests valid. Readers should tolerate missing delivery artifacts.
6. Treat existing absolute archive links as local-only unless they are rewritten into bundle-relative paths; never leak absolute workspace paths in an artifact that claims `requires_local_workspace: false`.
7. Update `elixir/docs/run_ledger.md`, `elixir/README.md`, and `SPEC.md` where behavior changes meaningfully.

Suggested tests for RON-10:

- completed run writes `artifacts/delivery-artifact.json` and links it from the manifest,
- artifact shape includes required top-level sections,
- source contract metadata and hashes are copied when present,
- raw logs are linked, not embedded,
- secret/content-heavy fields are redacted or summarized,
- existing ledgers without delivery artifacts still load,
- existing absolute archive links are either rewritten to bundled relative paths or marked/omitted as local-only,
- export bundle includes the delivery artifact when export bundling is implemented or already present.

## Acceptance Mapping

RON-27 acceptance:

- **RON-10 can be implemented AFK from the envelope.**
  - This document defines the artifact fields, source/hash expectations, proof references, redaction/portability rules, and implementation/test guidance needed for RON-10.
- **The envelope stays self-contained and does not require Beislið #58/#59 to exist.**
  - The contract uses existing Rondo run ledger/source contract data and optional future envelope fields. Missing future Beislið fields are represented as `null` rather than blockers.

RON-10 acceptance supported by this envelope:

- **Every completed run can emit a delivery artifact.**
  - Emit `artifacts/delivery-artifact.json` on successful completion and link it from the manifest.
- **Artifact links to proof rather than embedding raw logs by default.**
  - Use `proof.gate_results[*].*_path` references and keep `redaction.raw_logs_embedded: false`.
- **Export bundle can include it.**
  - Keep paths relative to `run_dir` and document bundle inclusion in `portability.bundle_notes`.
- **Tests cover shape, redaction, and backward compatibility.**
  - Suggested test list above covers required behavior.

## AFK Pause Conditions for RON-10

Pause and ask for human guidance if any of these occur:

- Existing run-ledger data cannot supply required fields and there is no safe `null` fallback.
- Adding the artifact would require embedding raw logs, full prompts, raw diffs, or secret-bearing values by default.
- Implementation would require Beislið #58/#59, Teotl behavior, or Memento writes.
- Backward compatibility for existing manifests would be broken.
- Configured proof cannot pass after the normal bounded retry/fix loop.

## Approval

This envelope is approved as the implementation boundary for RON-10. RON-10 may implement within this contract without further product steering, pausing only on the AFK pause conditions above.
