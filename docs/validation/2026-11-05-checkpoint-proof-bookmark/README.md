# Preserve checkpoint proofs and bookmark intent

Follow-up to merged [PR #87](https://github.com/hbmartin/Trace-Agent-Sessions/pull/87).
Frozen implementation: `c8a5ca8aa16cb0942f0d1d59cd0f22ac95bd573e`.
Base: `d7310a23ff61475e80d26121dc62a6ed6d06d2cb`.

## Change

Checkpoint work has stable obligation identities independent of watermark metadata. Immutable, canonical execution proofs live in the database-owned ledger, survive compatible scheduler replacement, and apply in execution order. Acceptance and prefix advancement process bounded batches of 128 records. Queued reset fencing preserves paid work; committed reset invalidation happens at the reset transaction boundary, including scope resets.

Failed checkpoint initialization pauses only persistence. Ordinary indexing continues, a safe monitoring warning is published for the current owner, and actual monitoring or scheduler replacement retries initialization. Watcher ingress uses serial coalescing mailboxes. Explicit stream controls preserve wrap, drop, and history metadata through content filtering; global wrap recovery retains precedence over local RootChanged recovery. A genuine zero-ID wrap requires complete root reconciliation in its new epoch.

Bookmark slots carry generation, source identity, and ownership tokens. Obsolete numeric cleanup cannot delete a newly restored slot after row-ID reuse. The active bookmark remains a fallback, newer scroll/clear intent wins, and full-refresh demand received during resolution receives a successor attempt.

## Frozen validation

- 659 affected Core/App tests passed, including SidecarDependencyTests.
- Twenty ownership regressions passed in five serial repetitions: 100 additional executions.
- 58 script tests passed. Debug/Release app builds, external-client compatibility, project drift, signing, network surface, and pinned whitespace checks passed.
- All twelve selected UI identifiers match compiled discovery (172 discovered cases). Execution remains pending desktop readiness and completion of competing native checks.
- One transcript timeout is excluded from the focused selection: `testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData`. It failed on both candidate and exact base `d7310a2` (one failed test, two assertion failures). Matching baseline logs and result bundle are retained.
- All 389 canonical input hashes match both the frozen commit and worktree.

## Publication and pending acceptance

The paired targeted enqueue/acceptance binaries are compiled against pinned #87 `398769c9db02cbf647ce1072dd8d378453cfcb35` and the frozen candidate. Tiny correctness smokes passed; those timings are not acceptance samples. The targeted warm-up/five-sample workloads and three required Release pairs against `61c00de` remain pending. No local 10% performance-acceptance claim is made yet.

The ready PR is published for review at the user’s request. This changes publication timing; the approved UI and local performance acceptance requirements remain outstanding. No performance omission or acceptance waiver is inferred.

Complete test suites remain outside scope. No schema migration, index-format change, or breaking public interface change is included.

## Evidence

One canonical [input hash map](source-hashes.json) identifies the frozen candidate. Validation records are append-only relative to earlier follow-ups; prior reports and failed attempts remain intact. Raw payloads are local-only, not downloadable repository or CI attachments. Provenance: `/Volumes/Pro2T/TraceValidation/checkpoint-proof-bookmark-followup`; XCTest bundles remain under the recovery worktree's `build/` directory. Vendor changes and triage records are preserved. No merge is authorized.
