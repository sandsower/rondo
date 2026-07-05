# ron-140-subprocess-group-kill

Source: RON-140
Approved: 2026-07-05T23:20:00Z by Vic Valenzuela <victor@dala.care>

## Objective
Agent subprocesses run in their own process group with reliable, checked group kill and guaranteed port close on all exit paths, identically across the claude, codex, and pi adapters.

## Scope
Include:
- `elixir/lib/rondo/claude/cli.ex`
- `elixir/lib/rondo/codex/cli.ex`
- `elixir/lib/rondo/pi/cli.ex`
- `elixir/test/rondo/claude_cli_test.exs`
- `elixir/test/rondo/codex_cli_test.exs`
- `elixir/test/rondo/pi_cli_test.exs`
- `a new shared spawn helper module under elixir/lib/rondo/ if none exists (none found in-session)`

Exclude:
- Adapter consolidation (RON-141)
- Any other adapter behavior change

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
Platform divergence between darwin and Linux in tests; kill/port semantics ambiguity; any need to touch files outside the three adapters plus one shared helper.

## Delivery
All three adapters spawn children as process-group leaders via a portable wrapper, kill by -pgid with checked results, and close ports in after/rescue paths; orphaned-child and raise-in-on_event tests pass on darwin.
