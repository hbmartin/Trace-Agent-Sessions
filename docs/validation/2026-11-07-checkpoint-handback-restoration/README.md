# Checkpoint handback and restoration validation

Follow-up to merged [PR #92](https://github.com/hbmartin/Trace-Agent-Sessions/pull/92).

Frozen implementation and harness: `9db1b4fdf2f6dc2d1ce586853df061cc2badbdff`.
Fresh base: `06aa5598a16239446073e786f714fec653c2432e`.
Pinned #92 baseline: `8706c87e3e33b9ac38ddc4a2492fbc5ae060af34`.

## Publication and limitations

The user instructed **“Skip UI and measurements; publish with limitations.”** No UI case or paired optimized workload ran in this follow-up. All twelve selected UI identifiers matched compiled discovery, but their native behavior is unverified. The baseline/candidate native-offset diagnosis and final native restoration verification remain incomplete. The strengthened UI assertions are compiled, not executed.

Paired enqueue, acceptance, backlog, and mailbox measurements at 1,000 and 10,000 inputs, including oversized and structural variants, were skipped. Optimized workload smokes were also skipped. The Release app build passed; that is not a performance measurement. Complete suites and the three full Release comparison pairs were outside the original scope. **No local 10% performance-acceptance claim is made.** See [the user waiver](publication-waiver.json) and [verification](verification.json).

## Changes

Shared-ledger registrations stay dormant when displaced. Stopping or deallocating the newest registration elects the latest remaining registration for the database family and wakes it outside the ledger lock. Extracted checkpoint updates carry their publication activity atomically; interrupted publication returns compatible updates and activity together. Stopped owners cannot publish or regain ownership. Idle waiting remains passive, shutdown remains joined, and handback reports paused streams without retrying initialization.

App preparation drops lexical/structural fields after upstream metadata-topology processing, avoiding auxiliary-only fragments. Generic mailbox deliveries still bound all retained path roles to 128 entries. Unreserved watermarkless groups cannot merge into tracked groups. Undelivered ownership is claimed before suffix allocation. DEBUG suppression precedes observable diagnostics, and invocation receipts report the actual returned transfer outcome. Test injection uses terminal outcomes with throwing timeout/cancellation rather than ambiguous Boolean polling; no-watermark checks inspect the model's actual ledger. Held synchronous acceptance tests use a dedicated queue instead of blocking the cooperative pool.

The model-level restoration regression exposed an offset bug: automatic reset restoration copied a saved bookmark anchor into `requestedMessageID`, selecting the native search route, whose offset is zero. Restoration now preserves the saved bookmark route and issues a fresh scroll request, while a real pending search target retains its route. Before the fix, `testAutomaticBookmarkRestorationDoesNotBecomeZeroOffsetSearch` failed one test with two reported issues; it passes after the fix and in all five race repetitions. This supports the model fix, **not a claim that the native UI offset has been verified**. UI diagnostics now require a fresh post-reset restoration receipt and retain bookmark, geometry, and subsequent frame evidence when run.

Benchmark payload construction moves before timing. Enqueue timestamps are separate from prepared paths. Retirement reports structured workload failure instead of crashing; extraction keeps baseline/candidate auxiliary expectations aligned with each revision's preparation contract. Script tests cover these contracts. No performance result is inferred from those tests.

## Completed validation

- 708 focused cases passed: indexing 207, watcher 13, metadata 64, sidecar dependency 27, App follow-up 397.
- 62 focused ownership cases passed in five repetitions, adding 310 executions.
- 73 script tests passed.
- Debug and Release app builds, external-client compatibility, project drift, signing, network surface, frozen-input validation, and pinned whitespace checks passed.
- All 62 race and 12 UI selectors matched compiled XCTest discovery (948 identifiers).
- The expected model-restoration negative control failed one test with two reported issues before the source fix; the final frozen source passes it.

The separately isolated `testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData` failed on both candidate and unchanged pinned #92 production source: one failed test and two reported issues, a state timeout and caught `CancellationError`. Those fresh results are separate from the 708 passing cases. The comparison establishes matching symptoms, not a new root cause. See [classification](known-transcript-classification.json).

## Evidence and retained attempts

[source-hashes.json](source-hashes.json) is the canonical hash map for 325 regular implementation/harness blobs at the frozen candidate. Every entry was checked against both Git blob and worktree bytes. Validation documents are excluded to avoid self-reference; the evidence-only commit changes no implementation input.

[Command receipts](attempts.json) preserve actual commands, timestamps, exit codes, commits and dirty input hashes. Earlier smoke failures remain: suppressed background callbacks polluted invocation history, and two handback tests incorrectly expected a ledger reservation alone to initiate work. Both were corrected before freezing and rerun successfully. An early nonexistent selector was rejected before XCTest; an initial script trial failed because of helper extraction/metric expectations, then the focused and complete script suites passed. The pre-fix restoration product snapshot and expected negative-control failure remain local. Baseline UI diagnostic builds were prepared but no UI test was run; an incorrect diagnostic table name was corrected before execution. The final controller was intentionally held before measurement instrumentation after the user waiver; this was not a test failure.

[raw-artifacts.json](raw-artifacts.json) records exact-byte hashes and provenance under `/Volumes/Pro2T/TraceValidation/checkpoint-handback-restoration-followup`. Raw payloads are **local-only**, not downloadable repository/CI artifacts. XCTest bundles and preserved binaries remain at receipt/provenance paths. Historical validation documents and prior raw payloads are unchanged. No skipped check has been fabricated.

No migration, index-format change, breaking public interface, application retry timer, or merge is included.
