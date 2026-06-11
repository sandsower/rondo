#!/bin/sh
# Live-E2E action-policy wrapper: REAL beislid evaluator + an explicit, scoped
# policy override that allows only tracker.issue.transition for the disposable
# test issue. Used via RONDO_E2E_ACTION_POLICY_COMMAND (auditable opt-in).
exec beislid "$@" --policy-file "$(dirname "$0")/e2e_action_policy.json"
