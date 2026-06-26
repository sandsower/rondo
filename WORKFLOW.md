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
  max_concurrent_agents: 5
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
when the Linear description says "see Source link". Close both sides on completion.

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
5. Project conventions live in `.beislid/workflow.md` (gates incl. known
   RON-31 flake hints, action policy, tracker duality). Run the configured
   gates before any push.
6. Out-of-scope discoveries become new Linear issues in the same project,
   linked `related`, never scope expansion.
7. Final message reports completed actions and blockers only.
