# Run Ledger

Rondo writes a durable run ledger for each dispatched issue attempt. The ledger is local diagnostic state that lets operators inspect a completed, failed, or terminated run from disk without the orchestrator process.

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
```

`run_id` is generated per dispatch attempt using the safe issue identifier, a UTC timestamp, and a short random suffix:

```text
<safe_identifier>-<YYYYMMDDThhmmssZ>-<random>
```

If `workspace.root` points at a temporary directory, ledgers are ephemeral with that directory.

## Manifest

`manifest.json` is the entry point. It records:

- schema version and `run_id`
- run status: `running`, `completed`, `failed`, or `terminated`
- absolute `run_dir`
- ticket snapshot: id, identifier, title, description, state, URL, labels, and priority
- workspace root and expected workspace path
- tracker and agent adapter names
- agent/Claude mode settings
- timestamps
- checkpoint index
- artifact links

Checkpoint and built-in artifact paths are relative to `run_dir`. Archive links may point at the existing archive location outside the ledger.

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
- `completed`
- `failed`
- `terminated`

Ledger write failures are logged as warnings and do not stop the run.

## Agent event artifact

`artifacts/agent-events.ndjson` stores sanitized agent event summaries. Values are size-capped and secret-looking keys are redacted. Usage token counts are preserved, but full prompts, file contents, auth headers, cookies, API keys, and secret-looking values should not be treated as captured source of truth.

## Archive relationship

The existing `.rondo_archive` behavior remains separate and unchanged. When an archived run file is written, the ledger manifest links to it as an artifact so operators can correlate the two records.

## Retention and privacy

V1 has no pruning or retention policy. Ledger files may include issue text, file paths, summarized tool events, session IDs, and token metadata. Treat the ledger directory as local/private diagnostic data and avoid publishing it without review.

The repository `.gitignore` excludes `.rondo_runs/` for repo-local workspace roots. If you point `workspace.root` at another repository, add the same ignore rule there.
