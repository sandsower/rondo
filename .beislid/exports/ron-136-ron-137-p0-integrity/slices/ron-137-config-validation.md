# ron-137-config-validation

Source: RON-137 (teotl unification P0 batch, audit findings R5/R6).
Approved: 2026-07-02T17:10:23Z by Vic Valenzuela (explicit per-envelope verdict).

**Objective:** wire `tracker.assignee` into polling, validate `merge.mode` against its own section, warn on unknown config keys, make workflow-load failure loud.

**Scope:** `elixir/lib/rondo/config.ex` + the assignee application point in `orchestrator.ex` + tests.
If the application point lives elsewhere: pause, don't widen.

**Autonomy:** supervised-auto; local branch work allowed; push/PR denied; new config keys denied.

**Proof:** `mix test` (one new test per acceptance bullet), `mix format --check-formatted`, `mix credo --strict`.

**Pause on:** scope drift outside the two files, gate failure after retry, ambiguity.

**Delivery:** summary, changed files, proof results; next step ready-for-review.

**Ownership:** Beislið planning/proof semantics; Rondo execution/run evidence; Memento memory capture.
