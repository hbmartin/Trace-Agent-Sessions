# Harden checkpoint coverage and bookmark cleanup

Follow-up to merged [PR #88](https://github.com/hbmartin/Trace-Agent-Sessions/pull/88).
Base: `18a0ef1b00d93476ca47f70be3674cd2bf50b21b`.
Frozen implementation candidate: `ded65dd9673a45a8a23133509456b7a247883dc5`.
Pinned targeted baseline: `0b22628e72eefc4ab8d6b39023ba917fd0603629` (the exact merged base tree).

## Change

Checkpoint proofs use actual full-scan execution, including implicit scope resets. Raw configured sidecar paths remain available for topology and link-change checks alongside canonical execution inputs. Failures are attributed only to attempted requirements. Compatible retained proofs drain on successor activation without a new filesystem request; metadata-only deliveries avoid empty proofs.

Paid records are compacted into checkpoint boundaries. Outcome history retains latest execution sequences, prunes dominated history, and retires execution ownership. Record-chain teardown is iterative while active traversal cursors keep their successor links. Reservations use obligation identity rather than constant versions. Paused and uninitialized streams continue retaining genuine completed coverage.

Obsolete-generation bookmark slots are removed without deleting current-generation or other-source slots; newer source-keyed intent remains available. Watcher ingress captures each stream's first chronological replay position and epoch before coalescing, appends bounded pages under a short lock, and merges detached pages outside the lock. Scope decoding shares one transaction-local helper.

Instrumentation distinguishes same-thread acceptance CPU from process CPU, validates unique insertion anchors, and keeps control handshakes and state exports outside measured intervals. No measured performance improvement is claimed.

## Completed validation

- 668 affected Core/App tests passed: 186 indexing, 13 watcher, 64 metadata, 27 sidecar-dependency, and 378 App follow-up cases.
- 21 ownership cases passed in five serial repetitions: 105 additional executions.
- 62 script tests passed at the final candidate.
- Debug/Release app builds, external-client compatibility, project drift, signing, network surface, and pinned implementation whitespace checks passed.
- All 21 race selectors and 12 UI selectors match compiled XCTest discovery (908 discovered identifiers).
- Synchronized baseline/candidate Release binaries compiled. Tiny correctness-only enqueue, acceptance, backlog, and mailbox smokes passed at eight obligations; these are not accepted performance measurements.
- All 325 canonical tracked input hashes match the frozen candidate and worktree. Vendor changes and local triage files remain outside the patch and retain their separate provenance.

Production/XCTest validation ran at `06ec908967ea01f14b1d5fef92a7beca0cc4281c`. The final candidate changes only the benchmark driver and its script regression, moving backlog exports outside measured intervals. Production, XCTest, project, and build inputs are byte-identical; [input equivalence](frozen-input-equivalence.json) records this distinction. Historical command records retain their actual tested commits.

## Existing failure

`testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData` failed separately on both the candidate and pinned #88 baseline: one failed test with two assertion failures, a state timeout and `CancellationError`. The pinned baseline tree equals the exact merge-base tree. It is excluded from the affected selection, with both command logs and result bundles preserved. See [verification](verification.json) and [classification](known-transcript-classification.json).

## Outstanding acceptance and publication

The selected serial UI attempt was blocked at app launch by a visible UserNotificationCenter dialog and cancelled with exit 75. No UI case is accepted. Protected dialogs require manual handling under AGENTS.md; none was bypassed. The host monitor also retained two observations of competing native sessions, so the cancelled attempt is not quiet-host acceptance evidence.

The paired targeted optimized workloads at 1,000 and 10,000 obligations have **not run**. Their required warm-up/five-sample acceptance, backlog, and mailbox measurements remain outstanding. Complete suites and the three full Release comparison pairs are omitted as selected. No local 10% performance-acceptance claim is made.

The ready PR is published for review at the user's request. Publication timing does not imply completion or waiver of the outstanding UI and targeted performance acceptance. Do not merge on the basis of this report alone.

## Evidence

[source-hashes.json](source-hashes.json) is the single canonical tracked input map for the frozen candidate; validation-only documentation is excluded to avoid a self-referential hash. [attempts.json](attempts.json) preserves exact commands, commit labels, exit codes, and local log paths, including failed exploratory attempts. Prior validation reports remain unchanged.

Raw payloads are **local-only**, not downloadable repository or CI attachments. [raw-artifacts.json](raw-artifacts.json) records individual file hashes and provenance under `/Volumes/Pro2T/TraceValidation/checkpoint-proof-hardening-followup`. XCTest bundles remain under `/Volumes/Pro2T/TraceWorktrees/rebuild-live-updates/build/`. The local untracked triage probe was excluded only from unexpected-build-input detection through an external per-command ignore file; no repository ignore, tracked source, or vendor input was excluded.

No migration, index-format change, public-interface break, or new retry timer is included.
