# Checkpoint coverage and restoration ownership

Follow-up to merged [PR #84](https://github.com/hbmartin/Trace-Agent-Sessions/pull/84).
Current frozen implementation: `d4e8ff171c0656851accbc459415cda0725e1769`. Base: `12f16d38604ac8eaaa9c40a79c74605cda3740ee`.

## Behavior

Checkpoint and ordinary-completion receipts require actual path, reconciliation, or full-scan coverage. Narrow reset fallback retains unrelated obligations. Partial discovery coverage survives failed-file recovery. Stop suppresses new acceptance; qualified persistence carries the execution's generation into the writer transaction. Uninitialized streams cannot invent an epoch, and failed initialization leaves live indexing active until a real restart.

Per-stream wrap lineage prevents delayed batches from lowering successor watermarks. Legacy raw saves remain monotonic; qualified updates provide wrap-safe persistence. Existing public call forms remain compatible. Bookmark restoration validates per-session intent through the final transcript suspension, retains explicit clears, and survives unrelated summary supersession. Source work transfers callbacks, reservations, delivery waiters, and safety intent together.

The targeted workload exposed repeated copies of a stream's record dictionary. Beginning and accepting coverage now mutate one locally owned stream dictionary at a time. Existing epoch, owner, version, mutation, and generation fences remain in place.

## Current validation

- 172 affected Core/App tests passed against the current candidate, with no skips.
- Nine ownership races passed five fresh repetitions: 45 additional executions.
- Debug/Release app builds, external-client compatibility, project drift, signing, network-surface, and whitespace checks passed again.
- The fresh 53-case script run is reused only with exact script/test input equivalence, recorded in [current status](corrected-validation-status.json).
- Eight selected UI cases passed on the prior benchmark candidate. They are not reused for the corrected implementation: its UI attempt was blocked by a newly issued protected macOS access prompt and was interrupted. Manual approval remains pending.
- Eleven exploratory checkpoint samples from the prior candidate are retained. That attempt had competing native compilers and a 50k gate timeout, so it is not accepted validation. The current candidate has no accepted targeted measurements yet.
- Complete suites and three repository-wide Release comparison pairs remain omitted as selected. No local 10% performance-acceptance claim is made.

[Current status](corrected-validation-status.json) and [canonical current hashes](corrected-source-hashes.json) identify the corrected implementation and its validation. No migration, schema/index-format change, breaking public API change, retry timer, or production monitoring Retry control was introduced.

## Preserved evidence

The initial implementation snapshot is `8f314a0754ea86ba68fcbfa476ed85bff98d3193`; its [verification](verification.json), [source hashes](source-hashes.json), [attempts](attempts.json), [compiled selections](compiled-selection.json), and [raw digests](raw-artifacts.json) remain unchanged. [Intermediate workload status](additional-validation-status.json) and [its hashes](targeted-source-hashes.json) retain the later approval and preparation history. Prior runs do not validate changed candidate inputs.

Ten final historical source hashes, the restored 12-entry `589d41d` map, 80 historical artifact records, and 16 historical tree digests reproduced. Earlier raw snapshots, failed attempts, triage files, vendor changes, and the primary checkout were preserved.

Raw payloads are local-only and are not downloadable repository or CI attachments. Provenance: `/Volumes/Pro2T/TraceValidation/checkpoint-coverage-restoration-followup`; XCTest bundles are in the recovery worktree's `build/` directory. UI and measurement validation remain incomplete for the current candidate. No merge was performed.
