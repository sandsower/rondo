# ron-136-claude-adapter-parity

Source: RON-136 (teotl unification P0 batch, audit findings R1/R2).
Approved: 2026-07-02T17:10:23Z by Vic Valenzuela (explicit per-envelope verdict).

**Objective:** claude CLI drains output at `:exit_status`; claude stream parser emits cache tokens + cost - both at parity with the codex/pi siblings.

**Scope:** `elixir/lib/rondo/claude/{cli,stream_parser}.ex` + tests.
Codex/pi files are read-only references; editing them is denied (drift risk).

**Autonomy:** supervised-auto; local branch work allowed; push/PR denied; out-of-scope edits ask.

**Proof:** `mix test` (with new drain/cache tests), `mix format --check-formatted`, `mix credo --strict`, all from `elixir/`.

**Pause on:** gate failure after retry, ambiguity in acceptance criteria, scope drift, missing dependency.

**Delivery:** summary, changed files, proof results; next step ready-for-review.

**Ownership:** Beislið planning/proof semantics; Rondo execution/run evidence; Memento memory capture.
