# Preserve checkpoint boundaries and bound watcher delivery

Follow-up to merged [PR #90](https://github.com/hbmartin/Trace-Agent-Sessions/pull/90).
Base: `a45cf45a296133a00d89896bc581656c2951e155`.
Frozen final candidate: `709e65afe9955006ce2fef97a7262ea7eb4ac19a`.
Production/XCTest validation commit: `bb1f924df2ddaddfbdb5de693e1f59c679dd5f5d`.
Pinned targeted baseline: `3beaf0db721ad29a04de06d71a00e0f9a751d1ae` (the exact merge-base tree).

## Changes

Committed resets widen effective obligation roots alongside reconciliation. Whole-scan failure attribution retains global failure semantics when roots are absent, while path-only records keep narrow attribution. Successful seeding and newly retained proofs register owner-scoped, coalescing wakeups before idle waits can finish. Waiting remains passive; stopped or retired subscriptions cannot publish or retain an idle scheduler.

The additive opaque `IndexCheckpointInputs` type prepares canonical reservation data off the main actor. Existing reservation and scheduler signatures remain compatible. Watcher preparation filters captured roots/providers in the background; current-owner validation precedes enrollment. Deliveries contain at most 128 indexing/reconciliation inputs and grouped boundaries contain at most 128 callbacks. Oversized callbacks retain one complete checkpoint obligation across fragments and only their first fragment can admit recovery. Rejected boundaries stop before later fragments; partially delivered unpaid work follows same-database buffered ownership.

Counting uses maintained stream outcome totals and narrow record queries. Instrumentation cannot silently replace existing counts or kind declarations. The benchmark has separate bounded producer/delivery deadlines, operation-wide cancellation, and shared setup outside timing. Both extracted revisions exercise actual normalization and reservation. No universal performance improvement is claimed.

## Completed independent validation

- 683 focused Core/App cases passed: 196 indexing, 13 watcher, 64 metadata, 27 sidecar-dependency, and 383 App follow-up cases.
- 37 ownership cases passed in five serial repetitions: 185 additional executions.
- 70 script tests passed at the final candidate, including strict synchronization, both timeout phases, and setup placement for both extraction layouts.
- Debug/Release builds, existing/additive external-client compatibility, project drift, signing, network surface, frozen-input validation, and pinned whitespace checks passed.
- All 37 race selectors and 12 UI selectors match compiled discovery (923 identifiers).
- Synchronized Release tools compiled; eight-obligation enqueue/acceptance/backlog/mailbox correctness smokes passed. Final mailbox tools also passed 257-event smokes and verified the candidate's 128-input delivery bound. These smokes are not performance acceptance.
- An isolated lifetime probe confirms an idle scheduler releases without explicit stop and cannot publish after retirement.
- All 325 canonical source hashes match the final frozen commit and worktree. [Input equivalence](frozen-input-equivalence.json) records that the final change affects only benchmark setup and its script test; production/XCTest/project/dependency inputs remain identical to the fully tested commit.

## Preserved failures and provenance

`testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData` fails identically on the candidate and unchanged pinned #90 baseline: one failed test with two assertion failures (state timeout and `CancellationError`). It is separate from the 683 passing cases. Both logs and result bundles are retained in [classification](known-transcript-classification.json).

Exploratory Swift compiler errors were corrected before candidate validation. Completed earlier-candidate runs, intentional validation holds, all failed attempts, and original hash maps remain preserved. Each [command receipt](attempts.json) retains its actual commit and any dirty input hashes; none is relabeled as final validation.

## UI and targeted acceptance

The user requested publication now with these remaining checks incomplete. This is a ready PR for review; it does not establish UI or targeted performance acceptance. The current request does not authorize interrupting competing checks or supply fresh desktop-idle confirmation. See [publication limitations](publication-limitations.json).

The twelve selected UI tests have not completed acceptance. Fresh desktop-idle confirmation and a quiet host are required before execution.

Paired targeted measurements at 1,000/10,000 obligations have not completed. Tool compilation and correctness smokes do not establish CPU, latency, or footprint acceptance.

Complete suites and the three full Release comparison pairs remain omitted as selected. No local 10% performance-acceptance claim is made. Required UI and targeted acceptance must be evaluated separately from the independent checks above.

## Evidence availability

[verification.json](verification.json) records exact acceptance state. [source-hashes.json](source-hashes.json) is the canonical map for the frozen final candidate, excluding validation documentation to avoid self-referential hashing. Historical maps and reports remain unchanged.

Raw payloads are **local-only**, not downloadable repository/CI attachments. [raw-artifacts.json](raw-artifacts.json) records individual hashes and provenance under `/Volumes/Pro2T/TraceValidation/checkpoint-boundary-delivery-followup`. XCTest bundles remain under `/Volumes/Pro2T/TraceWorktrees/rebuild-live-updates/build/`. The external per-command ignore excludes only unrelated untracked `reviews_triage/` probes from unexpected build-input detection; tracked and vendor inputs remain validated.

No migration, index-format change, breaking public interface, application retry timer, or merge is included.
