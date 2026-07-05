# ron-159-gate-repair-turn

Source: RON-159
Approved: 2026-07-05T23:20:00Z by Vic Valenzuela <victor@dala.care>

## Objective
Post-turn gate failure with remaining turn budget feeds the gate output back to the agent as a bounded same-tier repair turn instead of aborting the run.

## Scope
Include:
- `elixir/lib/rondo/agent_runner.ex`
- `elixir/test/ (agent_runner gate-repair tests; extend test/rondo/agent_adapter_test.exs or add a dedicated file)`

Exclude:
- Orchestrator-mode retry semantics
- Gate selection logic
- Terminal outcome semantics (RON-161)

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
If the codebase has no environment-class failure classification, treat all gate failures as repairable and state that in the final report - do not invent a taxonomy. Pause on any need to change gate selection or terminal-outcome semantics.

## Delivery
A fixable gate failure no longer wastes the whole run: the agent sees gate names plus failing log tails as a same-tier continuation prompt, bounded to 2 repair attempts, aborting only on exhaustion or exhausted turn budget.
