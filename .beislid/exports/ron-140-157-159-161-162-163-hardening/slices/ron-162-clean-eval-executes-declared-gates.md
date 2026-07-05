# ron-162-clean-eval-executes-declared-gates

Source: RON-162
Approved: 2026-07-05T23:20:00Z by Vic Valenzuela <victor@dala.care>

## Objective
clean_eval cannot report pass while provider-declared pre-PR gates and proof requirements went unexecuted; declared-but-unexecuted proofs fail closed.

## Scope
Include:
- `elixir/lib/rondo/clean_eval.ex`
- `elixir/lib/rondo/process_provider/native.ex (read/extend for command_proofs shape)`
- `elixir/test/rondo/clean_eval_test.exs`

Exclude:
- Gate selection semantics outside clean_eval
- Turn-loop changes (RON-159/161)

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
Ambiguity in the provider artifact contract shape; any change that would weaken an existing passing path.

## Delivery
clean_eval threads the manifest process_provider artifact into gate selection at stage pre_pr, executes declared gates/proofs, and fails closed with reason declared_proofs_not_executed when declared proofs produce no execution evidence.
