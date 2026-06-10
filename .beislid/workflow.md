<!-- beislid-workflow: v1 -->

# Beislið workflow config — rondo

## Issue tracker

Linear issues in the personal `teotl` workspace, team `rondo`, accessed via Linear MCP.

Tracker duality: these Linear issues mirror GitHub issues on `sandsower/rondo`. **Linear is canonical for state** (Todo/In Progress/Done); **GitHub is canonical for issue body and discussion** — fetch the GH body via `gh issue view` when the Linear description says "see Source link". When work completes, close both sides. Closing an envelope ticket (`[Envelope] ...`) never closes the implementation ticket it wraps — the envelope is the approval artifact, not the implementation (see the RON-10 reconciliation, 2026-06-10).

```beislid:ticket_source
type: mcp
tool: mcp__linear_personal__get_issue
id_pattern: '^RON-\d+$'
link_template: 'https://linear.app/teotl/issue/{id}'
```

```beislid:branch_pattern
^[^/]+/([a-z]+-\d+)
```

```beislid:ticket_update
type: mcp
comment_tool: mcp__linear_personal__save_comment
issue_tool: mcp__linear_personal__save_issue
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

## Quality gates

Cheap gates first for iteration; `elixir-ci` is the pre-PR aggregate matching CI.

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
- name: elixir-ci
  stage: pre-pr
  command: 'cd elixir && make all'
  cost: expensive
```

## Model routing

Sonnet-tier models handle implementation, review-fix, and babysit-style work (validated by the 2026-06-10 envelope batch); planning and adversarial skills prefer a stronger model. `mode: prefer` everywhere — fall back with disclosure rather than block.

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

Allow supervised agents to install dependencies, push, and post PR review replies without prompting.

```beislid:action_policy
modes:
  supervised-auto:
    rules:
      dependency-install: allow
      git-remote: allow
    actions:
      dependency.install: allow
      git.push: allow
      gh.pr.merge: allow
      pr.review.reply: allow
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
