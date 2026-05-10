<!-- beislid-workflow: v1 -->

# Beislið workflow config — rondo

## Issue tracker

GitHub Issues on `sandsower/rondo`, accessed via the `gh` CLI.

```beislid:ticket_source
type: cli
command: 'gh issue view {id} --json title,body,labels'
id_pattern: '^\d+$'
link_template: 'https://github.com/sandsower/rondo/issues/{id}'
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

## Probe cache

```beislid:probe_cache
ttl_hours: 24
```
