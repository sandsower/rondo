# RON-9 Beislið ProcessProvider Adapter — Execution Envelope v0

## Envelope Metadata

- **Schema:** `execution-envelope-v0`
- **Envelope ID:** `ron-9-beislid-process-provider-v0`
- **Source ticket:** RON-28 — "[Envelope] Create execution envelope for RON-9 Beislið ProcessProvider adapter"
- **Target implementation ticket:** RON-9 — "[GH #56] [P1] Implement Beislið ProcessProvider adapter"
- **Related GitHub issue:** sandsower/rondo#56
- **Status:** approved for fixture-backed AFK implementation of RON-9; real Beislið integration remains blocked until approved export artifacts or stable CLI/API outputs are available
- **Created:** 2026-06-09
- **Owning component:** Rondo
- **Upstream envelope dependencies:** BEI-57 external runner ProcessProvider boundary; BEI-59 approved Slice Plan export envelope

## Goal

Implement `process_provider.kind: beislid` as an optional Rondo ProcessProvider adapter that consumes approved Beislið process artifacts without making Beislið own Rondo execution, proof storage, run state, or workspace orchestration.

The adapter should let Rondo use Beislið-owned process semantics for:

- approved Work Contracts, selected slices, and execution envelopes;
- gate, guide, proof, and review expectations;
- action-policy evaluation boundaries;
- model-routing hints;
- capability/probe status and unsupported-feature reporting.

Rondo still owns execution, local workspace state, selected agent adapter invocation, gate/proof artifact persistence, run-ledger evidence, retry behavior, and final delivery artifacts.

## Ownership Boundaries

- **Rondo owns** runtime configuration, process-provider adapter selection, issue execution, workspace lifecycle, gate execution, proof artifact persistence, run-ledger manifests/checkpoints, optional native fallback, and operator-visible failures.
- **Beislið owns** Work Contract semantics, slice-plan/export semantics, execution-envelope semantics, proof requirement semantics, guide/gate selection intent, model-hint intent, action-policy vocabulary/decisions, and process capability metadata.
- **Memento owns** curated memory and durable lessons. The adapter may surface memory-related guide/proof metadata when exported by Beislið, but it must not write to Memento directly.
- **Teotl is not a dependency** for RON-9. Do not add Teotl services, daemons, databases, installer UX, or runtime naming.

## RON-9 Scope

RON-9 should add a Rondo Beislið ProcessProvider adapter behind `process_provider.kind: beislid`.

The implementation should:

1. Extend workflow validation so `process_provider.kind` accepts `native` and `beislid`.
2. Resolve `beislid` to a focused provider module such as `Rondo.ProcessProvider.Beislid`.
3. Keep the existing native provider behavior unchanged.
4. Support fixture-backed loading before real Beislið exports exist.
5. Report clear probe/capability status for available, missing, degraded, and unsupported Beislið features.
6. Preflight the configured Beislið input before the first agent turn so strict mode fails before agent invocation, provider-selected gates, and provider-owned action-policy side effects.
7. Select gates from approved Beislið process artifacts when available.
8. Preserve selected/skipped explanations, warnings, provider metadata, and fallback metadata in gate artifacts.
9. Persist guide/proof selection explanations in a reviewable run-ledger location or explicitly mark unsupported/deferred capabilities.
10. Route action-policy evaluation through Beislið when configured and available.
11. Apply strict vs optional provider behavior consistently with `process_provider.required`.
12. Document the configuration, fixture path, fallback behavior, and blocked real-integration status.

## Non-Goals

- Do not implement Beislið exporter runtime, parser services, schedulers, daemons, databases, or durable proof stores.
- Do not make Beislið required for Rondo. `process_provider.kind: native` must remain the default and continue to work.
- Do not copy Beislið planning semantics into Rondo core. Rondo should consume exported artifacts rather than redefine their meaning.
- Do not require real Beislið export artifacts for fixture-backed tests.
- Do not implement Teotl behavior or Memento writes.
- Do not change Rondo agent adapter contracts except where provider-selected prompts, gates, or policy evaluators already flow through the ProcessProvider seam.

## Existing Rondo Seam

Rondo already has the core seam RON-9 should use:

- `Rondo.ProcessProvider` defines the provider callbacks and normalizes gate-selection envelopes.
- `Rondo.ProcessProvider.Native` preserves current standalone `WORKFLOW.md` behavior.
- `Rondo.AgentRunner` resolves a provider module, builds the first-turn prompt through the provider, selects post-turn gates through the provider, and falls back to native gate selection for optional non-native provider failures.
- `Rondo.Gates` persists selected/skipped/warning/metadata gate-selection envelopes with gate results.
- `Rondo.RunLedger` records provider snapshot/probe metadata in run manifests.

RON-9 should extend this seam rather than introduce a parallel execution path.

## Beislið Input Assumptions

Until real Beislið export artifacts are available, RON-9 may use fixtures that model the approved BEI-57 and BEI-59 boundaries.

A future real input may come from:

- a local approved Slice Plan export manifest;
- an approved execution envelope file;
- a Beislið CLI/API command that returns a stable manifest;
- a configured fixture path used only for tests and early integration scaffolding.

The adapter should treat these inputs as Beislið-owned process artifacts. It must not scrape chat transcripts or Beislið internals.

Recommended configuration shape for RON-9 may stay minimal and fixture-backed, for example:

```yaml
process_provider:
  kind: beislid
  required: false
  # Future/fixture-specific fields may be added only if RON-9 explicitly implements validation.
```

If RON-9 needs a fixture path or CLI command, document the field and validate it explicitly. Do not silently accept unknown required fields or unsupported runner requirements.

## Adapter Behavior Contract

### `id/0`

Return `"beislid"`.

### `capabilities/0`

Return a stable map describing what the adapter can currently do. Fixture-backed RON-9 may report real gate selection and action-policy support while marking richer features as degraded or unsupported.

Recommended capability keys:

```elixir
%{
  gate_selection: "beislid_export" | "fixture" | "unsupported",
  guide_selection: "beislid_export" | "unsupported",
  action_policy: "beislid_evaluator",
  model_routing_hints: "beislid_export" | "unsupported",
  proof_requirements: "beislid_export" | "unsupported",
  probes: "beislid"
}
```

### `probe/1`

Probe the configured Beislið input source without mutating workspace state.

Probe result expectations:

- `:ok` when required configured input exists, is readable, and all required exported capabilities used by Rondo are available.
- `:degraded` when optional or richer features such as guides/model hints/proof requirements are unavailable but gate selection can still proceed or native fallback is allowed.
- `:missing` when required input is absent.
- `:unsupported` for features the current adapter intentionally cannot consume.

Probe metadata should explain each feature separately instead of collapsing all failures into one opaque error.

### Pre-agent-turn preflight

RON-9 must add an explicit provider preflight after provider resolution and before the first prompt/agent invocation. The preflight should load or validate the configured Beislið source, call the provider probe/load path, and decide strict vs optional behavior before the agent adapter can modify the workspace or provider-selected gates/action-policy decisions can run.

Preflight expectations:

- `process_provider.required: true` plus missing, invalid, unapproved, paused, superseded, or unsupported required Beislið input fails before adapter invocation.
- `process_provider.required: false` may continue with degraded status or native fallback only after recording the unavailable capability and fallback reason.
- Preflight failures should be visible as operator errors or run-ledger/checkpoint metadata rather than late post-turn gate failures.
- Existing workspace creation and configured `before_run` hooks currently happen before provider resolution in `Rondo.AgentRunner`; RON-9 must either keep the preflight boundary scoped to agent/provider execution or deliberately move preflight earlier if required Beislið input should block hooks too.
- Tests should prove required-mode invalid fixtures prevent the agent adapter from being invoked at all, and should pin whether `before_run` hooks are expected to run or be skipped on preflight failure.

### `select_gates/1`

Select runnable Rondo gate definitions from approved Beislið process artifacts.

The returned selection must include:

- `gates`: runnable Rondo gate maps compatible with `Rondo.Gates.run/3`;
- `selected`: human-readable reasons for each selected gate;
- `skipped`: human-readable reasons for relevant gates/proofs not selected;
- `warnings`: unsupported, degraded, or fixture-only caveats;
- `metadata`: at least provider id, source kind/path/ref when safe, stage, and artifact/schema identifiers when available.

If no Beislið gates apply but the export says proof is satisfied by other required evidence, return an all-skipped gate-selection envelope with clear `skipped` reasons and metadata. If required proof cannot be represented safely as Rondo gates or reviewable references, return an error so strict/optional behavior can handle it.

### `select_guides/1`

Guide selection is metadata, not a runtime dispatcher. The current callback shape returns `{:ok, [map()]}` or `{:error, term()}` and does not carry a separate metadata envelope. If Beislið guides are not yet exported, RON-9 should return `{:ok, []}` and report unsupported/deferred guide metadata through `probe/1`, run-ledger/provider snapshot metadata, or an explicitly implemented callback-envelope extension.

If guides are exported, return reviewable guide descriptors that can shape prompts, handoffs, or human instructions without executing arbitrary skills. Missing required guide capability should produce an unsupported-feature result or provider error rather than silently widening autonomy.

### `prompt/2`

The Beislið provider may augment the first-turn prompt with approved Work Contract, slice, envelope, guide, proof, and pause-condition context. It should not replace Rondo's issue context with opaque Beislið internals.

Prompt content must be transcript-safe and should avoid embedding raw logs, secrets, or unrelated export payloads. Prefer concise summaries plus artifact references when available.

### `model_routing_hints/1`

Return Beislið-exported model preferences only when present and supported. Hints are preferences unless the export marks them required. If required model hints cannot be honored by the selected Rondo agent adapter, the provider should report a capability gap or pause condition rather than silently ignoring the requirement.

### `proof_requirements/1`

Return exported proof requirements as reviewable maps when available. RON-9 does not need to make Rondo a Beislið proof store; Rondo should persist its own gate/proof evidence and may reference Beislið proof IDs in gate-selection metadata.

### Guide/proof explanation persistence

RON-9 must not claim guide/proof explanation support unless the explanations are persisted in a reviewable Rondo-owned artifact. Acceptable persistence paths include:

- gate-selection metadata when a guide/proof decision directly explains selected or skipped gates;
- run-ledger checkpoints, manifest/provider snapshot metadata, or `probe/1` metadata for guide/proof selections that are not gate-specific;
- explicit `unsupported`/`deferred` probe metadata when guide/proof exports are not available in fixture-backed RON-9.

The chosen path should include provider id, source artifact/schema/ref when safe, selected/skipped reasons, warnings, and required-vs-optional status. If RON-9 defers non-gate guide/proof persistence, its tests and docs must say so explicitly instead of treating the upstream acceptance as satisfied.

### `evaluate_action_policy/3`

Use Beislið's action-policy evaluator boundary for configured side effects. The adapter should return the same decision envelope shape Rondo already validates and persists.

If Beislið policy evaluation is unavailable:

- `process_provider.required: true` must fail clearly before the side effect.
- `process_provider.required: false` may fall back to the native/configured Rondo action-policy evaluator only when that fallback is explicit, logged, and reflected in metadata or warnings.

## Strict vs Optional Provider Semantics

`process_provider.required` controls behavior when the Beislið provider cannot supply a required capability.

### Optional provider (`required: false`)

Optional mode should preserve Rondo's current resilience:

- Gate-selection failure may warn and fall back to native flat gates.
- Fallback gate-selection metadata must include the original provider id and fallback reason.
- Native fallback must use the native action-policy evaluator for fallback gates.
- Unsupported optional features such as guide selection or model hints should be reported as degraded/unsupported without stopping unrelated execution.
- Optional fallback must not silently ignore exported `deny` or `ask` autonomy constraints if the Beislið artifact was successfully loaded and marked them required.

### Required provider (`required: true`)

Strict mode should fail closed:

- Missing or invalid Beislið input blocks the run.
- Required guide/gate/proof/model/action-policy capabilities that cannot be represented block the run.
- Invalid, draft, paused, superseded, or unapproved Beislið export artifacts block the run.
- Required action-policy evaluation failures block side effects.
- Errors should name the missing capability and safe remediation, such as providing an approved export artifact or switching back to `native`.

## Fixture-Backed Implementation Path

RON-9 may proceed before real Beislið exports exist by adding test fixtures that model the approved envelopes.

Recommended fixture coverage:

1. A valid approved Beislið export with one runnable gate and one skipped guide/proof explanation.
2. A valid export with no runnable gates but all-skipped explanations.
3. A missing/invalid/unapproved export.
4. A required-mode preflight failure that prevents the agent adapter from being invoked.
5. An optional-mode degraded preflight that records fallback/degraded metadata before continuing.
6. A provider gate-selection failure that falls back to native when optional.
7. The same failure blocking clearly when required.
8. A policy-evaluator fixture proving provider action-policy decisions flow into gate execution.

Fixtures should live under the existing test fixture/support structure chosen by RON-9 and remain small, explicit, and schema-labeled. They must not require the Beislið repo to be installed.

## Expected Files for RON-9

RON-9 will likely touch:

- `elixir/lib/rondo/config.ex`
- `elixir/lib/rondo/process_provider.ex`
- `elixir/lib/rondo/process_provider/beislid.ex` or equivalent new module
- `elixir/lib/rondo/agent_runner.ex` only if the existing provider resolution/fallback seam needs small adjustments
- `elixir/lib/rondo/run_ledger.ex` only if provider snapshot/probe metadata needs to include Beislið-specific safe fields
- `elixir/test/rondo/process_provider_test.exs`
- `elixir/test/rondo/agent_adapter_test.exs`
- fixture/support files for Beislið export examples
- `elixir/README.md`, `SPEC.md`, and/or `elixir/docs/run_ledger.md` for documented behavior

This list is guidance, not permission to broaden scope beyond the adapter contract.

## Proof Requirements for RON-9

RON-9 should include tests that prove:

- `process_provider.kind: beislid` validates and resolves to the Beislið provider.
- `native` remains the default and existing native behavior is unchanged.
- Beislið fixture gate selection returns runnable gates plus selected/skipped/warning/metadata envelopes.
- Gate artifacts persist provider gate-selection explanations.
- Guide/proof explanations are persisted in the chosen run-ledger location, or unsupported/deferred status is explicit and tested.
- Optional Beislið preflight or gate-selection failure falls back to native with warnings and fallback metadata.
- Required Beislið preflight or gate-selection failure stops clearly before unsafe execution.
- Provider action-policy evaluation is used for Beislið-selected gates.
- Native action-policy evaluation is used for native fallback gates.
- Probe/capability metadata reports missing/degraded/unsupported features clearly.
- Invalid, missing, or unapproved fixture input fails clearly according to `required` semantics.

Configured verification for this repo remains:

```bash
cd elixir && make all
```

## Acceptance Mapping

RON-28 acceptance:

- **`process_provider.kind: beislid` behavior is implementable with explicit fallback/strict-run semantics.**
  - This envelope defines config resolution, provider callbacks, gate selection, action-policy routing, optional fallback, required failure behavior, probe metadata, and fixture-backed tests.
- **Real integration remains blocked until Beislið export artifacts are available; fixture scaffolding is allowed.**
  - This envelope explicitly permits fixture-backed loading and blocks real integration until approved Beislið export artifacts or equivalent stable CLI/API outputs exist.

RON-9 acceptance supported by this envelope:

- **`process_provider.kind: beislid` works when configured.**
  - RON-9 should add config validation, module resolution, and a provider module with fixture-backed input.
- **Beislið unavailable/invalid config fails clearly when required and warns/falls back when optional.**
  - Strict vs optional semantics above define the required behavior.
- **Gate/guide/proof selection explanations are stored in the ledger.**
  - Gate-selection envelopes must include selected/skipped/warnings/metadata and flow through existing gate artifact persistence. Non-gate guide/proof explanations must either be persisted in run-ledger checkpoint/manifest/provider metadata or explicitly reported as unsupported/deferred in fixture-backed RON-9.
- **Native fallback remains unaffected.**
  - Native remains default, and optional fallback explicitly routes through native gate selection and native action-policy evaluation.

## AFK Pause Conditions for RON-9

Pause and ask for human guidance if any of these occur:

- Implementing the adapter requires real Beislið export artifacts that are not yet available and cannot be represented by approved fixtures.
- Beislið export schema details are ambiguous enough to change RON-9 behavior rather than only fixture naming.
- The work needs Beislið runtime/exporter changes, parser services, schedulers, daemons, Teotl behavior, or Memento writes.
- Optional fallback would ignore an exported required `deny`, `ask`, proof, guide, model, or action-policy constraint.
- Required provider behavior cannot fail closed without hiding the underlying missing capability.
- Existing native ProcessProvider behavior or flat gate behavior would regress.
- Configured proof cannot pass after the normal bounded retry/fix loop.

## Approval

This envelope is approved as the implementation boundary for RON-9. RON-9 may implement within this contract without further product steering, pausing only on the AFK pause conditions above.
