# RON-19 — Event JSONL, patch, and final-report artifact contract

Ticket: Linear RON-19 / GH sandsower/rondo#23 (P1)

## Goal

Make Rondo runs comparable across agent adapters by adding three contract-stable
artifacts to the existing run ledger:

1. **Normalized event JSONL** — `artifacts/agent-events.ndjson` lines carry an
   explicit `"schema": "rondo.events/v0"` and a stable normalized shape.
2. **Patch artifact** — `artifacts/changes.patch` (git diff) plus
   `artifacts/patch.json` metadata (`rondo.patch/v0`) captured for completed
   runs with local workspace changes, for later clean evaluation (GH#24).
3. **Final report** — schema-constrained `rondo.final_report/v0` report
   extracted from the adapter's final report, validated, persisted to
   `artifacts/final-report.json`, with invalid/missing reports classified
   distinctly from task/code failures in the ledger.

Plus: conservative deny-list secret redaction applied to all persisted
events/checkpoints/manifest strings, and manifest linkage for every artifact.

## Findings from exploration

- RON-10 "delivery artifact" landed only as an **envelope plan doc**
  (`docs/plans/2026-06-09-ron-10-delivery-artifact-execution-envelope.md`);
  there is no delivery-artifact code yet. The merged artifact system to extend
  is `Rondo.RunLedger` (manifest, checkpoints, `artifacts/agent-events.ndjson`,
  `link_artifacts/2`, sanitizers) and the `Rondo.RunOnce` integration path.
- Adapter events are already normalized by `Rondo.Agent.Adapter` and forwarded
  as `{:claude_worker_update, issue_id, update}` maps containing
  `event/adapter/run_ref/session_id/usage/capabilities/final_report/diff_source/raw`.
- `mix.exs` enforces 100% test coverage for non-ignored modules; `RunLedger`
  is covered, `RunOnce`/`Orchestrator` are coverage-ignored but tested.
- Gates: `cd elixir && make all` (fmt-check, specs.check + credo --strict,
  coverage, dialyzer).

## Design

### New modules

- `Rondo.Redaction` — pure string redaction with a deny-list of secret-shaped
  patterns (sk-/sk-ant- keys, bearer tokens, GitHub `ghp_`/`github_pat_`
  tokens, Slack `xox*`, AWS `AKIA…`, private-key markers, `KEY=value`
  assignments for secret-named keys) plus redaction of current env values
  whose variable names look secret (>= 8 bytes). Replacement: `[REDACTED]`.
- `Rondo.FinalReport` — `extract/1` (map, raw JSON string, or fenced
  ```json block inside the final report text) and `validate/1` against
  `rondo.final_report/v0`: required `schema`, `summary` (non-empty string),
  `changed_files` (list of strings), `gates_run` (list), `failures` (list),
  `risks` (list), `next_state` (non-empty string). Returns
  `{:ok, report}`, `{:error, :missing}`, or `{:error, {:invalid, errors}}`.
- `Rondo.PatchArtifact` — `capture/2` runs git in the run workspace:
  `status --porcelain` → no changes → `:no_changes`; otherwise
  `git add --intent-to-add .`, `git diff --binary <base_ref>`, `git reset -q`,
  writes `artifacts/changes.patch` + `artifacts/patch.json`
  (schema `rondo.patch/v0`, `base_ref`, `base_branch`, `format: "git-diff"`,
  `includes_untracked: true`, `captured_at`, `changed_paths`), links both from
  the manifest (`kind: "patch"`, `kind: "patch_metadata"`). Skips cleanly when
  the workspace is missing, not a git repo, or has no commits. Accepts a
  `:runner` opt for failure-injection tests.

### RunLedger changes

- `agent_event_payload/2` emits `"schema" => "rondo.events/v0"` plus
  `adapter` and `run_ref` fields (sanitized) alongside existing
  `timestamp/event/session_id/usage/raw`.
- `cap_string/1` routes through `Rondo.Redaction.redact/1` so every persisted
  string (manifest, checkpoints, events) is redacted before write.
- `record_final_report/2`: extract+validate, persist valid reports to
  `artifacts/final-report.json`, link `kind: "final_report"`, write a
  `final_report_validated` checkpoint, and stamp the manifest with
  `"final_report" => %{"status" => "valid"|"invalid"|"missing", ...}` and
  `"failure_classification"` (`"final_report_missing"`/`"final_report_invalid"`)
  for non-valid reports.
- `complete_run/4` stamps `"failure_classification" => "task_failure"` for
  non-completed terminal statuses (distinct from final-report classifications).

### RunOnce integration

After the agent run and queued-update recording, when the agent result is
`:ok`: capture the patch artifact and record/validate the final report (taken
from the last update carrying `final_report`). Errors in artifact capture are
logged, never fatal. Terminal run status semantics are unchanged.

## Decisions made AFK

- RON-10 delivery-artifact *code* does not exist on main (only its envelope
  doc); extended the existing RunLedger/RunOnce artifact system as the ticket
  pre-approval intends. No parallel artifact system created.
- Final-report enforcement is **classification, not status flipping**: a
  completed run with missing/invalid report stays `status: "completed"` but
  gets `failure_classification: "final_report_missing"|"final_report_invalid"`
  in the manifest plus a `final_report_validated` checkpoint. Code/task
  failures get `failure_classification: "task_failure"`. This keeps existing
  run semantics and tests stable while satisfying the distinct-classification
  acceptance criterion.
- Patch content is **not** redacted (a redacted patch is unusable for clean
  evaluation); the patch is workspace code authored by the run. Redaction
  applies to events/checkpoints/manifest/final-report strings.
- Patch capture uses `git add --intent-to-add .` + `git diff --binary <base_ref>` +
  `git reset -q` to include untracked file contents; this mutates the (already
  terminal) run workspace index only. `<base_ref>` is resolved from
  `manifest.repo.base_commit` (the run-start base commit) or falls back to
  capture-time `HEAD`.
- JSONL lines carry no per-line `seq`; ordering is line order (append-only),
  avoiding a signature change to `append_agent_event/3`.
- Final-report validation and patch capture are wired into both the `RunOnce`
  path (AFK/envelope runner) and the `Orchestrator` path. In the orchestrator,
  `finalize_run_ledger_artifacts/3` (on `:completed`) calls
  `record_run_ledger_final_report/2`, which delegates to
  `RunLedger.record_final_report/2` (uses `FinalReport.extract` to parse/extract,
  persists `final_report`, and writes the `:final_report_validated` checkpoint
  with `status: valid|invalid|missing` plus `failure_classification`). All runs
  gain JSONL schema, redaction, and `task_failure` classification via RunLedger.
- Prompt templates are user-configurable workflow data; not modified. The
  extractor accepts raw JSON or fenced ```json blocks so adapters/envelopes
  can instruct agents to emit the report.
- Env-value redaction reads `System.get_env/0` per redaction call (small
  payloads); tests inject env via an option.

## Test plan

- `redaction_test.exs` — each pattern, env-value redaction, non-secrets pass
  through, short/benign env values ignored.
- `final_report_test.exs` — valid map/raw JSON/fenced block, invalid schema /
  missing fields / wrong types with error details, missing (nil/prose/empty).
- `patch_artifact_test.exs` — captured patch for modified+untracked files,
  patch applies to a clean checkout at `base_ref`, metadata fields, manifest
  links, no-changes / missing-workspace / non-git / no-commit skips, runner
  failure error.
- `run_ledger_test.exs` — events JSONL: schema field, JSONL validity, secret
  redaction; `record_final_report` valid/invalid/missing manifest + artifact;
  `complete_run` failure classification.
- `run_once_test.exs` — end-to-end: completed run produces patch artifact and
  final-report validation results in the manifest; malformed report yields
  `final_report_invalid` classification while remaining completed.

## Gates

`cd elixir && make all` (fmt-check, lint, 100% coverage, dialyzer).

## Status log

- 2026-06-10: explored codebase, wrote plan.
- 2026-06-10: implemented `Rondo.Redaction`, `Rondo.FinalReport`,
  `Rondo.PatchArtifact`, RunLedger v0 event schema + final-report recording +
  failure classification, RunOnce artifact finalization, and docs.
  Full suite: 436 tests, 0 failures, 100% coverage. fmt-check + lint clean.
