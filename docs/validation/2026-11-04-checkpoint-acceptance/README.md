# Checkpoint acceptance and wrap recovery

Follow-up to merged [PR #85](https://github.com/hbmartin/Trace-Agent-Sessions/pull/85).
Frozen implementation: `83de9cbcba7be628c07331c58c86c564a3fc53cf`. Base: `0576876ea16c3dd7b64d7d252850267682222fbf`.

## Changes

- Materialize implicit reconciliation roots as outstanding work before subtracting successful coverage. Later metadata coalescing retains unpaid paths and roots; separately scanning the remaining root completes the obligation.
- Apply the checkpoint wrap transition when incoming epoch lineage advances, even if a post-wrap callback arrives before the callback carrying the wrap flag. Repeated and predecessor batches retain their existing fences.
- Distinguish an optimistic commit conflict from successful empty acceptance. Retain the completed execution proof for a cooperative successor acceptance, allow fresh indexing work to proceed, and retire obsolete proofs on reset or stop. No additional indexing pass or retry timer is introduced by acceptance contention.
- Process wrap control metadata before the watcher content filter. Filtered wrap paths still advance chronology and require root reconciliation; untracked watchers continue omitting checkpoint metadata.

There is no migration, index-format change, public-signature change, or change to ordinary/reset retry budgets. Superseded recovery-enrollment retirement and local-only artifact policy remain unchanged.

## Validation

- 555 tests passed: 181 Core indexing/watcher cases and 374 App recovery cases. The one excluded case is documented below; it is not counted as a pass or a runtime skip.
- Nine ownership cases passed five separate serial invocations: 45 additional executions. Internal scenario loops are not counted as extra XCTest methods.
- Seven new regression methods cover partial roots and metadata coalescing, both wrap delivery orders before/after initialization, acceptance contention, fresh-work progress, stop/reset retirement, and filtered/untracked watcher controls.
- Temporarily disabling the four fixes caused all four corresponding negative-control cases to fail: four failed tests, 12 assertion failures. Those are expected failures, not candidate acceptance. Production changes were restored before freezing.
- Debug/Release app builds, external-client compatibility, 53 script tests, project drift, signing, network surface, and whitespace checks passed.
- All 105 entries in [source hashes](source-hashes.json) were checked against both the frozen commit and the final working tree.

`testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData` timed out in the initial affected-group run and in an isolated candidate rerun. The identical case and timeout reproduced with exact base sources at `0576876ea16c3dd7b64d7d252850267682222fbf`. It was excluded from the final focused invocation after that reproduction. The baseline input hashes, both candidate failures, command lines, and expected negative-control failures are preserved in [verification](verification.json).

## Limits and artifacts

Complete suites, UI automation, optimized measurements, and three repository-wide Release comparison pairs were not run for this candidate. No local 10% performance-acceptance claim is made. Prior candidate measurements and UI results are not reused.

[Verification](verification.json), [canonical input hashes](source-hashes.json), and [raw-file hashes](raw-artifacts.json) describe the frozen candidate. Raw payloads are local-only, not downloadable repository or CI attachments. Logs and summaries remain at `/Volumes/Pro2T/TraceValidation/checkpoint-acceptance-followup`; XCTest bundles remain under the recovery worktree's `build/` directory. Vendor changes, triage records, and prior validation artifacts were preserved. No merge was performed.
