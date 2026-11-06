# Fix reset coverage, scheduler activation, and mailbox coalescing

Follow-up to merged [PR #89](https://github.com/hbmartin/Trace-Agent-Sessions/pull/89).
Base: `28888a0a35152df33d144053a025d3528babba06`.
Frozen final implementation candidate: `92008f7b64482c688784f13ea6ea2fd1b733d6a5`.
Pinned targeted baseline: `264cb95bb5328c57618b24f564d82ec44f3fd522`; its tree equals the merge-base tree.

## Change

Whole-scan failure attribution includes reconciliation roots added at reset commitment, while path-only obligations retain narrow failure ownership. The coordinator reports its actual scan qualification through an internal execution result used by checkpoint proofs and ordinary completion. Existing public coordinator and scheduler signatures remain compatible.

All scheduler callbacks are installed before one registered activation starts initialization and retained-proof processing. `waitUntilIdle()` waits for registered work without initiating another activation, and stop settles activation without later publication. The private frontier now expresses its reference ownership directly; dead branches and duplicate retained-state counts are removed.

Watcher ingress appends bounded chunks under a short lock. A serial background coalescer can keep aggregating while main-actor delivery is held, retaining one pending aggregate and one in-flight payload after catching up. Epoch lineage, reservations, diagnostics, closure, and replacement fences remain intact. The unused replay fallback and first-position bookkeeping are removed; missing persisted checkpoints still reconcile configured roots.

The mailbox workload uses asynchronous completion, cancellation, and a bounded timeout instead of main-actor polling. Completion is awaited before joining the producer so a timeout can surface. Instrumentation distinguishes actual frontier nodes from historical heap marks, shares count definitions, and rejects missing, duplicate, or reversed anchors. Handshakes and exports remain outside timed slices. No performance improvement is claimed.

## Completed validation

- 675 affected Core/App cases passed: 191 indexing, 13 watcher, 64 metadata, 27 sidecar-dependency, and 380 App follow-up cases.
- 29 ownership cases passed in five serial repetitions: 145 additional executions.
- 67 script tests passed at the final candidate; 66 passed before the final malformed-anchor regression was added.
- Debug/Release app builds, external-client compatibility, project drift, signing, network surface, frozen-input checks, and pinned whitespace checks passed.
- All 29 race selectors and 12 selected UI identifiers match compiled XCTest discovery (915 identifiers).
- Synchronized baseline/candidate Release tools compiled. Eight-obligation correctness smokes passed for enqueue, acceptance, backlog, and mailbox modes. Both mailbox tools were recompiled and re-smoked after the final harness-only correction. These runs are not accepted performance measurements.
- All 325 canonical source hashes match the final frozen commit and worktree. Vendor changes and local triage records remain outside this patch with separate input provenance.

Production, XCTest, project, and build validation ran at `81c7baee3c5d964e9d9c002f2a18191aff3a4ed5`. The final candidate changes only the standalone mailbox benchmark, instrumentation script, and script tests. [Input equivalence](frozen-input-equivalence.json) verifies production/XCTest/build inputs are byte-identical. Historical commands retain their actual tested commit labels. The evidence-only commit added after this freeze does not alter those inputs.

## Preserved failures and synchronization correction

`testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData` failed separately on both the candidate and unchanged pinned #89 baseline: one failed test with two assertion failures (state timeout and `CancellationError`). It is excluded from the 675-case passing selection. Both logs and result bundles are retained in [classification](known-transcript-classification.json) and [attempts](attempts.json).

An exploratory affected run also checked `lastSessionID` before asynchronous startup navigation remapping completed. Five isolated candidate repetitions and 20 unchanged-baseline repetitions passed; this is **not** classified as a reproduced baseline failure. The test now waits for accepted current-generation/source identity and message rows before retaining its original persistence assertions, without another summary refresh. The strengthened test passed in the frozen affected run and all five ownership repetitions. [Synchronization evidence](startup-test-synchronization.json) retains the failed attempt and follow-up results.

## Outstanding acceptance and publication

The twelve selected UI cases have **not run** for this follow-up. Compiled selector discovery does not validate UI behavior. No fresh desktop-idle confirmation was obtained, and competing native work remained active. No protected dialog was bypassed.

Paired targeted optimized enqueue, acceptance, backlog, and mailbox measurements at 1,000 and 10,000 obligations have **not run**. The required warm-up and five recorded samples per workload/revision remain outstanding. Tool compilation and tiny correctness smokes do not establish timing, contention, or footprint acceptance.

The ready PR is published at the user's request with these limitations explicit. Publication does not imply completion or waiver of UI or targeted performance acceptance. Complete suites and the three full Release comparison pairs are omitted as selected. **No local 10% performance-acceptance claim is made.** Do not merge on this report alone.

## Evidence and availability

[verification.json](verification.json) records acceptance state and exact counts. [source-hashes.json](source-hashes.json) is the canonical input map for the final frozen candidate, excluding validation documentation to avoid a self-referential hash. The original production-candidate manifest and all historical reports remain preserved. [attempts.json](attempts.json) contains exact commands, actual commit labels, exit codes, and local log paths, including failures.

Raw payloads are **local-only**, not attached as downloadable repository or CI artifacts. [raw-artifacts.json](raw-artifacts.json) records individual byte counts, hashes, and provenance under `/Volumes/Pro2T/TraceValidation/checkpoint-activation-mailbox-followup`. XCTest bundles remain under `/Volumes/Pro2T/TraceWorktrees/rebuild-live-updates/build/`. A per-command external ignore file excludes only unrelated untracked `reviews_triage/` probes from unexpected-build-input detection; tracked source and vendor inputs remain validated.

No migration, index-format change, breaking public interface, or new retry timer is included.
