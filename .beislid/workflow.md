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
