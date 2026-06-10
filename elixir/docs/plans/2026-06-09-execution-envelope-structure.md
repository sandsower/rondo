# Execution Envelope v0 — Implementation Structure

## Context

Execution Envelope is the provisional internal name for the approved AFK boundary around a Beislið Work Contract or child slice. Naming/branding is deferred until the Teotl release; Teotl is only acknowledged as the future thin bootstrapper, not a dependency for this work.

## Work Contract Summary

- **Kind:** multi_slice
- **Status:** approved for decomposition
- **Source:** conversation on moving Rondo/Beislið HITL planning tickets into AFK-workable units
- **Problem:** several cross-project automation tickets still require human decisions during execution because schema, autonomy, proof, and output boundaries are not pre-approved.
- **Desired outcome:** front-load those decisions into an Execution Envelope v0 so agents can implement bounded slices AFK and pause only on explicit conditions.
- **Constraints:** keep this minimal, do not design Teotl now, do not introduce a new runtime service, do not duplicate Beislið/Rondo/Memento ownership.
- **Ownership boundary:** Beislið owns planning/proof semantics; Rondo owns execution/run evidence; Memento owns memory/learning; Teotl later bootstraps broad installation/configuration.

## Durable Decisions

- **Execution Envelope is a packaging/approval layer, not task semantics.** It references or includes a Work Contract, Slice Plan/child contract, proof requirements, autonomy policy, dependencies, pause conditions, and expected delivery.
- **Canonical semantics stay component-owned.** Work Contract/Slice Plan/Proof Requirement remain Beislið-owned; Execution Request/Delivery Artifact remain Rondo-owned; MemoryProvider remains Memento-owned.
- **HITL becomes pre-approval, not runtime steering.** A human approves the envelope once; implementation proceeds AFK within allow/ask/deny and pause boundaries.
- **Teotl is deferred.** Do not add Teotl templates, installer profiles, or bootstrap UX in this slice.
- **Naming is provisional.** Use `execution-envelope-v0`; revisit naming before Teotl release.

## Phase 1: Execution Envelope v0 contract fixture (HITL -> AFK)

Cuts through: Beislið planning vocabulary, Rondo execution input, cross-project issue mapping.

Delivers:
- A concise `execution-envelope-v0` field contract.
- One human-readable example and one machine-readable example for a low-risk AFK slice.
- Explicit allow/ask/deny, proof requirements, pause conditions, dependencies, and expected delivery fields.

Validates:
- Humans can approve the boundary before implementation.
- Existing Beislið/Rondo concepts are sufficient; no Teotl/runtime service is needed.

Blocking:
- Must be approved before treating later HITL tickets as AFK units.

## Phase 2: Beislið child Work Contract decomposition envelope — #58 (AFK after Phase 1)

Cuts through: break-spec behavior, Work Contract v1, child slice/parent references, proof requirements.

Delivers:
- An approved envelope for Beislið #58.
- Child Work Contract / Slice Plan decomposition shape with explicit acyclic dependencies, proof, human decisions, and execution recommendation fields.

Validates:
- A previously HITL schema ticket can be implemented from an envelope without additional steering.

Parallelism:
- Can run in parallel with Phase 3 once Phase 1 is approved.

## Phase 3: Beislið external runner ProcessProvider contract envelope — #21 (AFK after Phase 1)

Cuts through: Beislið external-runner semantics, Rondo ProcessProvider needs, capability/probe behavior.

Delivers:
- An approved envelope for Beislið #21.
- Contract for operations such as probe, load/export approved contracts, select gates/guides, proof requirements, model hints, and action policy evaluation.

Validates:
- Rondo can consume Beislið process semantics through a stable boundary without Beislið owning execution.

Parallelism:
- Can run in parallel with Phase 2.

## Phase 4: Rondo delivery artifact envelope — #60 (AFK now)

Cuts through: Rondo run ledger, source contract metadata, proof references, redaction/portability, Beislið reconciliation needs.

Delivers:
- An approved envelope for Rondo #60.
- Stable delivery artifact shape with run id, source contract/envelope hash, summary, branch/PR links, proof status, interrupts, risks, and deferred work.

Validates:
- Completed runs have reviewable output that Beislið and humans can consume without scraping logs.

Parallelism:
- Can start immediately; it is self-contained and does not block on Beislið #58/#59.

## Phase 5: Beislið approved Slice Plan export envelope — #59 (AFK, blocked by Phases 2/3)

Cuts through: child Slice Plan artifacts, machine-readable export, human-readable markdown, validation/doctor guidance.

Delivers:
- An approved envelope for Beislið #59.
- Versioned export manifest preserving parent/child/proof/dependency information with optional runner-specific fields.

Validates:
- Rondo can ingest approved work without scraping chat or requiring Beislið internals.

Blocking:
- Depends on Phase 2 child slice shape and Phase 3 external-runner contract.
- Blocks final Rondo #56 integration.

## Phase 6: Rondo Beislið ProcessProvider adapter envelope — #56 (AFK with fixtures, real integration after Phase 5)

Cuts through: Rondo ProcessProvider seam, Beislið CLI/API/probe, gate/guide/proof selection, ledger explanations, native fallback.

Delivers:
- An approved envelope for Rondo #56.
- Fixture-backed adapter implementation path now; real provider integration once Beislið #59 exists.

Validates:
- `process_provider.kind: beislid` can be required for strict runs or optional with clear fallback.

Blocking:
- Requires Phase 3/5 for non-fixture integration.

## Phase 7: Pilot hardening and canary envelopes (AFK with bounded HITL review)

Cuts through: memento-vault or another low-risk pilot repo, gate fixtures, memory contract, canary execution, failure taxonomy.

Delivers:
- Envelopes for available pilot hardening work such as memento-vault CI gates/schema checks/memory contract.
- Canary criteria for low-risk AFK use: no silent failures, fail-closed policy, useful delivery artifacts, bounded retries, explicit pauses.

Validates:
- The envelope approach reduces manual steering before multi-slice orchestration exists.

Parallelism:
- Can run alongside Phases 2-6 where pilot work is not blocked by missing selector/clean-eval support.

## Deferred Phase: Parent/slice graph execution — Rondo #59 + Beislið #60

Cuts through: dependency graph execution, parent reconciliation, completed/failed/paused child status, integration slice routing.

Status:
- Intentionally deferred until single-slice envelope execution is boring and delivery artifacts exist.

Blocking:
- Requires Beislið #60 reconciliation and Rondo #60 delivery artifacts.

## AFK Pause Conditions for All Phases

- Required schema/ownership boundary is missing or contradicted.
- Implementation requires destructive, secret-bearing, production-deploy, or unapproved remote actions.
- Required proof cannot pass after bounded retry.
- Dependency artifact is missing, invalid, or has a hash/version mismatch.
- Agent would need to broaden scope beyond the approved envelope.
- Naming/branding beyond provisional `Execution Envelope` becomes blocking; defer to Teotl release instead.

## Recommended Parallel Workstreams

1. **Contract/export stream:** Phases 1, 2, 3, then 5.
2. **Runner/output stream:** Phase 4 immediately; Phase 6 fixture scaffolding after Phase 1.
3. **Pilot hardening stream:** Phase 7 for available low-risk project-gate/memory tasks.

Do not start the deferred parent/slice graph execution until Phases 4-6 have canary evidence.
