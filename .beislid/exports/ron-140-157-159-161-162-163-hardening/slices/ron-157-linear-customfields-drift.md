# ron-157-linear-customfields-drift

Source: RON-157
Approved: 2026-07-05T23:20:00Z by Vic Valenzuela <victor@dala.care>

## Objective
Linear GraphQL queries no longer request the removed customFields field, and deterministic schema-validation 400s are loud instead of silently swallowed per poll.

## Scope
Include:
- `elixir/lib/rondo/linear/client.ex`
- `elixir/test/ (new or extended Linear client test)`

Exclude:
- Other Linear query changes
- MCP server changes

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
If customFields data turns out to feed a live feature (grep consumers before deleting the extraction clause) - pause and report instead of guessing.

## Delivery
Linear issue queries validate against the current API schema; customFields selection and its extraction clause are gone; GRAPHQL_VALIDATION_FAILED 400s log at error level with the API message.
