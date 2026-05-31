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
- workspace root and expected workspace path
- tracker and agent adapter names
- agent/Claude mode settings
- timestamps
- checkpoint index
- artifact links
- pending human interrupt payload when the status is `paused`

Checkpoint and built-in artifact paths are relative to `run_dir`. Archive links may point at the existing archive location outside the ledger.

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
- `interrupt_created`
- `completed`
- `failed`
- `terminated`

Ledger write failures are logged as warnings and do not stop the run.

## Agent event artifact

`artifacts/agent-events.ndjson` stores sanitized agent event summaries. Values are size-capped and secret-looking keys are redacted. Usage token counts are preserved, but full prompts, file contents, auth headers, cookies, API keys, and secret-looking values should not be treated as captured source of truth.

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
