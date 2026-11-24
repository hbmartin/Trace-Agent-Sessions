# Adapter discovery and reproducible verification

Follow-up to merged #105. Frozen implementation and harness: `7643f1214ed789880d4ff6d9b7c2d0f91c626216`.
The branch starts at `e18e6d5a924bc9b9b251b180c64b94e85b60f2f2`; targeted baseline is pinned #105 HEAD `2257866e0d81907a76dc55cfd585830317553b54`.
The later evidence commit changes only this validation directory.

Changed-file discovery preserves legacy directory-enumerator adapters through an
additive opt-in capability. Accepted scope remains narrow; compatible configured
aliases share actual read outcomes, incompatible identities withhold coverage,
and built-in direct discovery follows hidden/package enumeration policy. File-only
passes avoid visible reconciliation progress. Stored-path matching normalizes once
per row/policy and avoids the former rows-times-scopes callback pattern. Metadata
routing uses captured provider roots. Verification receipts use product-relative,
streaming hashes; controlled fixture teardown and committed export instrumentation
make the benchmark reproducible without changing normal Core API.

Final validation passed: **740 affected native cases**, **135 script cases**, and
**60 focused executions across five repetitions** (35 native, 25 scripts). There
were no final failures or skips. The native selection includes indexing, watcher,
sidecar dependency, viewport and App follow-up groups. Debug/Release app builds,
external-client compatibility, project drift, signing, built-app network surface,
pinned whitespace, 337 source hashes,
and unchanged configured recursive vendor inputs are verified.

The selection-reentry test now seeds its existing failure prerequisite immediately
before publication. It remains a narrow publication invariant; it does not claim a
new end-to-end database-failure reproduction. Genuine database-failure and Retry
coverage remains in the affected App group.

## Targeted paired measurements

The first three 1,000-input workloads produced **15 recorded pairs** (30 recorded
samples; six warm-ups). Each has one warm-up plus five recorded samples per
revision. The user subsequently instructed **“Skip remaining measurements; publish
with limitations.”** The remaining 14 targeted workloads lack complete accepted comparisons; these
partial results are not full performance acceptance. Both exports use the same committed
instrumentation, harness definitions, configured dependency bytes, compiler and
`en_US` locale. Each sample checks correctness directly; no cleanup scan masks lost
coverage. Only the first three chronologically completed v3 workloads are reported. The
following interrupted warm-up pair is excluded; the waiting v4 job was cancelled
on the user's instruction before any workload began.

Elapsed medians in seconds (five recorded samples each):

| Workload | Inputs | Baseline | Candidate |
| --- | ---: | ---: | ---: |
| incremental / ascii | 1,000 | 0.448219 | 0.445314 |
| incremental / query-insensitive | 1,000 | 0.813830 | 0.003220 |
| incremental / unicode | 1,000 | 0.708071 | 0.460767 |

`targeted-summary.json` retains distinct CPU definitions, latency, physical
footprint, signed growth and phase metrics. Decoded-row instrumentation measures
materialized values, not SQL rows visited or physical I/O. The admission harness separates reservation, retirement and preparation, but no
final admission measurements are accepted in this partial report. Setup, validation,
control handshakes, exports and idle waits stay outside execution intervals.

## Retained attempts and limitations

All original results and failed/interrupted attempts remain local. The first
measurement attempt was contended. The pre-optimization batch exposed append
overhead and was deliberately stopped; the final candidate corrects that overhead
and has separate paired results. A later compiler job invalidated one warm-up;
its pair is excluded. The user waived the remaining measurements before another
workload began. This partial report excludes those invalid samples. The initial native TestClock timeout was not reproduced on the pinned
baseline; its cause remains inconclusive rather than being called unrelated.

Remaining targeted measurements were explicitly waived. UI, complete suites and
the three full Release comparison pairs remain omitted as selected. **No local
10% performance-acceptance claim is made.** Mixed-volume tests
inject captured policies instead of mounting a new volume. Conservative production
cleanup still rejects uncertain process ownership; it does not unconditionally
kill an unverifiable group. No migration, index-format change, retry timer or
breaking public signature is introduced.

Raw payloads are **local-only**, not downloadable repository/CI artifacts. Paths,
commands, hashes, summaries and preserved attempt classifications are recorded in
`raw-artifacts.json` and `verification.json`. Historical validation evidence is
unchanged.
