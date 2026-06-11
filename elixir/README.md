# Rondo

This directory contains the current Elixir/OTP implementation of Rondo, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Rondo is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

<img width="1920" height="1200" alt="2026-03-08-18:43:48-screenshot" src="https://github.com/user-attachments/assets/dc75a0a4-3c2f-417a-ad73-b11619ed5ada" />

## How it works

1. Polls Linear or GitHub Issues for candidate work
2. Creates an isolated workspace per issue
3. Launches Claude Code as a CLI subprocess inside the workspace
4. Sends a workflow prompt to Claude Code
5. Keeps Claude Code working on the issue until the work is done

During Claude Code sessions, Rondo also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Rondo stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents.
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Rondo's `linear_graphql` tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/sandsower/rondo.git
cd rondo/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/rondo ./WORKFLOW.md
```

For CI/CD or one-off operator runs where another system has already selected an issue, use
`run-once` to fetch exactly one visible tracker issue, run the configured agent, and exit:

```bash
mise exec -- ./bin/rondo run-once ./WORKFLOW.md --issue 123
```

`run-once` uses the same workflow file, tracker visibility/filtering, workspace lifecycle hooks, and
agent adapter as the polling service. Todo issues are transitioned to `In Progress` before the agent
runs. The command exits zero when the issue run completes and non-zero for config, tracker,
visibility/filter, workspace, or agent failures.

`run-once` can also execute a local approved-slice / execution-request manifest without fetching a
tracker issue:

```bash
mise exec -- ./bin/rondo run-once ./WORKFLOW.md --manifest ./request.json
```

P0 manifest loading accepts local JSON with `schema: "rondo-execution-request-v1"` or
`schema: "approved-slice-v1"`, plus `slice_id` and either `prompt` or `body`:

```json
{
  "schema": "rondo-execution-request-v1",
  "slice_id": "slice-123",
  "parent_contract": {"id": "plan-1", "source": "beislid"},
  "repo": {"base_ref": "main"},
  "prompt": "Implement the approved slice.",
  "boundaries": ["Do not touch billing."],
  "dependencies": [],
  "proof_requirements": ["mix test"],
  "allowed_actions": {"run_mode": "supervised-auto"},
  "process_provider": {"artifact_path": "./beislid-process.json"},
  "memory_provider": {},
  "output_expectations": {}
}
```

Manifest runs synthesize an in-memory issue from the request and record `source_contract` metadata in
the run ledger. Provider settings and allowed-action fields are recorded for provenance in this P0
slice; enforcement still comes from the configured Rondo/Beislið runtime boundaries.

## Configuration

Pass a custom workflow file path to `./bin/rondo` when starting the long-running service:

```bash
./bin/rondo /path/to/custom/WORKFLOW.md
```

If no path is passed in long-running mode, Rondo defaults to `./WORKFLOW.md`. In `run-once` mode,
pass the workflow path explicitly before `--issue`.

Optional flags:

- `--logs-root` tells Rondo to write logs under a different directory (default: `./log`)
- `--port` also starts the HTTP observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
configured agent session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
gates:
  - name: test
    command: mix test
    timeout_ms: 600000
agent:
  adapter: claude_code
  max_concurrent_agents: 10
  max_turns: 20
claude:
  command: claude
  permission_mode: default
  dangerously_skip_permissions: true
  max_turns: 50
  output_format: stream-json
# Or set agent.adapter: pi and configure:
# pi:
#   command: pi
#   turn_timeout_ms: 3600000
#   stall_timeout_ms: 300000
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

GitHub Issues can also be used as the tracker. Rondo uses the `gh` CLI, GitHub labels for
workflow state, and `gh issue comment` for basic issue comments:

```md
---
tracker:
  kind: github
  repo: "owner/repo"
  label_filter:
    - rondo
  state_label_prefix: "status:"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
workspace:
  root: ~/code/rondo-workspaces
claude:
  command: claude
---

You are working on a GitHub issue {{ issue.identifier }}.
```

For GitHub, every configured `label_filter` label is required. Rondo reads the issue workflow state
from exactly one label with the configured prefix, such as `status: Todo`; candidate polling skips
issues with no state label or multiple state labels. State transitions replace only prefixed state
labels, create the target state label if missing, and leave all other labels untouched. Native
GitHub `open`/`closed` state is used as an outer filter; label state is Rondo's workflow source of
truth. Candidate and cleanup listing uses `gh issue list --limit 1000`; repos with more matching
issues should narrow `label_filter` until a paginated adapter lands. See
[`examples/github-WORKFLOW.md`](examples/github-WORKFLOW.md) for a fuller prompt.

Notes:

- If a value is omitted or set to `null`, defaults are used. Explicit malformed values fail
  validation instead of silently falling back.
- `claude.permission_mode` controls Claude Code's permission system. Supported values: `default`,
  `plan`, `acceptEdits`, `bypassPermissions`. Default: `bypassPermissions`.
- `claude.dangerously_skip_permissions` when `true`, passes `--dangerously-skip-permissions` to
  Claude Code, bypassing all permission checks. Recommended for unattended operation when combined
  with `claude.allowed_tools` for tightening. Default: `true`.
- `claude.max_turns` caps how many back-to-back turns Claude Code will run per invocation.
  Default: `50`.
- `claude.output_format` controls output parsing. Must be `stream-json` for Rondo to parse
  usage events. Default: `stream-json`.
- `claude.model` optionally overrides the Claude model used. When unset, Claude Code uses its default.
- `claude.allowed_tools` optionally restricts which tools Claude Code may use (list of tool names).
- `claude.turn_timeout_ms` maximum wall-clock time per turn in milliseconds.
- `claude.stall_timeout_ms` maximum time without output before a turn is considered stalled.
- `agent.adapter` selects the provider adapter. Supported first-class values are `claude_code`
  (default) and `pi`.
- When `agent.adapter: pi`, `pi.command` launches `pi --mode json`; `pi.turn_timeout_ms` and
  `pi.stall_timeout_ms` mirror the Claude timeout settings. Resume uses pi `--session <id>` when a
  stable session id is available; usage/rate-limit/sandbox metadata is best-effort/degraded based on
  pi JSON-mode events.
- `action_policy.command` points to the Beislið CLI used for deterministic action-risk evaluation.
  Default: `beislid`.
- `action_policy.run_mode` selects Beislið's policy mode. Supported values: `supervised-auto` and
  `unattended-auto`. Default: `unattended-auto`.
- Beislið owns the action-policy vocabulary and decision table; Rondo enforces it at Rondo-owned
  orchestration boundaries and persists the returned envelopes in run artifacts. Claude/pi
  permission flags are useful host controls, but they are not a substitute for external policy
  enforcement. Policy `ask` decisions appear as **Needs Guidance** interruptions: Rondo pauses before
  the side effect, records the full envelope, shows a curated blocked-side-effect summary and
  deterministic suggested responses, and only auto-resumes operations with safe descriptors. V1 exact
  resume is limited to orchestrator-owned tracker transitions; shell hooks, cleanup, and destructive
  operations require manual/guidance handling unless later modeled with replay-safe descriptors.
- `process_provider.kind` selects the process/work-contract provider. Default: `native`. Supported
  values are `native` and fixture-backed `beislid`. The native provider preserves standalone
  `WORKFLOW.md` behavior for flat gates, prompts, action-policy evaluation, model hints, and run
  metadata. The Beislið provider consumes an explicit approved process artifact and maps its gate,
  guide/proof metadata, prompt context, and fixture action-policy decision onto the same boundary;
  it does not run a Beislið exporter/runtime or make Beislið required for Rondo.
- `process_provider.artifact_path` optionally points at an approved Beislið process artifact JSON
  when `kind: beislid`. For manifest runs, `source_contract.process_provider.artifact_path` takes
  precedence; `source_contract.path` is used only when that file is explicitly a Beislið process
  artifact schema.
- `process_provider.required` controls provider failure behavior. Default: `false`. Optional provider
  gate-selection failures can warn and fall back to native flat gates only when doing so does not
  ignore loaded approved required constraints; required provider failures stop the run clearly before
  agent invocation or gate execution.
- `agent.max_turns` caps how many back-to-back agent turns Rondo will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Rondo uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- Use top-level `gates` for deterministic validation commands Rondo runs after each successful
  agent turn. Gates run in the issue workspace and persist stdout/stderr plus `results.json` under
  the run ledger. The first gate failure, error, or timeout causes the run to fail/retry with gate
  evidence preserved; a repeated gate-failed retry pauses the run with a durable human interrupt
  instead of continuing automatic retries.
- Gate entries use a flat Beislið-compatible shape: `name`, `command`, and optional `timeout_ms`
  (default: 60000). Legacy flat gates default to Beislið `read`/`file.read` policy; gates that
  mutate state should declare `action_id` and `action_classes` such as `dependency.install` with
  `workspace-write`/`dependency-install`.
- Opt into post-run clean evaluation with `clean_eval.enabled: true`. After a successful run-once
  run, Rondo re-applies the run's `rondo.patch/v0` patch artifact on a pristine detached git
  worktree of the recorded base ref (created under `<workspace.root>/.rondo_clean_eval/<run_id>`
  and always removed afterwards), runs evaluator gates there, and records the outcome in the run
  ledger (`clean_eval/result.json`, gate logs under `clean_eval/gates/`, a `clean_eval_completed`
  checkpoint, and a manifest `clean_eval` pass/fail block). Patch apply failures are recorded as
  evaluator failures; runs without a patch artifact record `skipped`. Optional keys:
  `clean_eval.base_ref` overrides the patch metadata base ref, and `clean_eval.gates` (same shape
  as top-level `gates`) overrides which gates run during clean evaluation. When `clean_eval.gates`
  is absent the top-level `gates` run; an explicit `clean_eval.gates: []` means apply-only
  evaluation (pass if the patch applies cleanly). Gate timeouts are recorded as environment
  errors, not evaluator failures.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- `tracker.repo` is required for `tracker.kind: github` and uses `owner/repo` syntax.
- `tracker.state_label_prefix` defaults to `status:` for GitHub label-emulated workflow states.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `claude.command` and `pi.command` stay shell command strings and any `$VAR` expansion there
  happens in the launched shell on Unix-like hosts. Quoted commands and wrappers such as
  `mise exec -- claude` or `mise exec -- pi` are supported there; Rondo shell-escapes the prompt and
  generated CLI flags before appending them to that command string. Native Windows shell-command
  support is tracked separately and fails safely
  rather than routing prompt text through `cmd.exe`.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $RONDO_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
claude:
  command: "$CLAUDE_BIN"
  model: "claude-opus-4-6"
  dangerously_skip_permissions: true
action_policy:
  command: beislid
  run_mode: unattended-auto
process_provider:
  kind: native
  required: false
  artifact_path: null
```

For early Beislið integration scaffolding, use an explicit approved artifact:

```yaml
process_provider:
  kind: beislid
  required: false
  artifact_path: ./beislid-process.json
```

Fixture-backed Beislið artifacts use `schema: "beislid-process-artifact-v1"`, `status:
"approved"`, an `id`, and optional `gates`, `skipped`, `warnings`, `guides`,
`proof_requirements`, `model_routing_hints`, `metadata`, and `action_policy` sections. Unknown
fields are ignored for forward compatibility, but consumed sections are validated before use.

- If `WORKFLOW.md` is missing, has invalid YAML, or contains invalid configured values, startup
  and scheduling are halted until fixed. Invalid live reloads keep the last known good workflow and
  log the config path plus invalid field names.
- `server.port` or CLI `--port` enables the optional HTTP dashboard and JSON API at `/`,
  `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.
- Each dispatched attempt writes a local run ledger under
  `<workspace.root>/.rondo_runs/<issue_identifier>/<run_id>/`. See
  [`docs/run_ledger.md`](docs/run_ledger.md) for layout, privacy, and retention notes.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.claude/`: repository-local Claude Code configuration and setup helpers

## Testing

```bash
make all
```

### Live end-to-end test (opt-in)

`make e2e` proves the full production path against real services: Linear issue fetch,
workspace prep, a real agent subprocess, the tracker `Todo -> In Progress` transition,
and cleanup. It is **never** run by default — `mix test` and CI exclude the `:live_e2e`
tag, and even `make e2e` skips with a clear reason unless explicitly enabled:

```bash
export RONDO_RUN_LIVE_E2E=1                 # the opt-in gate
export LINEAR_API_KEY=lin_api_...           # real Linear API key
export RONDO_E2E_LINEAR_TEAM=RONT           # key of a dedicated *test* team
export RONDO_E2E_LINEAR_PROJECT="Rondo E2E" # project (by name) for disposable issues
make e2e
```

To run through the **pi adapter** instead of the default Claude adapter:

```bash
export RONDO_E2E_AGENT_ADAPTER=pi
export RONDO_E2E_AGENT_COMMAND=/path/to/pi   # optional; defaults to "pi" on PATH
make e2e
```

Optional knobs:

- `RONDO_E2E_AGENT_ADAPTER` — adapter to drive (`claude_code` or `pi`; default
  `claude_code`). Any other value is a config error with a clear message.
- `RONDO_E2E_AGENT_COMMAND` — agent CLI binary override. When not set the default
  binary for the selected adapter is used (`claude` for `claude_code`, `pi` for `pi`).
  If the default binary is not found on `$PATH` the test **fails** with a clear message
  naming the missing command and the env var to set.
- `RONDO_E2E_AGENT_MAX_TURNS` — max agent turns for the short task (default `10`).
- `RONDO_E2E_ACTION_POLICY_COMMAND` — action-policy evaluator override. The live
  profile is **fail-closed** by default: it probes for `beislid` on `$PATH` and uses
  it automatically. If `beislid` is not installed the test **fails** with a clear
  message directing you here. To run without Beislið installed, set this variable to
  `fake` — an explicit, auditable opt-in to the allow-all stub that approves every
  action without evaluation. Any other value is used as the evaluator command path
  directly.

Deprecated aliases (still accepted; generalized names above take precedence when both
are set):

- `RONDO_E2E_CLAUDE_COMMAND` — superseded by `RONDO_E2E_AGENT_COMMAND`
- `RONDO_E2E_CLAUDE_MAX_TURNS` — superseded by `RONDO_E2E_AGENT_MAX_TURNS`

> **Note on pi model selection**: when `RONDO_E2E_AGENT_ADAPTER=pi`, the model used by
> pi is whatever your pi installation is configured for. There is currently no env var
> to select the model from the E2E side — that plumbing lands in RON-30.

What it does and mutates:

- Creates one disposable issue titled `[rondo-e2e] disposable run <timestamp>` in the
  configured test team/project, pinned to `Todo`. The team must have `Todo` and
  `In Progress` workflow states.
- Runs Rondo's run-once path in-process with a temporary `WORKFLOW.md` whose
  `tracker.project_slug` scopes every query to the test project — the normal Rondo
  project is never read or written. The `agent.adapter` and adapter section (`claude:`
  or `pi:`) in the temporary `WORKFLOW.md` are set to match `RONDO_E2E_AGENT_ADAPTER`.
- The agent task only writes `rondo_e2e_marker.txt` into a temporary workspace; the
  test asserts the marker content and that the issue reached `In Progress`. Note the
  agent subprocess inherits the workflow defaults `permission_mode: bypassPermissions`
  and `dangerously_skip_permissions: true` (claude_code adapter only; acceptable for
  this sandboxed, single-file task; the prompt forbids any other action and turns are
  capped).
- Cleanup runs in `on_exit` even when the test fails: the disposable issue is deleted
  (moved to Linear's trash, recoverable) and the temporary workspace is removed.
  Cleanup is best-effort; failures are logged with the issue URL so you can delete it
  manually.

Failures include the issue identifier/URL, workspace root, and the full run result to
debug tracker, workspace, or agent launch errors.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `claude` in your repo, give it the URL to the Rondo repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
