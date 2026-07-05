# ron-161-unambiguous-terminal-outcome

Source: RON-161
Approved: 2026-07-05T23:20:00Z by Vic Valenzuela <victor@dala.care>

## Objective
A run with a valid final report and passing clean-eval reaches exactly one deliberate terminal state - never max-turns burn, never both completed and failed checkpoints.

## Scope
Include:
- `elixir/lib/rondo/agent_runner.ex`
- `elixir/lib/rondo/run_decision.ex`
- `elixir/test/rondo/run_decision_test.exs`
- `elixir/test/ (agent_runner terminal-outcome tests)`

Exclude:
- Tracker integration changes
- clean_eval internals (RON-162)

## Autonomy
- Allow: edit included files, run gates/targeted tests, local commits.
- Ask: scope drift, new dependencies, behavior beyond the bound design.
- Deny: remote writes (push/PR/tracker), external mutations, destructive work outside the repo.

## Proof
- `cd elixir && mix format --check-formatted`
- `cd elixir && mix credo --strict`
- `cd elixir && mix test`
- `cd elixir && mix dialyzer --format short`

## Pause conditions
Any ambiguity about which states count as 'active due to missing PR/review evidence'; any change to tracker-driven (non-manifest) flows.

## Delivery
Valid final report + tracker-less manifest run yields a deliberate handoff_required terminal outcome instead of burning turns to max_turns; gates_run string entries are normalized before completion; the ledger records exactly one terminal classification.
