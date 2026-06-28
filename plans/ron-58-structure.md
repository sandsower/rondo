# Detect and handle live ticket updates during active Rondo runs — Implementation Structure

## Durable Decisions
- Use a poll-and-diff runtime check on active runs rather than tracker-specific special cases.
- Snapshot the issue at dispatch with enough tracker metadata to compare later: title, description/body, updated_at, labels, relations/blockers, attachments/links, comments, and any tracker-specific fields exposed by Linear.
- Classify updates deterministically into: no-op metadata, self-authored workpad/progress comments, new requirements, reviewer/operator feedback, scope/risk/policy changes, and conflicting/ambiguous instructions.
- Persist the dispatch snapshot and every detected update checkpoint in the run ledger.
- Do not silently continue from stale context; choose ignore, inject, or pause and record the choice.
- Use the existing continuation turn path to inject refreshed context; do not restart the issue from scratch.

## Phase 1: Snapshot foundation + ledger checkpoints (AFK)
Cuts through: tracker fetches, ledger, tests
Delivers: a dispatch snapshot record and a new update-checkpoint artifact for one changed field (issue body/title)
Validates: Rondo can persist a richer issue snapshot and record that a live update was observed

## Phase 2: Live diff detection + self-update suppression (AFK)
Cuts through: orchestrator poll/reconcile, tracker snapshot fetches, ledger, tests
Delivers: active runs compare current Linear state against the dispatch snapshot; self-authored workpad comments are ignored; body edits and new Linear comments are detected
Validates: live updates are detected without self-interrupt loops

## Phase 3: Action routing for inject/pause decisions (AFK/HITL)
Cuts through: orchestrator, agent-runner continuation guidance, interrupt payloads, tests
Delivers: safe injected continuations for substantive updates, pause interrupts for conflicting/ambiguous or risk/policy-changing updates, and recording of the chosen action in the run ledger
Validates: the next turn receives refreshed context when safe, and manual guidance is required when not

## Phase 4: Observability surface (AFK)
Cuts through: run archive/presenter/dashboard projections, tests
Delivers: dashboard and archive show that an active run observed a ticket update and what action was taken
Validates: operators can see the update checkpoint history without reading raw logs
