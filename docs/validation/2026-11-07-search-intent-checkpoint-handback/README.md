# Search intent and checkpoint handback validation

Follow-up to merged [PR #93](https://github.com/hbmartin/Trace-Agent-Sessions/pull/93).

Frozen implementation and harness: `24ab4b2d48539e6ba99f0ce2ad8338af1c3cba0a`.
Fresh base: `9de536b4e918f0177c88c0d805170608de1e6bd8`.
Pinned #93 baseline: `4b1daa6449ddbe4f40bc852dc7d15d1ce00ee706`.

## Publication and limitations

The user requested **“open ready PR”** after the implementation summary disclosed that selected UI tests and paired measurements were unrun. Publication proceeds with those limitations. **No selected UI case or paired targeted measurement ran in this follow-up.** Native restoration and performance acceptance remain unverified; fresh desktop-idle confirmation has not been inferred. See [the publication instruction](publication-instruction.json).

The thirteen selected UI identifiers were verified against compiled discovery, including the new pending-search/bookmark coexistence case. Paired enqueue, acceptance, backlog, and mailbox workloads at 1,000 and 10,000 inputs were not executed before publication, including oversized, structural, and alternating tracked/untracked variants. Small optimized correctness smokes below establish harness behavior, not performance acceptance. Complete suites and three full Release comparison pairs are omitted by the approved scope. **No local 10% performance-acceptance claim is made.**

## Changes and scope

Automatic navigation captures a pending search target separately from the saved bookmark, with a stable message reference and private intent token. An unchanged pending search controls immediate positioning while the bookmark remains independently saved. Consuming the target, newer scrolling or explicit clears, navigation, replacement, and termination supersede captured intent. Generation/source ownership and intent revisions are revalidated after suspensions. Temporary absence and read failures remain pending; authoritative coverage of a missing target settles search intent and uses the latest valid bookmark. UI lookup waits for the reindexed source session before matching its fresh native restoration receipt.

Deinitialization idempotently releases the scheduler installation's reset fence. Explicit stop retains unregister, cancel, join, then fence-release ordering. This is defensive hardening: the real-transition regression characterizes active-worker lifetime and successor publication, without claiming that the reported old deallocation stall reproduced. Returning unpublished checkpoints now rejects values below the compatible stream frontier; equal-watermark handback, significant activity, generation/epoch rejection, and the database saver's same-epoch maximum protection remain intact. Cached paused/uninitialized state and a change revision avoid stream scans on eligibility checks, with full-recomputation consistency tests.

The DEBUG delivery helper returns a terminal result recorded before later cancellation or timeout. Cancellation before completion still throws. Transcript and metadata preparation share the consumed-topology clearing policy. Public interfaces, segment budgets, tracked/untracked merge guard, no-compatible-owner behavior, and restart-driven initialization remain unchanged. Optional dedicated-test-queue wrapper cleanup is deferred.

## Completed validation

- 717 focused cases passed: indexing 210, watcher 13, metadata 64, sidecar dependency 27, App follow-up 403.
- 71 ownership cases passed in five repetitions, adding 355 executions.
- 75 script tests passed.
- Debug and Release app builds, external-client compatibility, project drift, signing, network surface, frozen-input validation, and pinned whitespace checks passed.
- All 71 race and 13 UI selectors matched 958 compiled XCTest identifiers.
- Both optimized framework/workload builds passed. Each revision passed three checkpoint correctness smokes at eight obligations and four mailbox variants at 257 inputs, including fixture/timestamp/collector release assertions.
- Injected harness retirement and retained-fixture negatives exited 1 with structured errors. No production mailbox source was changed for those controls.

New regression tests were overlaid on unchanged pinned #93 production source. Two tests failed with four assertion issues: late checkpoint callbacks were `[200, 100]` rather than `[200]` (the database still persisted 200), and the bookmark message displaced a distinct pending search target. The final candidate passes both regressions and the five repetitions. These are test-only overlays; hashes and commands are retained.

The separately isolated `testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData` failed on both the frozen candidate and fresh pinned #93 production source: one failed test, two issues, a state timeout and caught `CancellationError`. Those results are excluded from the 717 passing cases. The comparison establishes matching symptoms, not a new root cause. See [classification](known-transcript-classification.json).

## Harness methodology

The mailbox harness records pre-payload and post-setup footprints separately. Signed retained growth uses the pre-payload baseline. Prepared fixtures, timestamp storage, producer captures, and payload-sized collector state leave scope before the two-second retained sample; weak lifetime assertions verify release while the mailbox stays alive. Timestamps are read once per delivery, and oversized callbacks reuse one submission timestamp. Setup, handshakes, and exports remain outside timed work.

Extraction requires an explicit preparation contract. Both pinned #93 and candidate use `consumed-topology`; literal source-text inference is removed. The mixed scenario alternates tracked and untracked roots without changing merging behavior. It also has fewer checkpoint reservations than an all-tracked workload, so eventual observed differences are diagnostic and do not alone establish the causal cost of the unimplemented merging alternative. CPU definitions distinguish synchronous acceptance-thread CPU from process-wide workload CPU. No correctness cleanup scan may mask missing proof coverage.

## Evidence and retained attempts

[source-hashes.json](source-hashes.json) is the canonical final map of 325 regular tracked implementation/harness blobs, excluding validation documents, symlinks, and gitlinks. Every entry matches both frozen Git blob and worktree bytes. The evidence-only commit changes no implementation or harness input. Earlier candidate maps for `5910146` and `5f5ab13` remain labeled separately; their validation is not substituted for final-candidate acceptance.

[Command receipts](attempts.json) retain commands, timestamps, exit codes, commits, and dirty input hashes. Preserved setup failures include a test enum typo corrected before successful compilation, a new replacement assertion that incorrectly depended on the sidebar's retained project filter, and discovery refusing to overwrite an existing output. The replacement test now asserts database and navigation ownership directly. Final discovery used a new output path. A new UI fixture was corrected to return to the project before querying a search field hidden by the reader; this correction was compiled before any UI execution. The complete independent pipeline was rerun against that final UI candidate.

[raw-artifacts.json](raw-artifacts.json) records individual exact-byte hashes and provenance under `/Volumes/Pro2T/TraceValidation/search-intent-checkpoint-handback-followup`. Raw payloads are **local-only**, not downloadable repository/CI artifacts. XCTest bundles and optimized binaries remain at their receipt/provenance paths. Historical evidence and failed attempts are preserved. No skipped result has been fabricated.

No migration, index-format change, breaking public interface, new application retry timer, or merge is included.
