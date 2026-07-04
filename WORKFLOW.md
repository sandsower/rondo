---
# Rondo execution profile — rondo (self-hosting)
# Run rondo against this profile to execute Linear issues from the
# "Rondo intake — rondo" project. Adding an issue to that project is the
# explicit AFK opt-in. Envelope-driven runs use `rondo run-once --manifest`
# and override tracker polling entirely.
#
# Note: elixir/WORKFLOW.md is the upstream example config; this file is the
# real profile for running rondo against its own backlog.
tracker:
  kind: linear
  api_key: "$LINEAR_API_KEY"
  project_slug: "rondo-intake-rondo-46bf79238daa"
  active_states:
    - Todo
    - In Progress
    - In Review
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 30000
workspace:
  root: ~/code/rondo-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:sandsower/rondo.git .
    git checkout -B rondo/{{ issue.identifier }}
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_run: git checkout -B rondo/{{ issue.identifier }}
  timeout_ms: 300000
gates:
  - name: format
    command: cd elixir && mise exec -- mix format --check-formatted
  - name: credo
    command: cd elixir && mise exec -- mix credo --strict
  - name: elixir-ci
    command: cd elixir && mise exec -- make all
    timeout_ms: 900000
agent:
  adapter: pi
  max_concurrent_agents: 15
  max_turns: 20
claude:
  command: claude
  permission_mode: bypassPermissions
  dangerously_skip_permissions: true
  output_format: stream-json
pi:
  command: pi
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
model_routing:
  defaults:
    tier: standard
    mode: prefer
  profiles:
    # Low-cost bulk AFK implementation runs route through OpenRouter-backed
    # light candidates by default. Planning/review-critical phases still
    # escalate via step_hints or source-contract hints to heavy/frontier.
    bulk_implementation:
      tier: light
      mode: prefer
      adapter: pi
  tiers:
    light:
      - adapter: pi
        model: openrouter/deepseek/deepseek-chat
    standard:
      # Subscription tier has been upgraded; prefer Codex for primary workflow
      # execution and retain OpenRouter only as fallback capacity.
      - adapter: pi
        model: openai-codex/gpt-5.4-mini
      - adapter: pi
        model: openrouter/deepseek/deepseek-v4-pro
    heavy:
      - adapter: pi
        model: openai-codex/gpt-5.5
      - adapter: pi
        model: openrouter/deepseek/deepseek-v4-pro
      - adapter: pi
        model: openrouter/z-ai/glm-5.2
    frontier:
      - adapter: pi
        model: openai-codex/gpt-5.5
      - adapter: pi
        model: openrouter/deepseek/deepseek-v4-pro
action_policy:
  command: beislid
  run_mode: unattended-auto
  policy_file: /Users/vicvalenzuela/Personal/rondo/.beislid/action-policy.json
process_provider:
  kind: beislid
  required: false
---

You are working on Linear ticket `{{ issue.identifier }}` in the rondo repo
(Rondo — execution orchestrator; run ledger, agent adapters; Elixir under elixir/).

Tracker duality: Linear is canonical for state; GitHub (sandsower/rondo) is
canonical for issue body and discussion — fetch the GH body via `gh issue view`
when the Linear description says "see Source link". Close both sides only after a
reviewable PR/diff has landed and the ticket is truly complete. Never move a
Linear issue to In Review/Human Review/Done unless a PR/diff URL or configured
review artifact is attached; if implementation finishes without that evidence,
leave the issue In Progress and record the missing handoff in the workpad.

Claude Code sessions can load the repo-local project-scoped `.mcp.json` at the
repository root; it exposes the `linear_graphql` tool via
`./elixir/bin/linear_graphql_mcp` using Rondo's configured Linear auth.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform
   follow-up actions; only stop for a true blocker (missing auth/permissions).
2. Work only in the provided repository copy.
3. Maintain a single persistent Linear workpad comment as the source of truth
   for progress; bring it up to date before new implementation work.
4. Treat any ticket-authored Validation/Test Plan section as non-negotiable
   acceptance input; execute it before considering the work complete.
5. Project conventions live in `.beislid/workflow.md` (gates, action policy,
   tracker duality). Run the configured gates before any push.
6. Out-of-scope discoveries become new Linear issues in the same project,
   linked `related`, never scope expansion.
7. Final response must be only a valid `rondo.final_report/v0` JSON object with required fields `schema`, `summary`, `changed_files`, `gates_run`, `failures`, `risks`, and `next_state`. Use `schema: "rondo.final_report/v0"`; do not use legacy keys such as `version`, `ticket`, `completed_actions`, or `blockers` instead of the required fields.

## In Review babysit loop

When the ticket status is `In Review`, do not start new feature work. Treat the run as a review/babysit loop:

1. Find the linked/open PR for the issue branch; if none exists, move the ticket back to `In Progress`, update the workpad with the missing review artifact, and stop.
2. Read top-level PR comments, inline review comments, reviews, CI/check status, mergeability, and branch freshness.
3. Treat every actionable human/bot comment as blocking until it is fixed and replied to, or an explicit justified pushback is posted.
4. Run the configured workflow gates before every babysit-owned push or merge boundary.
5. Only leave the ticket in `In Review` when the PR is reviewable, checks are green or legitimately pending human review, and unresolved actionable feedback is recorded in the workpad. If changes are required, move the ticket to `In Progress` and execute the fixes end-to-end.
6. Never merge automatically from this prompt-level fallback unless the workflow has native release-loop support and action policy permits it.
