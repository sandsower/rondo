# RON-33: Parameterize live E2E agent adapter to cover pi runs

**Date**: 2026-06-11
**Branch**: vic/ron-33-parameterize-live-e2e-agent-adapter-to-cover-pi-runs

## Goal

Parameterize the live E2E profile so it can drive the pi adapter (non-Anthropic models) in addition to the default claude_code adapter. Unit/fixture-level verification only — never run live against real credentials in this branch.

## Scope

1. Add `RONDO_E2E_AGENT_ADAPTER` env var to `Rondo.LiveE2E` (default `claude_code`, accepts `pi`; anything else is a config error with a clear message).
2. Add generalized agent env vars `RONDO_E2E_AGENT_COMMAND` and `RONDO_E2E_AGENT_MAX_TURNS`; keep `RONDO_E2E_CLAUDE_COMMAND` / `RONDO_E2E_CLAUDE_MAX_TURNS` as deprecated aliases (generalized names win when both set).
3. `load_context/2` returns `:agent_adapter`, `:agent_command`, and `:agent_max_turns` keys in the context map, plus a `:cli_missing` probe-honest failure when the selected adapter's CLI is not found on PATH.
4. `configure_live_workflow!/2` in the live E2E test writes the matching `agent.adapter` plus adapter section (`claude:` or `pi:` with command and sensible timeouts).
5. Unit tests in `live_e2e_support_test.exs` cover: adapter selection (default, pi, invalid value), alias precedence, missing-CLI failure message, and the temp WORKFLOW.md contents per adapter.
6. README live-E2E section updated with new vars, deprecated aliases, and pi-model note.

## File plan

| File | Action |
|---|---|
| `test/support/live_e2e.exs` | Add adapter resolution logic, generalized env vars, deprecated aliases |
| `test/e2e/live_linear_claude_e2e_test.exs` | Generalize `configure_live_workflow!/2` to emit correct adapter section |
| `test/rondo/live_e2e_support_test.exs` | Add unit tests for new behavior |
| `elixir/README.md` | Document new vars, deprecated aliases, pi-model note |
| `elixir/docs/plans/2026-06-11-ron-33-e2e-pi-adapter.md` | This file |

## TDD rhythm

1. Write failing tests for new LiveE2E.load_context/2 behavior
2. Implement the new behavior in live_e2e.exs
3. Write failing tests for configure_live_workflow!/2 adapter dispatch
4. Implement configure_live_workflow!/2 changes
5. Run format + credo, then full test suite

## Decisions made AFK

- **Probe-honest failure vs skip**: The ticket says "fail (not skip)" when the adapter's CLI is missing. We return `{:error, {:agent_cli_missing, command, env_var}}` which causes `flunk/1` in the test. This matches the existing pattern for `action_policy_command_missing`.
- **Default adapter command**: For `pi`, the default command is `"pi"` (matches the pi section default in WORKFLOW.md). For `claude_code`, the default command is `"claude"` (unchanged from today).
- **`agent_command` key naming**: The context map uses `agent_command` and `agent_max_turns` (not `claude_command` etc.) as the canonical keys for the generalized adapter. The old `claude_command` and `claude_max_turns` keys are kept alongside for backward compat during the transition, populated from the resolved generalized values when adapter is `claude_code`.
  - CONSERVATIVE CHOICE: Actually keep the old `claude_command` / `claude_max_turns` keys in the map and add `agent_command` / `agent_max_turns` as canonical. The live test references `context.claude_command` / `context.claude_max_turns` — rather than update those references at risk of breaking things, we emit both. This is a one-step conservative choice.
  - REVISED: The ticket says "generalized names win when both set". The map should use `agent_command` / `agent_max_turns` as canonical. The live test `configure_live_workflow!/2` will be updated to use those keys. Since the live test is in the same PR, this is safe.
- **Timeout values**: pi section in WORKFLOW.md uses `turn_timeout_ms: 3_600_000` and `stall_timeout_ms: 300_000` by default. We use these same sensible defaults in the temp workflow.
- **`pi` default command**: `"pi"` (matching existing WORKFLOW.md template).
- **Invalid adapter error key**: `{:error, {:invalid_agent_adapter, value, ["claude_code", "pi"]}}` — clear, list-of-accepted included.
