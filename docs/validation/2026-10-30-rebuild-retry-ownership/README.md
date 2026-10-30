# Rebuild retry and reset-ownership validation

Follow-up to merged [PR #79](https://github.com/hbmartin/Trace-Agent-Sessions/pull/79).
Implementation candidate: `6f67f03a50cf71e724726e27c4b15ad2d2cdd52f`. Base: `70634d5db0732fff0c2e42f4c5196770a214498e`.

## Result

- 399 focused unit tests passed: 220 Core and 179 App.
- 24 ownership and retry cases passed five consecutive runs: 120 additional test executions.
- Debug and Release app builds, the external-client fixture, project drift, signing, network-surface, 53 script tests, and whitespace checks passed.
- UI execution was skipped at the user's explicit request. The UI target, including the new selection-after-delivery regression, compiled.
- Complete suites and Release comparison pairs were omitted as planned. The local 10% performance rule was not evaluated; this report makes no performance-acceptance claim.
- SwiftLint was unavailable; its optional build phase emitted a missing-tool warning.

[Verification results](verification.json), [focused selection](focused-selectors.json), [repeated cases](race-selectors.json), and [source hashes](source-hashes.json) identify the validated inputs. Documentation-only commits may follow the implementation candidate.

## Changes exercised

Waiting retries relinquish their stored batch before execution. Reset and ordinary retry budgets remain independent, ordinary completion receipts are deduplicated, and events without callbacks retain no empty receipts. Committed-scope full scans cover every root even when subtree provenance is present. Pending, waiting, dormant, and ordinary-recovery work all fence stream checkpoints.

A content-generation token advances in the reset transaction and survives a post-commit checkpoint failure. Existing reads carry generation and opaque source identity into selection, transcript, search, and hydration acceptance. Global invalidation follows reset commitment independently of the original selection. Cached source and message identities preserve later navigation and bookmarks through reused row IDs. Capture and resolution use batched reads; prepared persistence is retired by its owner while committed recovery survives restart.

Aborted capture routes ordinary work through the same watcher buffering boundary. Replaced queued enrollments release their waiters and transfer their inputs. Safety delivery distinguishes actual reset/ordinary handoff from retirement, avoiding a second reconciliation. Restoration-reference mismatch exits its switch while retaining the summary tail.

All four existing scheduler request signatures remain available. The external client also compiles the additive committed-scope and generation-owned navigation APIs. Schema version 18, index format 7, and ID allocation remain unchanged.

## Retained attempts and limitations

An intermediate search-restoration run advanced virtual time before search enrollment. Its regression now waits for search start before advancing `TestClock`, preserving the result and anchor assertions.

One intermediate run timed out in `testDeferredPublicationReentryCannotDiscardNewManualRebuild`. No production change was made for that timeout. The final 399-test selection and all five repeated runs, including this case, passed. Its cause is not established; it is not classified as unrelated or baseline-safe.

Earlier startup-restoration, selection-coverage, and row-reuse failures found during implementation were corrected and rerun. Compiler attempts and every failed/intermediate XCTest bundle remain available. [Attempt outcomes](attempts.json) distinguish intermediate evidence from final validation; [raw artifact hashes](raw-artifacts.json) preserve their identities.

Raw logs and check results: `/Volumes/Pro2T/TraceValidation/rebuild-retry-ownership-followup`.
XCTest bundles: `/Volumes/Pro2T/TraceWorktrees/rebuild-live-updates/build/retry-*.xcresult`.
The primary checkout, vendor changes, and earlier validation artifacts were preserved. No merge was performed.
