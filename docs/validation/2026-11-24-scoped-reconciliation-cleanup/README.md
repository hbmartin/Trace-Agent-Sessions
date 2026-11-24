# Scoped reconciliation and verification cleanup

Follow-up to merged PR #103. Base: `6f454f5ad05d49abb29f48df2709a21977ba6703`.
Frozen implementation and harness: `a4f453a258e03ba3155d0fc269efc7f5137fcf77`.
Subsequent documentation commits contain evidence only.

Incremental discovery still belongs to the adapter. Reconciliation now queries
stored candidates for the attempted root and scopes, batches large input sets,
and uses captured path identity instead of re-resolving stored paths. Failed
scopes, aliases, deleted inputs, literal wildcard characters, Unicode case rules,
and custom filenames retain their coverage semantics. Case-insensitive filtering
runs in SQLite; this is not a claim of sublinear SQL execution. The counter counts
`IndexedSourcePath` objects decoded, not SQLite rows/pages internally visited.

The verification runner inspects process-group membership and state before
signalling. Reaped/zombie-only groups can finish cleanup; unknown or live denied
members remain batch-fatal. Group inspection is bounded, TERM/KILL deadlines and
interruption precedence remain intact, and a recycled live leader is rejected.
Finalization has an explicit test seam under the existing handler/cwd restoration
guard. SDK provenance uses one captured version.

Metadata benchmark extraction recognizes supported signatures explicitly. Mixed
admission validates expected work before retirement, outside reservation timing.
No public Core interface, migration, index format or application retry timer changes.

## Completed checks

- 729 affected native cases passed: 242 indexing, 27 sidecar dependency, 13 watcher,
  4 viewport and 443 App follow-up cases; no failures or skips.
- Fifteen native selectors ran five times each: 75 executions. Five cleanup,
  interruption and finalization selectors also ran five times each: 25 executions.
- All 126 script tests passed. The formerly failing hosted script step also passed
  for candidate `a4f453a` in Actions run `45421372887`; other CI steps were still
  running when that snapshot was captured.
- Debug/Release builds, external-client compatibility, project drift, signing,
  network surface and pinned whitespace checks passed. Compiled discovery ran
  without executing UI tests.
- Synchronized optimized baseline/candidate workloads compiled against pinned
  #103 HEAD `387527b9bb00bca52902395a70d6a692792615e0` and the frozen candidate.
- Two-input correctness probes passed for both incremental binaries, preserving
  100 appends and the unrelated sessions. They decoded 300 and 100 reconciliation
  objects respectively. These are structural correctness observations, not
  accepted performance comparisons.
- The mixed-admission positive probe passed. A negative control that discards
  in-root navigation work exited 2 with `correct=false`, despite zero final debt.
- All 333 entries in the canonical source manifest match the frozen commit and
  working bytes. Recursive vendor inputs remain identical to the prior snapshot.

Exact commands, hashes, counts, probe outputs and failed attempts are recorded in
`verification.json` and the associated manifests. Original #103 CI failures remain
in the local raw evidence. No failed attempt is labelled unrelated without proof.

## Limitations and deferred acceptance

The user explicitly chose **“Skip measurements; publish with that limitation.”**
The paired 1,000/10,000-input measurements were not run. Small probes were executed
for correctness only; their emitted timing/footprint fields are not performance
samples. No speedup, footprint improvement or local 10% acceptance is claimed.

UI execution, complete native suites, and the three full Release comparison pairs
are omitted by the approved plan. This follow-up contains no renderer changes.
The paired driver remains gated and was not launched; no desktop-ready lease was
created.

The constant-argv `xcrun` command-injection annotations are invalid: neither call
uses a shell or request-derived arguments. The duplicate SDK query was independently
removed. Existing review threads and external alert states were left unchanged.
The finalization extraction improves the test seam; it is not presented as a fix
for a reproduced handler-restoration leak.

## Raw evidence

Raw payloads are local-only at:

`/Volumes/Pro2T/TraceValidation/scoped-reconciliation-cleanup-followup`

They are not attached as downloadable repository or CI artifacts. Source exports,
compiled binaries, XCResults, logs, failed preparations and negative controls remain
at their provenance paths. `raw-artifacts.json` inventories selected completed
regular files, not entire DerivedData, Git, XCResult or source-export trees.
Historical validation and vendor changes remain preserved.
