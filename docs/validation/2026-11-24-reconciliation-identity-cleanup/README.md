# Reconciliation identity and cleanup ownership

Follow-up to merged PR #104. Base: `5354f6e62b7835bfe3f4a6b021ccc748ae1d6dd8`.
Frozen implementation and harness: `27b17c8d6e25fddb0f7452fc6710e271d644ba69`. Later commits contain evidence only.
Pinned comparison baseline: `a3ef91b39cdeae6a64363febf265e5af1c650051`.

## Resulting behavior

Reconciliation retains each attempted scope's captured path and case policy.
Live membership accepts exact canonical identity and folds only files captured on
case-insensitive volumes. A file and its root can therefore have different volume
policies without deleting the session just indexed. The regression injects the
contrasting file policy through the production coordinator/database flow and
checks persisted source/session identities and later real deletion. Pure tests
cover both policy directions and distinct sensitive siblings; no new volume was mounted.

Scoped SQL retains its binary query and unions a root-filtered canonical-Unicode
fallback, with source-ID deduplication and bounded batches. NFC/NFD and Kelvin-sign
cases are tested using directly persisted spellings to avoid Foundation masking
the distinction. This is defensive boundary hardening: the ordinary URL pipeline
normalized both spellings on the triage Mac, so its claimed deletion failure was
not reproduced. Decoded-candidate counters do not count SQLite internal rows or
pages visited. No sublinear SQL or performance improvement is claimed.

Cleanup records owned membership before reaping its original leader, then checks
a current snapshot before signalling. The real-process regression exits the
leader before first inspection and leaves a TERM-resistant descendant. Cleanup
now reaches that descendant while retaining zombie-only, recycled-identity,
permission-denial, bounded-wait and interruption behavior.

The incremental workload obtains its corpus total from statistics and uses an
explicit sufficient session-list limit for selected-session lookup. ASCII and
Unicode modes share setup and instrumentation. The cleanup workload keeps setup
outside timing, preserves structured errors, and tears down its controlled fixture.
No public Core signature, migration, index-format, or retry-policy changes are included.

## Completed validation

- 732 affected native cases passed without failures or skips: 245 indexing,
  27 sidecar dependency, 13 watcher, 4 viewport, and 443 App follow-up cases.
- Five native selectors and five script selectors each ran five times: 50
  additional passed executions. Invocation counts are verified from raw logs.
- All 129 script cases passed. Debug/Release builds, external-client compatibility,
  project drift, signing, built-app network-surface and pinned whitespace checks passed.
- The corrected optimized harness passed correctness-only runs with 499, 500, and
  1,000 candidate sources, and 500 baseline sources, each preserving 100 selected
  appends and the full corpus. Timing/footprint fields are not accepted measurements.
- Both optimized workload binaries compiled. Candidate Core source was exported
  and instrumented outside the checkout. The cached pinned baseline's normalized
  Core inputs were verified, and the same per-materialized-object counter and
  corrected harness were used. Exact commands and hashes are retained.
- All 334 canonical source hashes match the frozen commit and working bytes.
  Recursive vendor inputs remain unchanged; vendor changes were not staged.

## Failed attempts and limitations

The initial Debug build caught two missing awaits in the new test fixture;
those were fixed before freezing the candidate. The first broad native attempt
was interrupted after an existing checkpoint-retry case stopped progressing.
Its stack and incomplete result (51 passed, one interrupted failure) are retained.
The isolated case and the full rerun with explicit per-case timeouts passed.
A bounded held-clock baseline probe did not reproduce the stall; its cause is
inconclusive and is not labelled an unrelated baseline defect.

An instrumentation-equivalence collector initially assumed the wrong historical
counter syntax. That failed preparation and its source snapshot remain available;
the collector was corrected and the final optimized export was rebuilt and verified.

The user explicitly instructed **“Skip measurements; publish with that limitation.”**
No paired measurement driver was launched and no desktop-ready lease was created.
UI execution, complete suites, and three full Release comparison pairs are omitted
as selected. There is no measured speedup, footprint improvement, or local 10%
performance-acceptance claim. Existing GitHub threads and alert states are unchanged.

## Evidence availability

Raw payloads are local-only at:

`/Volumes/Pro2T/TraceValidation/reconciliation-identity-cleanup-followup`

They are not attached as downloadable repository or CI artifacts. The inventory
covers selected completed regular files and does not claim whole DerivedData,
XCResult, Git or source-export tree digests. Failed attempts and historical
validation remain preserved at their provenance paths.
