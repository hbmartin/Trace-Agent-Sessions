# Navigation intent and source coverage through recovery

Frozen implementation and harness: `67f62626067af39509e1275235c0c4b84a549e67`. Base: `9bd76f52fde82627c54a6b4a6d6bb15b99053b12` (merged [PR #95](https://github.com/hbmartin/Trace-Agent-Sessions/pull/95)); paired baseline: `6c21e794d774776e1a7b511306912823d440e43f`. Later documentation commits do not change implementation inputs.

## Result

Renderer saves carry explicit origin and generation, source, selection-request, and user-revision ownership. An unavailable owner cannot turn a programmatic save into user intent. The same fence protects native target consumption and restoration receipts. Valid programmatic saves persist achieved positions without retiring pending search intent.

Search intent follows its stable anchor through a second reset, source moves and rewrites, and row remapping. Unsupported numeric targets settle without dead Retry. Pending lookups coalesce successor demand and preserve readable content through private lookup failures. Explicit reader Retry can refresh during indexing and retains genuine read errors until successful recovery. Cached rows are reused only with matching source revision, generation, complete row count and target identity; absent anchors need no row scan in that accepted snapshot.

Opaque source-work receipts enroll before buffering or recovery and travel with fragments, merges, startup, replacement, and retries. New same-source work immediately withholds absence authority. Only actual successful terminal source observations pay it. Coverage uses immutable shared scope-index nodes, so a one-file update does not filter the retained whole-file dictionary. Qualification follows the validated resolved source, rather than a now-covered obsolete path after a move.

Checkpoint returns retain their scope, generation, epoch qualification, activity and shared completion identity. Scope-only replacement requires fresh compatible coverage. Valid legacy activity completes once with an empty map when values are filtered; qualified callbacks remain checkpoint-only. A synchronously closed publication lifetime rejects late permit enrollment and stop joins admitted work.

## Validation status

- Focused groups: 746 passing cases (IndexingRegressionTests: 221, FSEventsWatcherTests: 13, SessionMetadataTests: 64, SidecarDependencyTests: 27, TranscriptViewportPolicyTests: 4, AppReviewFollowupTests: 417). Complete suites are outside scope.
- Scripts: 78 passing cases.
- Ownership selection: 96 cases; 5 of five repetitions complete. See `verification.json` for current command results.
- All 18 selected UI identifiers are checked against compiled XCTest discovery. Desktop execution and paired targeted measurements are **unrun**. After being offered publication with these limitations, the user instructed “open ready PR”; publication proceeds on that basis. Compiled discovery and correctness-only preflights do not replace those checks.
- Debug/Release builds, external-client compatibility, project drift, signing settings, network surface, scripts and pinned whitespace checks are recorded individually. Pending commands are not reported as passes.
- The isolated `testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData` state timeout followed by cancellation also reproduces on pinned #95: one failed test, two issues. The frozen candidate is checked separately; it is excluded from the passing focused group, not hidden as a pass.

## Targeted measurement contract

Required paired optimized modes are enqueue, acceptance, backlog, mailbox plain/oversized/structural/alternating tracked-untracked, coverage-cache scaling and pending-target reads, at 1,000 and 10,000 inputs. Each revision receives one warm-up and five recorded samples. Grouping is unchanged. Tiny optimized preflight runs validate correctness and fixture release; their timings are not performance acceptance.

Both revisions use the same instrumentation and preparation contract. Acceptance CPU is same-thread execution CPU; process workload CPU is reported separately. Mailbox timing includes normalization, reservation and main-actor delivery. It validates delivery/provenance and retained unpaid ledger state; scheduler workloads validate checkpoint outcomes without a cleanup scan masking lost proof. The exact extracted pending resolver runs against a real database and a coherent 127-row provisional reader; it isolates lookup/read/publication counts and excludes AppKit rendering and model-observer costs. Cache runs assert positive initial coverage and negative final coverage using captured canonical source paths. Setup, preflight, handshakes, correctness exports and retained-footprint waits remain outside timing.

Complete suites and the three full Release comparison pairs are intentionally omitted. **No local 10% performance-acceptance claim is made.**

## Evidence and qualifications

`source-hashes.json` is the only canonical source map for the final frozen candidate; every entry is verified against that commit and the checkout. `raw-artifacts.json` preserves hashes and provenance paths for local payloads. They are **local-only**, not downloadable repository or CI attachments. Earlier failed attempts, snapshots, and result bundles are retained. The candidate-02 discovery attempt rejected an existing output path; later outputs are versioned. Candidate-05 checks were retired after its in-flight Release build completed, before entering another command.

The earlier captured-intent overlap and publication-admission report retain narrow ownership tests where the complete original race has not been demonstrated. The source move qualification edge is reproduced by `relocation-probe-v2-run.json` and a real move/rewrite App regression. Ownerless renderer rejection is defensive contract coverage; selected UI exercises the complete restoration path when desktop validation is available.

No database migration, index-format change, breaking public signature, or application retry timer is added. Publisher locking, admission barriers, independent retry budgets, accessibility identifiers, and existing recovery policies remain.
