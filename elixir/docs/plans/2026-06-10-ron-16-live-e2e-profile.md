# RON-16 — Opt-in live E2E profile for Linear + Claude

Ticket: Linear RON-16 / GH sandsower/rondo#15

## Goal

One command (`make e2e`) that proves the full production path — Linear fetch, workspace
prep, Claude subprocess, tracker state transition, cleanup — against a disposable Linear
issue in a dedicated test team/project. Skipped by default with a clear reason; never on
in CI.

## Design

### Gating

- New ExUnit tag `:live_e2e`, excluded by default in `test/test_helper.exs`
  (`ExUnit.configure(exclude: [:live_e2e])`), so `mix test` / `make test` / CI never run it.
- `make e2e` runs `mix test --only live_e2e`. The test module checks
  `RONDO_RUN_LIVE_E2E=1` at compile time; when unset the module is tagged
  `skip: <clear reason>` so the run reports a visible skip reason instead of failing.

### Orchestration helper (unit-testable)

`Rondo.LiveE2E` in `test/support/live_e2e.exs` (loaded from `test_helper.exs`, added to
`test_ignore_filters` in `mix.exs` like the other support files). All Linear access goes
through an injectable `graphql` function defaulting to `Rondo.Linear.Client.graphql/2`,
i.e. it reuses rondo's existing Linear config plumbing (api key resolution, endpoint,
logging) rather than a parallel client.

Responsibilities:

- `enabled?/0`, `skip_reason/0` — gate plumbing.
- `load_context/1` — validates required env (`LINEAR_API_KEY` real, `RONDO_E2E_LINEAR_TEAM`
  team key, `RONDO_E2E_LINEAR_PROJECT` project name) plus optional knobs
  (`RONDO_E2E_CLAUDE_COMMAND`, `RONDO_E2E_CLAUDE_MAX_TURNS`,
  `RONDO_E2E_ACTION_POLICY_COMMAND`). Errors list every missing variable.
- `resolve_team/2` — team by key; returns id + workflow states; requires a `Todo`-typed
  start state and an `In Progress` state (RunOnce transitions literally to "In Progress").
- `resolve_project/2` — project by name; returns id + `slugId` (used as
  `tracker.project_slug`, matching the client's `project.slugId` poll filter by
  construction).
- `create_issue/2` — `issueCreate` with title prefix `[rondo-e2e]`, explicit start
  stateId, marker-file task description.
- `fetch_issue_state/2` — current state name for post-run assertion.
- `cleanup_issue/2` — best-effort `issueDelete` (Linear trash), logs failures, never raises.

All error tuples carry enough context (operation, response body) to debug tracker issues.

### Live test

`test/e2e/live_linear_claude_e2e_test.exs`, `async: false`, `@moduletag :live_e2e`,
10-minute timeout. Uses `Rondo.TestSupport` (per-test temp WORKFLOW.md + env restore),
then rewrites the workflow file with live values:

- tracker: linear, `api_key: "$LINEAR_API_KEY"`, `project_slug` = resolved test project slugId
- workspace root: unique tmp dir; `after_create` hook `git init --quiet .`
- claude: real `claude` command (overridable), small max_turns
- action_policy: TestSupport's fake allow-all evaluator by default
  (`RONDO_E2E_ACTION_POLICY_COMMAND` to use a real `beislid`)
- prompt: create `rondo_e2e_marker.txt` with a known content line, do not touch Linear,
  stop immediately after

Flow: create disposable issue (on_exit: delete issue + remove workspace, best-effort,
logged) → `Rondo.RunOnce.run(issue_uuid)` in-process → assert `:ok`, marker file content,
and tracker state == "In Progress". Assertions embed issue URL, workspace path, and run
result for debuggability. Nothing reads or writes the normal rondo project: the tracker
project_slug filter scopes all queries to the configured test project.

### Unit/fixture tests (run by default)

`test/rondo/live_e2e_support_test.exs` — covers env validation, team/project resolution
(including missing-state and not-found errors), issue create/fetch/cleanup against
fixture graphql funs, cleanup logging on failure, and gating helpers.

### Docs

README gets a "Live end-to-end test (opt-in)" subsection under Testing: required env
vars, what the test mutates (one trashed `[rondo-e2e]` issue in the test project, temp
workspace), cleanup behavior, and the manual invocation.

## Decisions made AFK

1. Disposable resource = a single issue in a pre-existing test team/project (env-provided),
   not a generated project: project creation/deletion is heavier and Linear project
   deletion is more destructive; an issue in a dedicated test project is fully scoped.
2. Reuse `Rondo.Linear.Client.graphql/2` for all sandbox calls — per ticket instruction to
   reuse existing Linear plumbing.
3. Default the action-policy evaluator to TestSupport's fake allow-all script so the live
   profile exercises Linear+Claude without requiring a beislid install; opt into the real
   evaluator with `RONDO_E2E_ACTION_POLICY_COMMAND=beislid`.
4. Cleanup uses `issueDelete` (moves to Linear trash, recoverable) rather than archive —
   clearer "disposable" semantics, still non-destructive.
5. Helper lives in `test/support` (coverage-ignored like existing support), not `lib`,
   so no production module ships for a test-only concern; it is still fully unit-tested.
6. The live run was NOT executed against real credentials (explicitly deferred to the
   human per the execution envelope). Verified: default skip path, `--only live_e2e`
   skip-with-reason path, and all sandbox logic via fixture tests.

## Verification

- `make all` (fmt-check, credo --strict, coverage 100% threshold, dialyzer)
- `mix test` shows live test excluded by default
- `RONDO_RUN_LIVE_E2E` unset + `mix test --only live_e2e` → skipped with printed reason
- Live run: deferred to human (documented in README)
