<!-- beislid-workflow: v1 -->

# Beislið workflow config — rondo

## Issue tracker

Linear issues in the personal `teotl` workspace, team `rondo`, accessed via Linear MCP.

Tracker duality: these Linear issues mirror GitHub issues on `sandsower/rondo`. **Linear is canonical for state** (Todo/In Progress/Done); **GitHub is canonical for issue body and discussion** — fetch the GH body via `gh issue view` when the Linear description says "see Source link". When work completes, close both sides. Closing an envelope ticket (`[Envelope] ...`) never closes the implementation ticket it wraps — the envelope is the approval artifact, not the implementation (see the RON-10 reconciliation, 2026-06-10).

```beislid:ticket_source
type: mcp
tool: mcp__personal-linear-server__get_issue
id_pattern: '^RON-\d+$'
link_template: 'https://linear.app/teotl/issue/{id}'
```

```beislid:branch_pattern
^[^/]+/([a-z]+-\d+)
```

```beislid:ticket_update
type: mcp
comment_tool: mcp__personal-linear-server__save_comment
issue_tool: mcp__personal-linear-server__save_issue
```

## PR reviews

Read GitHub PR review comments and post clear-fix replies through the `gh` CLI.

```beislid:pr_review_source
type: cli
summary_command: 'gh pr view --json url,number,reviewDecision,reviews,comments'
threads_command: 'gh api repos/{owner}/{repo}/pulls/{number}/comments'
```

```beislid:pr_review_update
type: cli
reply_command: 'gh api repos/{owner}/{repo}/pulls/{number}/comments --method POST --input {json_file}'
rerequest_command: 'gh api repos/{owner}/{repo}/pulls/{number}/requested_reviewers --method POST --input {json_file}'
```

AgenticReviewer is a scarce final-review role; CodeRabbit is this repo's current provider. Do not trigger it for WIP or routine iteration; run local gates and Beislið review first, then opt in by adding the configured label or PR body keyword.

```beislid:review_policy
agentic_reviewer:
  mode: opt_in_final_review
  provider: coderabbit
  label: coderabbit-ready
  description_keyword: coderabbit:review
risk:
  max_auto_closeout_risk: low
  high_risk_paths:
    - '**/config/**'
    - 'elixir/config/**'
    - '**/priv/repo/migrations/**'
    - 'elixir/priv/repo/migrations/**'
    - '**/*_web/**'
    - '**/security/**'
    - '**/auth/**'
    - '**/crypto/**'
    - '**/billing/**'
    - '**/payment/**'
    - 'mix.lock'
  low_risk_paths:
    - 'docs/**'
    - 'test/**'
    - 'elixir/test/**'
    - 'elixir/test/support/**'
    - '**/*.md'
    - '**/*.markdown'
    - '**/*.mdx'
    - '**/*.rst'
    - 'README*'
    - 'CHANGELOG.md'
  high_risk_file_count: 12
  high_risk_total_changes: 500
  low_risk_file_count: 3
  low_risk_total_changes: 120
```

## Quality gates

Cheap gates first for iteration. Normal review/babysit runs format, credo, tests, dialyzer, and script syntax only; `elixir-exhaustive` keeps `make all` available as a manual/high-risk gate because it includes coverage and is intentionally heavier.

```beislid:gates
- name: format
  command: 'cd elixir && mix format --check-formatted'
  cost: cheap
  parallel_safe: true
- name: credo
  command: 'cd elixir && mix credo --strict'
  cost: cheap
  parallel_safe: true
- name: test
  command: 'cd elixir && mix test'
  cost: expensive
- name: dialyzer
  stage: pre-pr
  command: 'cd elixir && mix dialyzer --format short'
  cost: expensive
  parallel_safe: true
  failure:
    hint: 'runs independently so static analysis is not masked by coverage threshold failures.'
- name: scripts-syntax
  stage: pre-pr
  command: 'bash -n scripts/restart-rondo-services'
  cost: cheap
  parallel_safe: true
- name: elixir-exhaustive
  stage: exhaustive
  command: 'cd elixir && make all'
  cost: expensive
  failure:
    hint: 'exhaustive/manual gate only. Includes coverage with an honest, measured threshold on the execution core (web/dashboard/timeseries display surfaces excluded deliberately). Ratchet convention: the threshold may only increase; lowering it requires a ticket.'
```

## Model routing

Sonnet-tier models handle implementation, review-fix, and babysit-style work (validated by the 2026-06-10 envelope batch); planning and adversarial skills prefer a stronger model. `mode: prefer` everywhere — fall back with disclosure rather than block.

TRANSITIONAL VOCABULARY: the model aliases below are placeholders for the provider-neutral capability tiers (`light` / `standard` / `heavy` / `frontier`) decided in the 2026-06-10 poke-holes session. Today's model_routing contract only validates portable aliases and provider strings; once BEI-76 ships the tier→candidates mapping table and RON-30 the resolution plumbing, rewrite this block in tier vocabulary (sonnet → standard; opus → heavy) and delete this note.

```beislid:model_routing
defaults:
  models: [sonnet]
  mode: prefer
overrides:
  - skills: [spec, blueprint, poke-holes]
    models: [opus]
    mode: prefer
```

## Action policy

Canonical policy lives in `.beislid/action-policy.json` (the evaluator only reads `--policy-file`; inline `modes:` here never reached it). Allows dependency install, git push, PR create/ready/merge, PR review reply, and ticket comment without prompting in both supervised-auto and unattended-auto. The evaluator's sandbox floor still applies: unattended-auto pushes/merges on the default branch or with uncommitted changes downgrade to ask.

```beislid:action_policy
policy_file: .beislid/action-policy.json
```

## Probe cache

```beislid:probe_cache
ttl_hours: 24
```


## Babysit

Allow `/babysit` to use the configured review-response/gate loop and close out automatically when policy permits.

```beislid:babysit
loop:
  use_review_response: true
  run_configured_gates_before_push: true
  wait_interval_seconds: 60
closeout:
  merge:
    mode: auto
    method: merge
    delete_branch: true
  memento:
    mode: auto
  retro:
    mode: auto
    apply_findings: auto
```
