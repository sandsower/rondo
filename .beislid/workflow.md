<!-- beislid-workflow: v1 -->

# Beislið workflow config — rondo

## Issue tracker

Linear issues in the personal `teotl` workspace, team `rondo`, accessed via Linear MCP.

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

Run the same verification as CI before shipping.

```beislid:gates
- name: elixir-ci
  command: 'cd elixir && make all'
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
