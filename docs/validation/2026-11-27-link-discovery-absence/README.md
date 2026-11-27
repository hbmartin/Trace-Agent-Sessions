# Link discovery and interruption verification

Follow-up to merged #109. Frozen implementation and harness: 0d5b819011b2b4173b08c82a62690616d4194bcc.
Branch base: 47bfd93c21e29896fd77517a5aa6ad79067a2c37.
Targeted baseline: f91336d2aa3f68b851fdd461e8823a50e962a710.
Later documentation commits do not change implementation or harness inputs.

## Completed checks and limits

The indexing group executed 283 cases with
1 environment-specific skip and no failures;
the skipped /var-alias case passed separately under its required layout.
All 67 source-safety/metadata cases, 7 focused App cases, 8 Release behavioral
cases, and 160 script cases passed. Five ownership repetitions executed
45 Core cases and 40 script cases.
Selected Debug groups executed 397 cases: 394 passed, 2 failed, and 1 was
skipped for the required /var layout. The separate /var run passed.

The watcher/sidecar failures remain failures:
both reproduced at matching assertion sites and messages in pinned #109
Debug checks; none remain unmatched. Passing attempts and duplicate
Objective-C class warnings are retained. The bounded comparisons establish
neither a root cause nor a failure rate. See baseline-comparison.json.

Production Debug/Release builds, external-client compilation, project drift,
signing settings, actual signatures, network checks, pinned whitespace and all
140 frozen source-input hashes passed. Original vendor
inputs, revision and dirty status remain preserved.

Targeted paired measurements remain unrun. The user requested ready-PR
publication after this remaining gate was disclosed. The compiled workloads
and verified baseline/candidate inputs are retained; they are not measurement
results or a performance-acceptance waiver.
UI execution, complete native suites and three full Release comparison pairs
are omitted as selected. No local 10% performance-acceptance claim is made.
These results do not complete an earlier PR's unrun gate retroactively.

## Behavior and focused regressions

Legacy discovery retains recognized unavailable-link candidates for individual
read failures; rich discovery returns healthy files with file-local failures.
Deletion and navigation share captured failure qualification. Unknown subtrees
and unreadable intermediate links withhold external absence, while explicit
healthy observations qualify independently. Duplicate root IDs do not trap.
Every SQL query policy validates root/provider ownership.

The controlled permission probe initially reproduced deletion of a cached row
while the intermediate link was unreadable. The final regression retains that
row and withholds absence, then verifies recovery after access returns.
Healthy discovery values use optional reference storage for failure evidence.
Healthy links retain the Foundation fast path. Lexical joining avoids
per-component directory-inference operations.

Case-level final saves preserve interruption and cleanup outcomes. Signal-mask
restoration includes acquisition failure. Original launch, nonreaping-wait,
descriptor-ownership and first-signal regressions remain covered.

## Storage recovery and provenance

The startup volume reported ENOSPC and SQLite IO errors during proof-stage
checks. Those failed attempts remain storage-invalid and are not counted as
passing validation. A later, explicitly selected external APFS fixture root
passed the permission-denial fidelity check. Recovered verification runs
serially; the first Release app setup attempt also failed beside Xcode cache
disk-I/O diagnostics, its direct GRDB configuration probe passed, and the
preserved Release retry passed. Fixtures retain normal system-temp defaults
when their opt-in is unset.

The first whole-script attempt expired at 360 seconds. Its verbose rerun passed;
both remain retained. Earlier code candidates f0ca9d8, 93ba752 and 1f0ddab are
historical and cannot substitute for the recovered final-candidate results.

source-hashes.json is the single canonical input map for the frozen candidate;
each entry was compared with Git and worktree bytes. attempts.json preserves
commands, failures and limits without rewriting historical commands.

Raw payloads are local-only, not downloadable repository or CI artifacts.
raw-artifacts.json records provenance paths and top-level file hashes.
Directory entries make no recursive tree-digest claim. Later publication
receipts are outside that timestamped inventory.
