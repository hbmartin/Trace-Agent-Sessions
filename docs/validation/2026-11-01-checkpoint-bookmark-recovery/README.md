# Checkpoint initialization and bookmark recovery validation

Follow-up to merged [PR #82](https://github.com/hbmartin/Trace-Agent-Sessions/pull/82).
Implementation candidate: `f06c853e619a78b3a4cf4d4e3404ed4aefa23407`.
Base: `b282be23987b11a9d977653994dd6ec0b463dec8`.

## Result

- 439 focused Core/App tests passed.
- 65 checkpoint, bookmark, and ownership cases passed five consecutive runs: 325 additional executions.
- Debug/Release app builds, external-client compatibility, project drift, signing, network surface, 53 script tests, and whitespace checks passed against the frozen source hashes.
- Compiled XCTest enumeration confirmed all 25 selected UI identifiers, including the corrected `testPendingLaunchRestorationResumesWithoutUserIntent` selector.
- The full quiet 25-case UI selection was omitted at the user’s request. Two focused UI cases passed in a diagnostic attempt that overlapped competing GitX builds; that attempt is not counted as quiet validation.
- Zero, negative, malformed, and overflowing benchmark event counts exited with status 2 and a usage diagnostic. A one-event Release CLI smoke run succeeded. Its incidental timings are not performance measurements or an acceptance result.
- Complete suites, optimized event-burst measurements, and three Release comparison pairs were omitted as selected. The local 10% rule was not evaluated.

[Verification](verification.json), [attempts](attempts.json), [focused selection](focused-selectors.json), [repeated races](race-selectors.json), [UI selection](ui-selectors.json), [source hashes](source-hashes.json), and [raw artifact hashes](raw-artifacts.json) identify the inputs and outcomes. Documentation-only commits may follow the implementation candidate without changing its validated source inputs.

## Behavior covered

A failed checkpoint read is distinct from a successfully read missing row. Failed streams continue live indexing and reconcile their roots without enrolling new checkpoint obligations. A safe monitoring warning remains visible until a current source/monitoring restart reads the checkpoint successfully. Healthy streams continue checkpointing; cancellation and obsolete reads cannot seed a replacement ledger. Existing valid reservations retain their ownership across same-database replacement. Private diagnostics deduplicate per stream and reset after success.

Wrap identifiers now belong to individual streams, independently of aggregate recovery reasons. Merging wrapped A with B cannot lower B's watermark or replace B's epoch. Reservation-only requests drain without a coordinator pass; metadata delivery cannot pay indexing or wrap-reconciliation debt. Blocked obligations remain available for later qualifying coverage without spinning or blocking scheduler idle/stop. Empty checkpoint saves return before acquiring the writer.

Pending bookmark resolution validates both its store and summary/workflow owners after suspension. A newer bookmark revision causes a new resolution snapshot; explicit clears and later scroll positions win. Replacement and termination reject obsolete restoration. Opt-in native restoration receipts identify the rendered generation, session, invocation, and applied bookmark only after native completion. The latest-scroll UI assertion requires a fresh receipt from the post-reset generation before geometry can satisfy it.

No migration or index-format change was introduced: schema 19 and index format 7 remain unchanged. Existing public signatures and default retry policies remain available. There is no automatic retry timer or monotonic-ID redesign.

## Retained attempts

The first compilation failed on fixture argument order and an inferred UI polling expression; both were corrected. An initial eight-test run exposed three test-control/setup errors: the healthy sibling was absent from the attached source, the restart helper reused an already-ready watcher, and a termination test waited while retaining its own read gate. The fixtures now use the actual replacement-watcher path and release the held read after starting owner retirement.

The first frozen candidate (`589d41d`) passed 439 focused cases and three 65-case repetitions. Its fourth repetition exposed a premature search-test wait: cached pre-reset rows satisfied completion before reindexing restored the selected source. The test now requires the new selected-session generation and a nonempty search result before checking the target. The final candidate also retains checkpoint warnings during held restart initialization and gates every native restoration reason in the focused UI control. All final unit selections passed after these changes.

No failed attempt is classified as unrelated or baseline-safe. Original logs, intermediate manifests, and XCTest bundles remain retained. The diagnostic UI attempt passed both checkpoint recovery and latest-scroll restoration. Competing GitX builds resumed after the initial empty process check. The user then directed publication without further UI tests; the full quiet selection remains unverified.

Raw payloads are local-only and are not attached as downloadable repository or CI artifacts. The paths below identify retained provenance, not public download locations.

Raw evidence: `/Volumes/Pro2T/TraceValidation/checkpoint-bookmark-recovery-followup`.
XCTest bundles: `/Volumes/Pro2T/TraceWorktrees/rebuild-live-updates/build/checkpoint-recovery-*.xcresult`.
The complete per-file bundle inventory is retained locally; repository metadata records each bundle's tree digest. The unrelated primary checkout, vendor changes, triage artifacts, and prior reports were preserved. No merge was performed.
