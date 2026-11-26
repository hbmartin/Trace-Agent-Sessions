# Discovery membership and interruption ownership

Follow-up to merged #107. Frozen implementation/test candidate: `a511d9d6a5d0abac89b611ecb799779fce52c894`.
Pinned baseline: `a8732af55a5595974d20260cc81d854eb3c50895`; main base:
`753b578a2eb6aa4ef9aafdb95c9c6d6dd1125dc4`.

**Ready publication is requested with targeted measurements incomplete.**
After being told the ready PR was waiting on this gate, the user requested
“open ready PR.” This authorizes publication now; it does not establish performance
acceptance. No accepted timing samples are recorded. UI tests, complete native
suites, and three full Release comparison pairs are omitted by the selected plan.
No local 10% performance-acceptance claim or unmeasured CPU/footprint improvement
is made. See [the publication decision](publication.json).

## Resulting behavior

- Root availability failures stay with their owning root. Genuine contained
  subtree failures remain shareable; canonical alias failures still deduplicate.
- Root-owned regular-file links may target outside the root. Discovery preserves
  lexical membership separately from canonical ingestion. Live observed link
  changes reconcile the owning root; no external-directory watcher is added.
  Missing/invalid targets withhold coverage and preserve rows until authoritative
  recovery. External read failures fence the root's checkpoint normally.
- Incompatible returned identities create file-local failures. Discovery scope
  matching normalizes once per file/policy and uses prefix lookup. Transparent
  wrappers forward exact-file capability and scoped discovery.
- Each GRDB connection owns a stable, non-pure SQL matcher function. Query-local
  context is restored on throw/nesting, independent concurrent readers retain
  their own contexts, and repeated execution does not expire prepared statements.
- The runner keeps its child unreaped until owned-group cleanup finishes. One
  signal-collection lifetime covers launch, waiting, cleanup, persistence, and
  handler restoration. A second signal cannot bypass cleanup. An already-reaped
  or otherwise unproven handle still fails closed rather than signaling strangers.
- Benchmark preparation preserves canonical source provenance, records actual
  input bytes, and atomically replaces output. Descriptor release masks signals
  across ownership transfer and close. Both historical layouts are documented.

Admission benchmark metric version 2 remains unchanged: it accumulates admissions
before separately timed retirement. Version 1 is not comparable without rerunning
synchronized harnesses. File-only refreshes keep their existing presentation.
The defensive internal root/provider-query asymmetry is unchanged.

## Completed validation

- **759 affected Debug cases passed:** 314 indexing/watcher/metadata-sidecar/viewport
  Core cases and 445 App follow-up cases; zero missing or skipped cases.
- **10 Release behavioral cases passed**, and the actual Core test target compiled
  in Debug and Release. DEBUG-only matcher counter assertions run in Debug.
- **149 script tests passed.** Five final ownership repetitions passed 30 native
  and 40 script executions. Exact selectors and native counts are committed.
- Normal Debug/Release app builds, the external-client fixture (legacy and additive
  file-location APIs), project drift, signing settings, built app signatures,
  runtime network surface, and pinned whitespace checks passed.
- Preserved vendor bytes match the initial snapshot. One canonical source map is
  verified against its frozen Git commit and working bytes. No historical map or
  raw attempt was rewritten.
- Both optimized revisions and all three shared Swift clients compile. Each
  revision passes six incremental/query modes, discovery, query/write contention,
  and live/zombie/early-exit process-cleanup correctness smokes. Twenty-four invalid
  count cases reject input before setup. These small runs are not measurements.

The final Core group used the existing cooperative desktop/native-build lease,
without messaging another chat, to prevent competing native admission. This is
noninteractive XCTest coordination, not a claim of desktop UI isolation. The
extra Release launcher initially lost its framework environment through `xcrun`;
the direct Xcode XCTest executable ran all ten selected cases successfully.

## Retained failures and corrections

Initial compilation exposed naming/Sendable-capture mistakes, a lifecycle-request
test signature mismatch, and a DEBUG-only helper called by a Release test. Those
were corrected, with final successful builds recorded separately. A hosted Core
attempt timed out before executing tests; direct non-hosted XCTest executes and
verifies actual case counts instead. An earlier full build timed out during test
compilation. Its logs remain available.

The expanded discovery tests caught loss of captured lexical failure scopes.
The broad group then caught overly broad lexical preservation splitting canonical
alias failures. Both were fixed without weakening their assertions. One new
checkpoint test timed out during installation overlap; it now explicitly owns a
settled installation, while existing activation-overlap regressions remain.

Earlier native attempts recorded a live-checkpoint watcher timeout, late startup
metadata traffic, and filesystem callback admission exceeding its wall-clock
backstop. They remain failures in the attempt inventory; they are not classified
as unrelated or excused by an unrun baseline. The isolated checkpoint transition,
final serial App group, and final lease-owned Core group pass with assertions
unchanged. Five final ownership repetitions also pass.

XcodeGen 2.49 added `buildArchitectures="Automatic"` to generated schemes. The
metadata is synchronized and a second generation is stable; arm64 build settings
remain explicit. The failed first drift attempt is retained.

## Evidence and remaining acceptance

[Verification](verification.json), [execution counts](native-counts.json),
[attempts](attempts.json), [source map](source-hashes.json), and
[input qualification](input-equivalence.json) identify the exact evidence.
The optimized source export is `c8a8c5d`; the final candidate differs only in a
Release-compatible Core-test wait and generated scheme metadata. All normalized
Core and measurement-harness inputs match the frozen final candidate explicitly.

Raw results and product/source exports remain at:
`/Volumes/Pro2T/TraceValidation/discovery-signal-ownership-followup`.
They are **local-only**, not downloadable repository or CI artifacts; provenance
paths are listed in [the raw inventory](raw-artifacts.json).

After the pending desktop-idle confirmation and completion of competing native
checks, run the approved paired optimized scope/discovery, cold/warm reconciliation,
query/write-contention, and owned-process-cleanup workloads: one warm-up and five
recorded samples per workload/revision. Keep actual filesystem policy separate
from forced-query policy, preserve signed footprint and invalid attempts, and
reject incorrect samples. No cleanup scan may mask missing work. The user has
requested the ready, unmerged follow-up now with this gate explicitly incomplete;
publication is not evidence that performance acceptance passed.
