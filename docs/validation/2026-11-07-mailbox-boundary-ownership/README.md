# Mailbox boundary ownership and scheduler retirement

Follow-up to merged [PR #91](https://github.com/hbmartin/Trace-Agent-Sessions/pull/91).

Frozen implementation and harness: `1770130548077c805ad9c67cba8975351d9d2afe`.
Fresh base: `2c6e38c261a97629cfa4f3e82ae4c7bae5b57dfc`.
Pinned baseline: `160f1662030ee01756345a6f3666c9546968d726`.

## Publication and limitations

The user requested a ready PR after being told that UI baseline comparison and targeted measurements were blocked. **Validation is incomplete.** Ready status does not mean all acceptance checks passed.

The twelve selected UI cases ran: eleven passed and `testAutomaticResetCommitRestoresReaderAndBookmark` failed with 170 reported issues (the first native offset was 0 rather than -40, followed by sampled offset mismatches). Other native checks began during that run, so quiet-host acceptance is false. This failure is **unclassified**, not claimed to be unrelated. The unchanged #91 baseline app was blocked at launch by another protected macOS dialog; its attempt was interrupted without a completed test. A preceding candidate attempt was also interrupted at a protected dialog. No dialog was bypassed. See [UI outcomes](ui-progress.json) and [verification](verification.json).

Paired optimized measurements at 1,000 and 10,000 obligations were **not run**. Both optimized revisions and workload binaries compiled; small correctness smokes passed, but they establish no performance result. Complete suites and the three full Release comparison pairs remain outside the original approved scope. **No local 10% performance-acceptance claim is made.**

## Behavior

Delivery outcomes distinguish rejection, ordinary transfer, whole-boundary recovery transfer, and deliberate retirement. Recovery owns the complete boundary and skips later ordinary fragments. Accepted transfer is recorded before yielding and cannot become rejection after watcher replacement. Closure awaits the receiver and retains only the undelivered suffix for matching database ownership.

All four path roles share a total 128-entry segment budget. Canonical reservation inputs are prepared in the background, reused during enrollment without filesystem resolution, and omitted when watermarks are absent. The bare receiver compatibility initializer and default no-op retirement were removed. Production and DEBUG injection use the same receiver, with weak stored database captures and opt-in test receipts.

The current scheduler installation owns checkpoint draining and publication. Obsolete computations retain compatible coverage for successors; retiring an obsolete reset fence wakes successor publication. Shutdown joins readiness and worker tasks. Existing public signatures remain; the canonical-input `IndexCheckpointInputs` initializer is additive.

## Completed validation

- 695 focused Core/App cases passed: indexing 201, watcher 13, metadata 64, sidecar dependency 27, App follow-up 390.
- 49 ownership cases passed in five repetitions, adding 245 executions.
- 72 script tests passed. Debug/Release builds, external-client compatibility, project drift, signing, network surface, frozen inputs and pinned whitespace checks passed.
- All 49 race and 12 UI selectors matched compiled XCTest discovery (935 identifiers).
- Both optimized frameworks and workload binaries compiled. Enqueue, acceptance and backlog smokes used 8 obligations per revision; plain, oversized and structural mailbox smokes used 257 inputs per revision.
- The intentional reset-fence negative control failed one test with one reported issue. Production source was restored before the final candidate was frozen and validated.

The separately isolated terminal-reread test fails on both candidate and unchanged pinned #91 source, with one failed test and two reported issues: a state timeout and caught `CancellationError`. This matched baseline failure is separate from the 695 passing cases and from the unclassified UI restoration failure. See [classification](known-transcript-classification.json).

## Evidence

[verification.json](verification.json) records completed and incomplete checks. [source-hashes.json](source-hashes.json) is the single canonical map for the 325 regular implementation/harness blobs at the frozen candidate. Every entry was checked against its Git blob and current worktree bytes; validation documentation is excluded to avoid self-reference. The final documentation commit changes no implementation input.

[Command receipts](attempts.json) retain actual commands, commits, timestamps, exit codes and dirty input hashes. Earlier 693/694-case runs, an extra-live-callback harness failure, the intentional command hold, the negative control, protected-dialog attempts and the nonaccepted UI run remain preserved. Held commands were not executed. Historical reports and original hash maps are unchanged.

Raw payloads are **local-only**, not downloadable repository/CI attachments. [raw-artifacts.json](raw-artifacts.json) lists exact-byte hashes and provenance under `/Volumes/Pro2T/TraceValidation/mailbox-boundary-ownership-followup`. XCTest bundles remain at the paths recorded in command receipts. No paired-measurement results are claimed or fabricated.

No migration, index-format change, application retry timer, breaking public interface, or merge is included.
