# RON-15 (GH #24): Local clean-eval worktree mechanics

Status: implemented
Branch: vic/ron-15-gh-24-p1-add-local-clean-eval-worktree-mechanics

## Goal

Separate patch generation from clean evaluation. After a run completes, optionally
re-evaluate the run's patch artifact (`rondo.patch/v0`, from RON-19/GH#23) on a clean
checkout of the recorded base ref, run local evaluator gates there, and report
pass/fail in the run ledger — independent of agent workspace state.

## Design

### New module: `Rondo.CleanEval` (`lib/rondo/clean_eval.ex`)

Public API:

- `Rondo.CleanEval.run(ledger, opts) :: {:ok, ledger, result} | {:error, term}`
  - `result` is a map with `:status` in `:pass | :fail | :error | :skipped` plus
    detail fields. `{:error, term}` only for ledger/artifact persistence failures.
- `Rondo.CleanEval.enabled?/0` — config gate (`clean_eval.enabled`, default false).
- `schema/0` (`"rondo.clean_eval/v0"`), `result_relative_path/0` (`"clean_eval/result.json"`).

Flow per run:

1. Read patch artifact from the run ledger dir using the RON-19 contract paths
   (`artifacts/changes.patch`, `artifacts/patch.json`). Missing patch ⇒ `:skipped`
   (`reason: "missing_patch_artifact"`). Missing/invalid metadata or absent
   `base_ref` ⇒ `:error` (recorded, never a crash).
2. Base ref: `opts[:base_ref]` > `clean_eval.base_ref` config > patch metadata `base_ref`.
3. Create a clean detached worktree from the agent workspace repo:
   `git worktree add --detach <workspace_root>/.rondo_clean_eval/<run_id> <base_ref>`.
   The worktree shares object storage but has a pristine checkout of `base_ref`,
   so it is independent of dirty agent workspace state. Failure ⇒ `:error`.
4. Apply patch with `git apply <abs patch path>` in the eval worktree.
   Non-zero exit ⇒ evaluator failure: `:fail`, `patch_status: "apply_failed"`,
   apply output captured (capped) in the result artifact.
5. Run gates via the gate-runner seam (`opts[:gate_runner]`, default `&Rondo.Gates.run/3`)
   with `gates_dir: "clean_eval/gates"` so gate logs/results land under the
   `clean_eval/` subtree of the run dir, separate from agent `artifacts/`.
   Gates: `opts[:gates]` > `clean_eval.gates` config > top-level `gates` config.
   Gate summary `:fail` ⇒ `:fail`; `:error`/`:timeout` ⇒ `:error`; runner returning
   a non-summary error ⇒ `:error`. Empty gate list ⇒ `:pass` (apply-only evaluation).
6. Cleanup always: `git worktree remove --force`; on failure fall back to
   `rm -rf` + `git worktree prune`. Recorded in result (`cleanup.removed`, `cleanup.method`).
7. Persist `clean_eval/result.json` (schema `rondo.clean_eval/v0`: status, reason,
   base_ref, base_branch, patch_path, patch_status, apply_exit_status, apply_output,
   gates summary, eval_workspace, cleanup, started_at/finished_at), link manifest
   artifacts (`clean_eval_result`, `clean_eval_gate_results`), write a
   `clean_eval_completed` checkpoint, and set a manifest `"clean_eval"` block
   `{"status", "result_path"}` so pass/fail is reported in the run ledger.

Git commands run through an injectable `opts[:runner]` (same shape as
`Rondo.PatchArtifact`'s: `fn args, cd -> {output, exit_status} end`) for tests.

### Beislid swap seam

The gate-runner seam is a single function with `Rondo.Gates.run/3`'s contract
(`(gates, workspace, opts) -> {:ok, summary} | {:error, summary | term}`),
consistent with the ProcessProvider gate-selection shape. Beislid staged pre-PR
gates can later replace local gates by injecting a runner (or routing gate
selection through `Rondo.ProcessProvider`) without changing CleanEval mechanics.

### Config (`WORKFLOW.md`)

New `clean_eval` section (opt-in):

```yaml
clean_eval:
  enabled: true            # default false
  base_ref: null           # optional override; default: patch metadata base_ref
  gates:                   # optional; default: top-level gates
    - name: tests
      command: make test
```

Accessors: `Config.clean_eval_enabled?/0`, `Config.clean_eval_base_ref/0`,
`Config.clean_eval_gates/0` (falls back to `Config.gates/0` when unset).
Validation mirrors the top-level `gates` validation (reused with a path prefix).

### `Rondo.Gates` change

New optional `:gates_dir` opt overriding the default `"artifacts/gates"` base dir,
combined with `execution_id` as before.

### `Rondo.RunOnce` integration

After a successful agent run (result `:ok`) and after queued updates are recorded,
`maybe_run_clean_eval/2` runs CleanEval when `clean_eval.enabled` — logging only,
never altering the run result. Seam tolerance to RON-19: RON-19 adds
`finalize_run_artifacts` (patch capture) in the same region; on merge, clean eval
must run *after* patch capture. CleanEval itself only reads contract files from the
run dir, so it is order-independent at the module level.

## Decisions made AFK

- Opt-in via `clean_eval.enabled` (pre-approved); disabled ⇒ RunOnce skips entirely.
- Clean-eval failure does not change the run-once result; it is reported in the
  ledger (manifest `clean_eval` block + checkpoint + result artifact). The ticket
  asks for reporting, not gating; gating arrives with Beislid pre-PR integration.
- Missing patch artifact ⇒ `:skipped` (still recorded), per the contract note that
  readers must tolerate missing patch artifacts (no-changes runs).
- Patch/contract paths are hardcoded constants matching `rondo.patch/v0` instead of
  calling `Rondo.PatchArtifact` (module not on main yet); keeps the seam tolerant
  to RON-19 landing in either order.
- Apply output is embedded (capped at 16 KiB) in `result.json` instead of a separate
  apply.log file, keeping persistence single-pathed; gate logs remain separate files
  under `clean_eval/gates/` via `Rondo.Gates`.
- `git worktree` chosen over `git clone` for the clean checkout: the base ref is a
  workspace-local SHA, worktrees are cheap, and the checkout is pristine regardless
  of the source worktree's dirty state. Eval dir lives under
  `<workspace_root>/.rondo_clean_eval/<run_id>` (inside the configured root so
  `Gates` workspace validation passes; removed on completion).
- Orchestrator integration deferred (run-once path only), matching RON-19's scope.

## Test coverage (clean_eval_test.exs + gates/config/run_once additions)

- clean apply + gates pass (dirty agent workspace untouched/independent)
- apply conflict ⇒ `:fail` recorded as evaluator failure
- gate failure ⇒ `:fail`; gate env error (127) ⇒ `:error`
- skipped when patch missing; errors for bad metadata/base ref/workspace/worktree
- cleanup on pass, fail, and worktree-remove failure (rm_rf fallback)
- gate-runner seam injection; empty gates apply-only pass
- persistence failure returns `{:error, _}`
- config parsing/validation defaults and overrides
- run-once integration: enabled config triggers eval and manifest reporting
