# Run Ledger

Rondo writes a durable run ledger for each dispatched issue attempt. The ledger is local diagnostic state that lets operators inspect a running, paused, completed, failed, or terminated run from disk without the orchestrator process.

## Layout

Ledgers live under the configured `workspace.root`:

```text
<workspace.root>/.rondo_runs/<issue_identifier>/<run_id>/
  manifest.json
  checkpoints/
    0001-dispatch.json
    0002-spawned.json
    ...
  artifacts/
    agent-events.ndjson
    delivery-artifact.json
    gates/
      turn-0001/
        results.json
        0001-unit-stdout.log
        0001-unit-stderr.log
```

`run_id` is generated per dispatch attempt using the safe issue identifier, a UTC timestamp, and a short random suffix:

```text
<safe_identifier>-<YYYYMMDDThhmmssZ>-<random>
```

If `workspace.root` points at a temporary directory, ledgers are ephemeral with that directory.

## Manifest

`manifest.json` is the entry point. It records:

- schema version and `run_id`
- run status: `running`, `paused`, `completed`, `failed`, or `terminated`
- absolute `run_dir`
- ticket snapshot: id, identifier, title, description, state, URL, labels, and priority
- optional `source_contract` metadata for local execution-request / approved-slice manifest runs
- workspace root, expected workspace path, and the run-start `base_commit`/`base_branch` (or `null` when the workspace is not a git repository at run start)
- tracker and agent adapter names
- agent/Claude mode settings
- timestamps
- checkpoint index
- artifact links
- `final_report` validation block and `failure_classification` when recorded (see below)
- completed-run delivery artifact link (`kind: delivery_artifact`) when emitted
- pending human interrupt payload when the status is `paused`

Checkpoint and built-in artifact paths are relative to `run_dir`. Archive links may point at the existing archive location outside the ledger.

For `run-once --manifest` runs, `source_contract` records manifest provenance and planning metadata such as `schema`, `slice_id`, absolute manifest `path`, `sha256`, `parent_contract`, `repo`, `allowed_actions`, `process_provider`, `memory_provider`, and `output_expectations`. The manifest prompt/body is rendered into the issue description snapshot; the source contract block stays metadata-focused.

A paused manifest includes an `interrupt` object with a stable reason, state, exact question, options, recommendation, gate evidence, and resume seeds such as run ID/path, workspace path, session ID, run reference when available, retry attempt, and gate artifact paths. Paused runs are discovered at orchestrator startup by scanning `.rondo_runs/*/*/manifest.json` for `status: "paused"` so they remain excluded from redispatch without relying on chat/session context.

## Checkpoints

Rondo writes checkpoint files incrementally as lifecycle transitions happen. Checkpoints are separate JSON files so partial run history is inspectable even before the process exits.

Current checkpoint kinds include:

- `dispatch`
- `spawned`
- `workspace_ready`
- `turn_started`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `edit_batch`
- `gates_completed`
- `final_report_validated`
- `patch_secret_scan`
- `interrupt_created`
- `completed`
- `failed`
- `terminated`

Ledger write failures are logged as warnings and do not stop the run.

## Agent event artifact

`artifacts/agent-events.ndjson` stores sanitized agent event summaries as JSONL. Each line is a `rondo.events/v0` object with a stable key set:

```json
{
  "schema": "rondo.events/v0",
  "timestamp": "2026-06-10T12:00:00Z",
  "event": "invocation_completed",
  "adapter": "claude_code",
  "run_ref": {"adapter": "claude_code", "provider_ref": "…", "provider_ref_kind": "session_id", "resumable?": true},
  "session_id": "…",
  "usage": {"input_tokens": 1},
  "accounted_usage": {"input_tokens": 1},
  "raw": {}
}
```

`usage` is the raw provider-normalized event payload. `accounted_usage`, when present, is the spend Rondo counted for that event after adapter-specific normalization. For Pi, repeated/cumulative snapshots keep the raw `usage` value but `accounted_usage` only includes the positive delta so dashboard and billing-style totals do not sum the same snapshot repeatedly.

Values are size-capped, secret-looking keys are redacted, and all persisted strings additionally pass through the `Rondo.Redaction` deny-list (API-key shapes, bearer/GitHub/Slack/AWS tokens, private-key blocks, secret-named assignments, and values of secret-named environment variables). Usage token counts are preserved, but full prompts, file contents, auth headers, cookies, API keys, and secret-looking values should not be treated as captured source of truth.

## Patch artifact

For completed runs (orchestrator-driven and `run-once`) whose workspace changed during the run, Rondo captures the final diff for later clean evaluation:

- `artifacts/changes.patch` — `git diff --binary` output against the run-start `repo.base_commit` recorded in the manifest (falling back to the capture-time `HEAD` when no base commit was recorded or it is no longer resolvable), so both work the agent committed during the run and uncommitted/untracked changes (captured via intent-to-add) are included. It applies with `git apply` on a clean checkout of the recorded `base_ref`. Patch content is intentionally not redacted; a modified patch would no longer apply.
- `artifacts/patch.json` — `rondo.patch/v0` metadata: `format` (`git-diff`), `base_ref` (the commit the patch applies on), `head_ref` (workspace `HEAD` at capture time), `base_branch`, `includes_untracked`, `includes_committed`, `captured_at`, `changed_paths`, and `patch_path`.

Both files are linked from the manifest with artifact kinds `patch` and `patch_metadata`. Capture is skipped (without failing the run) when the workspace is missing, not a git repository, has no commits, or has no changes relative to the base. See `Rondo.PatchArtifact`.

Patch bytes stay byte-exact so clean-eval can apply them. Rondo still runs the deny-list scanner over the captured patch. If a hit is found, the patch is not rewritten; the manifest records `failure_classification: patch_contains_secret`, writes a `patch_secret_scan` checkpoint, marks the patch artifact `exportable: false`, and suppresses delivery-artifact emission/export inclusion for that run.

## Final report artifact

Completed runs (orchestrator-driven and `run-once`) validate the adapter's final report against the `rondo.final_report/v0` schema (`Rondo.FinalReport`). The report is a JSON object — the whole final report string or a fenced ```json block (the first candidate that validates wins; the last fenced block is preferred when several validate) — with required fields `schema`, `summary`, `changed_files`, `gates_run`, `failures`, `risks`, and `next_state`.

Validation writes a `final_report_validated` checkpoint and a manifest `final_report` block with `status` `valid`, `invalid`, or `missing` plus validation `errors`. Valid reports are persisted (sanitized) to `artifacts/final-report.json` and linked with artifact kind `final_report`.

Invalid or missing reports are a distinct failure classification from task/code failures: the manifest `failure_classification` field is `final_report_invalid` or `final_report_missing` for completed runs with bad reports, and `task_failure` for runs that terminate with status `failed`.

## Delivery artifact

Successfully completed runs emit `artifacts/delivery-artifact.json` and link it from the manifest with artifact kind `delivery_artifact`. The schema is `rondo-delivery-artifact-v0` and includes these top-level sections: `run`, `source`, `summary`, `outputs`, `proof`, `interrupts`, `human_decisions`, `risks`, `deferred_work`, `memory_lesson_candidates`, `redaction`, and `portability`.

The delivery artifact is a consumable handoff summary for humans and Beislið reconciliation. It links to existing proof artifacts (gate results, stdout/stderr paths, clean-eval result path, final-report path, patch path when safe) instead of embedding raw logs or diffs. Paths are run-dir-relative by default so a future export bundle can include `delivery-artifact.json` plus referenced relative artifacts. Absolute archive links are treated as local-only and omitted from portable outputs while setting `portability.requires_local_workspace: true`.

Runs classified as `patch_contains_secret` do not emit a delivery artifact; the byte-exact patch remains available locally for clean-eval but is blocked from delivery/export inclusion.

## Gate artifacts

When workflow gates are configured, Rondo stores structured gate summaries and raw command output under `artifacts/gates/`. Agent-turn gate runs are namespaced by turn, for example `artifacts/gates/turn-0001/results.json`, so later continuation turns do not overwrite earlier evidence.

Gate artifact links use these kinds in the manifest:

- `gate_results` for the structured JSON summary
- `gate_stdout` for a gate command's raw stdout log
- `gate_stderr` for a gate command's raw stderr log

Each gate completion also records a `gates_completed` checkpoint with the sanitized summary payload. If configured gates fail repeatedly, Rondo preserves the first retry behavior and then creates a human interrupt on the second gate-failed attempt. The interrupt checkpoint stores the full sanitized gate summary so operators can inspect the failure before a future resume/abort/defer action.

## Archive relationship

The existing `.rondo_archive` behavior remains separate and terminal-only. When an archived run file is written, the ledger manifest links to it as an artifact so operators can correlate the two records. Paused runs are not archived as failed; they remain visible through the paused ledger manifest and observability payloads until an explicit outcome is implemented.

## Retention and privacy

V1 has no pruning or retention policy. Ledger files may include issue text, file paths, summarized tool events, session IDs, and token metadata. Treat the ledger directory as local/private diagnostic data and avoid publishing it without review.

The repository `.gitignore` excludes `.rondo_runs/` for repo-local workspace roots. If you point `workspace.root` at another repository, add the same ignore rule there.
