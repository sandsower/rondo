# Rondo

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Claude Code as a CLI subprocess.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `Rondo.Workflow` and `Rondo.Config`.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `Rondo.Config` instead of ad-hoc env reads.
- `command_proofs` manifest key runs executable exit-code proofs inside `Rondo.CleanEval` post-gates; see the moduledoc in `lib/rondo/clean_eval.ex`.
- Workspace safety is critical:
  - Never run Claude Code with cwd in the source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

- Replay corpus regression (`test/rondo/replay_corpus_test.exs`) runs under plain `mix test`; regenerate goldens with `REGEN_REPLAY_GOLDEN=1 mix test test/rondo/replay_corpus_test.exs` (deliberately fails so regens can't pass silently).
- `mix rondo.scorecard [--workspace-root PATH] [--json]` prints a read-only cross-run outcome scorecard over `.rondo_runs/` ledgers; see the moduledoc in `lib/mix/tasks/rondo.scorecard.ex`.
- Coverage threshold (`mix.exs` `test_coverage`) is a ratchet - may only increase, lowering requires a ticket; runs in `make all`/`make exhaustive`, not in blocking CI.

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/rondo/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
