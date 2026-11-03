# Checkpoint coverage and restoration ownership

Follow-up to merged [PR #84](https://github.com/hbmartin/Trace-Agent-Sessions/pull/84).
Frozen implementation: `8f314a0754ea86ba68fcbfa476ed85bff98d3193`. Base: `12f16d38604ac8eaaa9c40a79c74605cda3740ee`.

## Behavior

Checkpoint and ordinary-completion receipts require actual path, reconciliation, or full-scan coverage. Narrow reset fallback leaves unrelated obligations unpaid. Partial discovery coverage survives failed-file recovery. Stop suppresses new coverage acceptance, while qualified persistence carries the execution's content generation into the write transaction. Uninitialized streams cannot invent an epoch; failed initialization leaves ordinary indexing active and waits for a real restart.

Watcher batches carry opaque per-stream wrap chronology. Same-epoch merges retain the maximum and delayed predecessor batches cannot lower a newer epoch. Legacy raw saves remain monotonic; wrap-safe clients use qualified updates. Existing reservation signatures and function-reference types remain available through a forwarding overload. `matchesAnchor` is additive and uses the resolver's external-ID precedence.

Bookmark restoration validates per-session intent through the final transcript suspension, preserves explicit clears, and survives unrelated summary supersession. Scroll updates reuse message-identity lookup data. Monitoring warnings derive from current failure episodes; provisional stream ownership retires on deferral/replacement. Same-database buffered work is retained until delivery or actual database replacement.

## Validation

- 172 affected Core/App tests passed, with no skips.
- Nine ownership races passed five repetitions: 45 additional executions. Internal success/failure and replacement/termination loops are not counted as additional XCTest methods.
- Debug/Release builds, external-client compatibility, project drift, signing, network surface, whitespace, and compiled discovery passed.
- All 53 script tests passed. Their exact script/test input hashes match the frozen candidate; the reused run and input equivalence are recorded explicitly.
- Eight selected UI identifiers compiled and match discovery; execution remains pending fresh desktop-idle confirmation.
- Targeted Release measurements remain blocked pending explicit user confirmation after automatic approval review applied an earlier follow-up's performance omission. No performance measurements or local 10% acceptance claim are reported.
- Ten final historical source hashes, the restored 12-entry `589d41d` map, all 80 historical artifact records, and 16 historical tree digests reproduced.

[Verification](verification.json), [canonical source hashes](source-hashes.json), [attempts](attempts.json), [compiled selections](compiled-selection.json), and [raw artifact digests](raw-artifacts.json) preserve evidence and failures. No database migration, schema/index-format change, or breaking public API change was introduced. No retry timer or production monitoring Retry control was added. Complete suites and three repository-wide Release comparison pairs were omitted as selected.

## Availability and pending work

Raw payloads are local-only and are not attached as downloadable repository or CI artifacts. Provenance: `/Volumes/Pro2T/TraceValidation/checkpoint-coverage-restoration-followup`; XCTest bundles reside under the recovery worktree's `build/` directory. Prior artifacts, unrelated vendor changes, triage records, and the primary checkout were preserved.

UI execution and targeted performance verification are pending; neither is silently waived. No merge was performed.
