# Readable-session restoration and checkpoint delivery validation

Follow-up to merged [PR #94](https://github.com/hbmartin/Trace-Agent-Sessions/pull/94).

Frozen implementation and harness: `38f8b9dcf3162bb88b79c4230f1351d872f6000f`. Fresh base: `283c2114e3aff3c8e28b2351d0a2e7755c6c7ae5`. Pinned #94 baseline: `cb353d36f0533731cf5a034b80a61d2ddff2ad1b`.

## Publication and limitations

The user explicitly instructed **“Skip UI and measurements; publish with limitations”**. [Publication waiver](publication-waiver.json) records that instruction. **No selected UI case or paired targeted measurement ran.** Fifteen UI selectors, including the two new search-absence cases, were verified against compiled XCTest discovery. Native restoration geometry and performance acceptance remain unverified. Small optimized correctness smokes exercise harness behavior and do not substitute for the omitted 1,000/10,000-input paired measurements. Tracked/untracked grouping remains unchanged.

Complete suites and three full Release comparison pairs remain outside the approved scope. **No local 10% performance-acceptance claim is made.** No merge is included.

## Runtime changes

Readable-session publication is independent of a missing search target. The transcript opens at its latest bookmark while a generation-, source-, selection-, token-, and bookmark-revision-owned stable target remains private. Newer scrolling, explicit clears, navigation, replacement, and termination supersede it. Later accepted indexing may resolve the exact target; successful coverage of its own source may settle absence. An unrelated corrupt file does not deny a healthy source's authority. Retry uses the same source-coverage policy without submitting indexing work.

Core publishes an opaque source-coverage value on terminal progress, derived from actual successful ingestion and discovery scopes and excluding failed or incomplete scopes. The App cache is scoped to content generation and source configuration rather than an individual navigation object, so stale search results opened after indexing completes can use already-accepted coverage. All three absence decisions share that policy. Repeated file facts replace prior slots; later broad coverage compacts old descendants.

Ordered multi-anchor capture refreshes bookmark and distinct search anchors in one SQL read. Stable anchors take precedence over numeric IDs; numeric fallback requires the matching content generation and expected source. Existing capture signatures remain available. Reset staging prefers a current captured intent before a current prior intent and preserves capture-time bookmark revisions. The candidate-selection case is defensive hardening; a real stale-old/current-captured overlap has not been demonstrated.

A cancellation-safe shared-ledger permit serializes complete legacy and qualified checkpoint callbacks across registrations. Qualification after permit acquisition checks installation, content, scope, epoch, fences, and compatible delivery frontiers. An admitted callback finishes before its successor enters. Interrupted pre-entry publications return updates and activity together, while stop joins admitted work and retires queued waits. `pauseInitialization` ignores an obsolete failure after successful seeding. The optional two-stage paused-state locking cleanup is unchanged.

## Completed validation

- 728 focused cases passed: indexing 215, watcher 13, metadata 64, sidecar dependency 27, App follow-up 409.
- 82 ownership cases passed five repetitions, adding 410 executions.
- 76 script tests passed.
- Debug/Release app builds, external-client compatibility, project drift, signing, network surface, frozen-input validation, and pinned whitespace checks passed.
- All 82 race and 15 UI selectors matched 971 compiled XCTest identifiers.
- Both optimized framework/workload builds passed. Each revision passed three eight-obligation checkpoint smokes and four 257-input mailbox smokes. The candidate also passed a 257-input equivalent-normalization smoke.
- Structured retirement and retained-fixture negative controls exited 1 as expected. A wrong supported preparation contract failed promptly with `MailboxBenchmark.preparationContractMismatch` before setup/timing. Behavioral preflight exercises both extracted normalizers, without inferring semantics from source spelling.

Four new tests were overlaid on unchanged pinned #94 production source. All four failed, with eleven reported issues: out-of-order admitted callbacks in both API forms, blank missing-target restoration with an unrelated failure, blank stale-generation search restoration, and reused numeric anchor capture. The candidate passes them, including the repeated races. [Baseline evidence](baseline-product-regressions.json) identifies test-only overlays and unchanged production hashes.

The separately isolated `testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData` failed on both frozen candidate and fresh pinned #94 production: one failed test, two issues (state timeout and caught `CancellationError`) in each run. These results are excluded from the 728 passing cases. [Classification](known-transcript-classification.json) records matching symptoms without claiming a new root cause.

## Retained evidence

[source-hashes.json](source-hashes.json) is the canonical map of 325 regular tracked implementation/harness blobs, excluding validation documents, symlinks, and gitlinks. Every entry matches the frozen commit and worktree bytes. The evidence-only commit changes no implementation or harness input. Historical validation is preserved unchanged.

[Command receipts](attempts.json) retain commands, commits, dirty input hashes, timestamps, status, and local log paths. Preserved failures include an incomplete test-source wrapper, Swift closure-type inference, a test's private-property access, a nonasserting UI-poll closure annotation, and an initial smoke failure. Before acceptance, full-summary ownership was corrected so explicit refresh is not mistaken for an already-handled terminal event; the Retry regression was synchronized with its admitted summary tail. Final validation was run against the frozen candidate after those changes.

[raw-artifacts.json](raw-artifacts.json) records exact-byte file hashes and provenance under `/Volumes/Pro2T/TraceValidation/search-coverage-checkpoint-delivery-followup`. Raw payloads are **local-only**, not downloadable repository/CI artifacts. XCTest result bundles, baseline overlays, command outputs, and optimized binaries remain at their recorded paths. Expected negative-control failures are distinguished from final acceptance failures.

The underlying fixture's existing async teardown remains in place. Public signatures, synchronous publication, publisher locking, generation fencing, navigation ownership, checkpoint provenance, admission barriers, and bounded retries are preserved. No migration, index-format change, or application retry timer is included.
