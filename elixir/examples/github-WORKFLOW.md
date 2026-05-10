---
tracker:
  kind: github
  repo: "owner/repo"
  label_filter:
    - rondo
  state_label_prefix: "status:"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
    - Cancelled
workspace:
  root: ~/code/rondo-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:owner/repo.git .
agent:
  adapter: claude_code
  max_concurrent_agents: 2
  max_turns: 20
claude:
  command: claude
  permission_mode: bypassPermissions
  dangerously_skip_permissions: true
  max_turns: 50
  output_format: stream-json
---

You are working on a GitHub issue `{{ issue.identifier }}`.

Issue context:
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. Work only in the provided repository copy.
2. Keep progress visible on the GitHub issue when useful.
3. Treat labels with the configured state prefix as Rondo workflow state.
4. Do not remove non-state labels.
5. Validate the changed behavior before reporting completion.
