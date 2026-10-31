# Navigation identity and indexing-work validation

Follow-up to merged [PR #80](https://github.com/hbmartin/Trace-Agent-Sessions/pull/80).
Implementation candidate: `9e9a9556117f9ad9bd2c24daeaf21051aeb2f6f8`. Base: `947e1891df64431ec8099d449cd47969debe71e5`.

## Result

- 416 focused Core/App tests passed.
- 42 ownership, navigation, retry, and checkpoint cases passed five consecutive runs: 210 additional test executions.
- Debug and Release app builds, external-client compatibility, project drift, signing, network-surface, 53 script tests, and whitespace checks passed against the final source hashes.
- UI execution was skipped at the user's explicit request. The UI target compiled, including new chained-file-move and automatic-reset search-anchor regressions.
- Complete suites and Release comparison pairs were omitted as planned. The local 10% performance rule was not evaluated; this report makes no performance-acceptance claim.
- SwiftLint was unavailable; its optional build phase emitted a missing-tool warning.

[Verification results](verification.json), [focused selection](focused-selectors.json), [repeated cases](race-selectors.json), [compiled UI selection](compiled-ui-selectors.json), and [source hashes](source-hashes.json) identify the validated inputs. Final XCTest runs use the frozen implementation candidate. The build/check input manifest independently matches that candidate. Documentation-only commits may follow.

## Changes exercised

Committed source moves establish generation-owned relocation lineage; rollback, source deletion/replacement, and reset cannot authorize an unrelated reused row. Anchored capture validates expected references in the same database read. Accepted moved transcripts refresh mutable source metadata while retaining message anchors. Prepared restoration clears stale numeric IDs after generation or database-family change and keeps the stable source reference.

Reset-owned bookmark capture survives switching or clearing selection, merging later bookmarks before commitment. Sidebar selection uses the current row's source and generation metadata. Copy and restoration cancellation remain supersession. Page snapshots own their cursor generation; cross-generation appends restart the requested depth coherently.

One database-owned startup envelope transfers source inputs, completion obligations, delivery waiters, and safety intent together. Later arrivals drain through the same boundary. Same-database supersession retains undelivered obligations; actual replacement and termination retire delivery waiters. Watermark-only recovery does not run an empty indexing pass.

Compatible waiting ordinary retries share inputs, receipts, and the earliest deadline without extending their budget. Executing work remains exclusive. Ordered per-stream obligations advance the contiguous accepted checkpoint prefix while older unfinished work fences later checkpoints. Stream-root qualifications remain attached to retained recovery and accepted-but-not-durable coverage is invalidated when a reset supersedes it. Canonical roots are resolved once per enrollment and shared by its batch and checkpoint receipt.

Generation-family extraction and transactional generation advancement share one implementation. SQL snapshots read the token once and pass it into row conversion. All existing scheduler request signatures remain available; the external client also compiles the additive validated-capture overload and anchor-preservation API. Schema version 18, index format 7, and ID allocation remain unchanged.

## Retained attempts and limitations

Two intermediate focused runs failed `testWatermarkOnlyRequestAddsItsStreamRootToRetainedRecovery`. The ordered checkpoint implementation was corrected to preserve additional stream-root qualification and reset-invalidated coverage. The existing regression assertion was retained; it and the final focused/stress selections passed.

An intermediate restoration-cancellation regression cleared the database a second time, causing legitimate confirmed absence rather than simulating an obsolete resolution. The test now injects cancellation at the owned resolution boundary and observes every publication while asserting the cached reader and safe status remain intact. The corrected test passed in the final selection and repeated runs.

Earlier compiler attempts, all intermediate logs, and every failed XCTest bundle remain available. [Attempt outcomes](attempts.json) distinguish intermediate evidence from final validation; [raw artifact hashes](raw-artifacts.json) identify the retained logs, inputs, and bundles. No failed attempt is classified as unrelated or baseline-safe.

Raw logs and check results: `/Volumes/Pro2T/TraceValidation/navigation-checkpoint-ownership-followup`.
XCTest bundles: `/Volumes/Pro2T/TraceWorktrees/rebuild-live-updates/build/nav-*.xcresult`.
The primary checkout, vendor changes, and earlier validation artifacts were preserved. No merge was performed.
