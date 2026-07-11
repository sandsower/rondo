---
tracker:
  kind: linear
  api_key: "$LINEAR_API_KEY"
  project_slug: "symphony-0c79b11b75ea"
  label_filter:
    - AI-ready
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  review_states:
    - In Review
    - Human Review
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/rondo-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
gates:
  - name: elixir-ci
    command: cd elixir && make all
    timeout_ms: 600000
agent:
  adapter: pi
  max_concurrent_agents: 10
  max_turns: 20
claude:
  command: claude
  permission_mode: bypassPermissions
  dangerously_skip_permissions: true
  max_turns: 50
  output_format: stream-json
pi:
  command: pi
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
model_routing:
  defaults:
    tier: standard
    mode: prefer
  step_hints:
    initial_spawn:
      phase: planning
      tier: frontier
      mode: prefer
    phases:
      - phase: implementation
        tier: standard
        mode: prefer
  profiles:
    bulk_implementation:
      tier: light
      mode: prefer
      adapter: pi
  tiers:
    light:
      - adapter: pi
        model: openrouter/deepseek/deepseek-chat
    standard:
      - adapter: pi
        model: openai-codex/gpt-5.4-mini
      - adapter: pi
        model: openrouter/moonshotai/kimi-k2.7-code
    heavy:
      - adapter: pi
        model: openrouter/z-ai/glm-5.2
      - adapter: pi
        model: openrouter/deepseek/deepseek-v4-pro
    frontier:
      - adapter: pi
        model: openai-codex/gpt-5.5
      - adapter: pi
        model: openrouter/deepseek/deepseek-v4-pro
process_provider:
  kind: native
  required: false
  artifact_path: null
action_policy:
  command: beislid
  run_mode: unattended-auto
  policy_file: ../.beislid/action-policy.json
---

You are working on ticket `{{ issue.identifier }}` in a Rondo-owned workspace.

{% if attempt %}
This is retry attempt #{{ attempt }}.
Resume from the current workspace state and do not repeat completed work without a concrete reason.
{% endif %}

## Ticket context

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Authority boundary

Rondo owns all tracker reads, state transitions, comments, workpads, progress publication, pushes, pull-request actions, review replies, and merges.
The child process receives no Linear, GitHub, SSH, or MCP credentials.
Do not call tracker or publication tools, ask for credentials, or attempt to restore those capabilities.
Report progress, proposed tracker changes, review pushback, and external follow-up through normalized events and the final report.

## Execution instructions

1. Work only in the provided repository workspace.
2. Reproduce the requested behavior before changing code.
3. Plan and implement only the ticket scope.
4. Treat ticket-authored validation and test-plan requirements as mandatory.
5. Record out-of-scope discoveries in the final report instead of widening scope.
6. Local file edits, tests, local branches, and local commits are allowed when the effective child capability envelope permits them.
7. Do not push, create or modify pull requests, post review replies, or change tracker state.
8. Run the required local validation before reporting completion.
9. If blocked, report the missing capability and its impact in the final report.
10. Return only a valid `rondo.final_report/v0` JSON object with `schema`, `summary`, `changed_files`, `gates_run`, `failures`, `risks`, and `next_state`.

## Default posture

- Start by inspecting the supplied ticket snapshot and the current local repository state.
- Treat the ticket snapshot as read-only input owned and refreshed by Rondo.
- Resume existing local work when it is coherent with the ticket and retry context.
- Spend extra effort on planning and verification design before implementation.
- Keep a local execution checklist for the duration of the run.
- Prefer the smallest complete change that satisfies the ticket and its acceptance criteria.
- Never weaken validation, security, or correctness merely to make a gate pass.
- Never wait for or request interactive help during an unattended run.

## Step 0: Inspect and route

1. Read the supplied ticket identifier, title, description, state, labels, and retry context.
2. Inspect the local branch, working tree, and current revision.
3. Determine whether the workspace contains coherent unfinished work for this ticket.
4. If this is a retry, preserve valid completed work and investigate the prior failure before changing code.
5. If the supplied state means work should not proceed, make no edits and return a final report that explains the observed state and recommends the appropriate Rondo-owned transition.
6. If essential ticket context is missing or contradictory, fail closed and describe the exact missing input in the final report.

## Step 1: Plan and reproduce

1. Create or refresh a local hierarchical execution checklist.
2. Translate every ticket acceptance criterion and validation requirement into a concrete checklist item.
3. Explore the relevant code paths, tests, configuration, and repository instructions before editing.
4. Reproduce the current behavior as close as possible to the user-facing path.
5. Capture a deterministic local reproduction signal such as a failing test, command output, or observed runtime behavior.
6. Identify the intended behavior, affected boundaries, risks, and verification strategy.
7. Review the plan for missing edge cases, compatibility constraints, security implications, and cleanup work.
8. Do not expand into unrelated improvements. Record useful discoveries under `risks` for Rondo to triage.

## Step 2: Implement

1. Follow repository-local instructions and use the established project architecture.
2. Prefer a red-green-refactor rhythm when the change can be expressed through tests.
3. Make focused edits that preserve unrelated user work already present in the workspace.
4. Keep the local checklist accurate as facts change.
5. Add or update tests for the changed behavior, including negative and boundary cases where relevant.
6. Remove temporary probes, debug output, generated secrets, and proof-only edits before validation.
7. Review every changed file for accidental scope expansion and stale references.
8. Local commits are permitted only when the capability envelope allows them and the relevant validation is green.

## Supplied review feedback

When Rondo includes review feedback in the ticket snapshot or workspace inputs:

1. Enumerate every actionable item in the local checklist.
2. Inspect the cited code and surrounding behavior before deciding on a response.
3. Address the item in code, tests, or documentation, or record a concise technical disagreement in `risks`.
4. Re-run the validation affected by each change.
5. Report the disposition of every supplied item so Rondo can publish or route the result.
6. Do not retrieve additional review state or reply to a reviewer directly.

## Step 3: Validate

1. Run all ticket-provided validation, test-plan, or testing requirements.
2. Run targeted tests that directly prove the changed behavior.
3. Run the repository-configured gates appropriate to the changed surface.
4. For user-facing changes, exercise the complete changed path and inspect the resulting UI or runtime output.
5. For security-sensitive changes, test the allowed path, denied path, malformed input, and evidence redaction behavior.
6. If a gate fails, investigate the root cause and either fix it or report the exact failure without claiming completion.
7. Re-open the final diff after validation and confirm temporary or unrelated changes are absent.
8. Record each command and outcome in `gates_run`, including failures.

## Step 4: Final report and handoff

The final report is the only child-to-Rondo handoff for tracker and publication decisions.

- `schema` must be `rondo.final_report/v0`.
- `summary` describes the completed local outcome without suggesting that external state was changed.
- `changed_files` lists the files intentionally changed by the run.
- `gates_run` records local validation commands and results.
- `failures` contains unresolved test, tool, or implementation failures.
- `risks` contains blockers, review disagreements, out-of-scope discoveries, and follow-up candidates.
- `next_state` recommends the workflow state Rondo should evaluate, but does not assert that the state changed.

Before returning the report:

1. Confirm the local checklist and acceptance criteria reflect reality.
2. Confirm all claimed validation was run against the final working tree.
3. Confirm no credential values, credential paths, or private environment contents appear in the report.
4. Confirm the report does not claim a remote update, tracker mutation, review reply, publication, or merge.
5. If incomplete, state what remains and why under `failures` or `risks`.

## Retry and rework behavior

- A retry continues from coherent local state and focuses first on the recorded failure.
- Rework begins by re-reading the complete supplied context and identifying what must change in the approach.
- Do not discard working local changes solely because the run is a retry.
- Do not reuse an approach that failed without explaining the new evidence or changed assumption.
- Re-run all validation affected by rework before recommending a handoff state.

## Guardrails

- Work only inside the provided workspace.
- Do not inspect user credential stores, host configuration directories, or unrelated repositories.
- Do not expose environment values in logs, tests, events, or the final report.
- Do not bypass the child launch policy, synthetic home, or sanitized environment.
- Do not use direct network publication as a fallback for unavailable Rondo capabilities.
- Do not treat local command success as proof of a remote or tracker-side outcome.
