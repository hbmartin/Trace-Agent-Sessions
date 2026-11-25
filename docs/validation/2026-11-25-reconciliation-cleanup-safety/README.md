# Reconciliation and cleanup ownership follow-up to #106

Frozen implementation candidate: `8506092bf413576da00b570c17873371a76018b4`.
Fresh main base: `b817fd48a1172178b7c7220db6d380277a49de96`.
Pinned measurement baseline: #106 HEAD `25c5fff3c73b191dd29f806f8102da2be168e7eb`.
The later delivery commit adds validation documents only.

## Changes and scope

ASCII-sensitive scoped queries retain one non-ASCII source-path count per
provider/root, qualified by writer connection, snapshot and SQLite data version.
A proven zero count skips the canonical-equivalence fallback. Content appends
do not invalidate that count; committed membership changes update it. Rollback,
root retirement, reset commitment and external writes have explicit regression
coverage. Insensitive and Unicode requests retain the reader-pool query path.
The cache retains counts rather than a second copy of the source paths.

Cleanup retains its unreaped process-group leader as an ownership anchor until
the owned group has no live members, including descendants created by TERM
handlers. Signals arriving during child launch are deferred until the child
handle is installed for cleanup. Controlled test and benchmark fixtures use an
invocation-owned pipe for emergency shutdown; they do not signal a saved
descendant PID after normal cleanup. Atomic readiness publication is retained.

The optimized harness records physical filesystem policy separately from forced
SQL query policy, distinguishes cold from warm queries and requires an explicit
instrumentation layout. Its probes exist only in exported measurement sources,
behind `TRACE_CHECKPOINT_BENCHMARK`; normal Core has no public measurement API.

The selected fixes are comments #1, #3, #4 and #8. Comment #5 was already fixed
and remains covered. Comments #6 and #7 are explicitly deferred: mixed-volume
ancestor case policy and child-scope parent spelling are unchanged. For #2,
both existing writable APFS filesystems rejected normalization-twin directory
creation and resolved both spellings to the same inode. This is a bounded
investigation, not a reproduction of the reported destructive pipeline. No new
filesystem was mounted and canonical-equivalence behavior is preserved.

## Accepted validation

| Check | Result |
| --- | --- |
| Affected Debug native groups | 746 passed, zero failures or skips |
| Indexing / sidecar / watcher / viewport / App cases | 258 / 27 / 13 / 4 / 444 |
| Script discovery | 141 passed |
| Six native ownership cases, five repetitions | 30 executions passed |
| Seven script ownership cases, five repetitions | 35 executions passed |
| Debug build-for-testing | Passed |
| Normal Release app build | Passed, `ENABLE_TESTABILITY=NO` |
| Isolated Release Core test target compilation | Passed, `ENABLE_TESTABILITY=YES` |
| Release external-client fixture | Passed |
| Project drift, signing settings, network surface | Passed |
| Pinned whitespace and 337 canonical source hashes | Passed |
| Vendor inputs before/after | Identical, including existing local changes |
| Optimized baseline/candidate frameworks and clients | Built successfully |
| Twelve optimized correctness smokes, 10 inputs | Passed; timing is not accepted performance evidence |

`verification.json` records exact commands and provenance paths.
`native-execution-counts.json` records each executed selector.
`native-race-counts.json` distinguishes 30 executions from six unique cases.
The native summary also retains a watcher-test runtime QoS warning; no test
failed or skipped because of it.

<!-- MEASUREMENTS -->
**Targeted paired measurements are incomplete: zero accepted samples.** The
user requested a ready PR. No fresh desktop-idle confirmation or explicit
measurement waiver was received, so the originally selected measurement gate
remains unsatisfied and is disclosed in this ready-for-review PR. Both optimized
clients are built and their twelve correctness smokes pass, but those checks
do not establish a performance improvement. The prepared matrix is six query/
append modes at 1,000 and 10,000 inputs plus three cleanup modes, each with one
warm-up and five recorded samples per revision. No timed matrix was started.
<!-- END MEASUREMENTS -->

UI tests, complete native suites and the three full Release comparison pairs
are omitted by the approved plan. No local 10% performance-acceptance claim is
made.

## Failures and negative controls

All raw failed attempts remain at the local provenance paths in
`raw-artifacts.json`; historical validation directories were not rewritten.

- Against the actual pinned #106 runner, mocked negative controls produce one
  failed test and one errored test for launch ownership and late TERM forks.
  A separate actual-baseline benchmark control fails one test for the stale
  descendant-PID signal. These are expected failures, use no real signals and
  are not counted as final passing tests. The older job label
  `baseline-negative-control` actually ran instrumentation contract tests;
  `command-label-clarification.json` in the raw inventory preserves that fact.
- An early real SIGTERM attempt left a running-phase receipt; launch handoff
  was fixed. Another exploratory real SIGTERM attempt recorded cleanup failure
  without enough diagnostics to establish its cause. It remains inconclusive;
  later diagnostic runs and the final five repetitions pass. It is not labeled
  unrelated.
- A new cache rollback test initially used a lexical Unicode path rather than
  its canonical stored identity. It now checks the preserved source row ID.
  Early Debug/measurement builds also found explicit-self capture errors in
  sendable closures; the normal source and shared export instrumentation were
  corrected before accepted builds.
- Two extra broad Release build-for-testing attempts failed. The first lacked
  testability; the second also compiled App `ClockTests` and reported references
  to DEBUG-only helpers. There is no matching baseline reproduction. The normal
  Release app and the required isolated Release Core test target subsequently
  passed; this does not claim Release App test-target compatibility.
- The first filesystem probe gave `diskutil` a subdirectory rather than the
  mount. The corrected probe identifies each existing mount before inspection.

## Frozen-input and artifact provenance

`source-hashes.json` is the canonical map of all 337 regular tracked candidate
inputs except historical validation documents. Symlinks and gitlinks are
excluded. Each SHA-256 was verified against both the frozen Git blob and working
bytes. `frozen-input-equivalence.json` independently verifies every Core Swift
blob in the optimized exports after removing only the shared instrumentation.

Normal Core at the frozen candidate is byte-equivalent to `6e64f56`; timed
harnesses and instrumentation are byte-equivalent to `4f577b7`. The final commit
after those revisions strengthens one Python regression test. Final script
discovery includes that strengthened test. No runtime or harness change is
being substituted for the inputs that were built and validated.

`compiled-workloads.json`, `compiled-products.json` and `toolchain.json` retain
binary, harness and toolchain provenance. Exported baseline and candidate use
identical recursive vendor inputs, preserving local vendor modifications.

Raw payloads, logs, result bundles, exported sources and binaries are
**local-only** under
`/Volumes/Pro2T/TraceValidation/reconciliation-cleanup-safety-followup`.
They are not attached as downloadable repository or CI artifacts. The committed
inventory hashes top-level regular files and records directory provenance paths;
it does not claim recursive tree digests for those directories.
