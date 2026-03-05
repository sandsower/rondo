# Label-based filtering for Linear issue selection

**Goal:** Allow Symphony to filter candidate issues by Linear labels, enabling safe coexistence with human issues in shared projects.

**Config:** `tracker.label_filter` -- a list of label names. When set, only issues with at least one matching label are fetched. When nil/empty, current behavior (all issues in matching states).

**Approach:** Server-side GraphQL filtering. Add `labels: { name: { in: $labelNames } }` to the issues query filter when labels are configured. Linear treats multiple filter conditions as AND.

**Files:**
- `config.ex` -- add `label_filter` to tracker schema + getter
- `linear/client.ex` -- add query variant with label filter, select at call time
- `test_support.exs` -- add `tracker_label_filter` config override
- Tests for config parsing and client filtering

## Status

Implemented.
