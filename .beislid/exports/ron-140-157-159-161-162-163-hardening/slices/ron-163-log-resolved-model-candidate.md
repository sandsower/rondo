# ron-163-log-resolved-model-candidate

Source: RON-163
Approved: 2026-07-05T23:20:00Z by Vic Valenzuela <victor@dala.care>

## Objective
Every model-routing resolution and every completed agent turn logs the resolved provider/model, tier, and fallback position - manifest run-once flows included.

## Scope
Include:
- `elixir/lib/rondo/model_routing.ex`
- `elixir/lib/rondo/agent_runner.ex (log call sites only)`
- `elixir/test/rondo/model_routing_test.exs`

Exclude:
- Routing behavior changes
- Dashboard work (RON-60/RON-86)

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
If the resolved candidate is not available at the agent_runner log site without threading new state through public function signatures beyond one plumbing parameter - pause and propose.

## Delivery
Run logs answer 'which model actually ran': resolve/1 emits adapter, provider/model, tier, candidate index and fallback flag with issue/turn context; the Completed-agent-turn line includes the resolved model; fallbacks log failed candidate plus selected fallback.
