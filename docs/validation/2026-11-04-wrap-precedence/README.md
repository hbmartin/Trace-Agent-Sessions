# Preserve wrapped-event recovery precedence

Follow-up to merged [PR #86](https://github.com/hbmartin/Trace-Agent-Sessions/pull/86), addressing [the combined-flags comment](https://github.com/hbmartin/Trace-Agent-Sessions/pull/86#discussion_r4469691454).
Frozen implementation: `05c0c2f2ce9d310a164aa4b7b57a151af11b1123`. Base: `7f827a770b61f9624dd82aec5246c9d33daba7b1`.

## Finding and fix

The reviewed watcher first included global wrap control, then included the accepted path after removing the wrap bit. For combined `RootChanged` or `MustScanSubDirs` flags, that second include entered local recovery branches that the original wrapped event suppressed. It added the changed path and a local recovery reason. `CodexMetadataWatcher.receive` uses `.rootChanged` to restart streams.

Accepted events now call `SourceChanges.include` once with their original flags. Rejected wrapped paths still include unfilterable global wrap control. This preserves global recovery precedence, structural/path/history metadata, and exactly one epoch transition without changing public signatures or `SourceChanges.include`.

## Validation

- The new regression failed against the exact reviewed watcher source at `f0ec90a4852c09f598966857e1184cecc26bc7db`: one expected failed test, 24 assertion failures. The before-fix inputs and logs are retained.
- 245 Core watcher, metadata, and indexing cases passed with no failures or skips.
- Three wrap cases passed five separate serial invocations: 15 additional XCTest executions.
- The new regression is one XCTest method with 56 internal combinations of wrap/local/drop/history/structural flags, accepted/rejected filtering, and tracked/untracked watermarks. Internal scenarios are not counted as additional tests.
- Debug/Release app builds, external-client compatibility, project drift, signing, network surface, and whitespace checks passed.
- All 105 [canonical input hashes](source-hashes.json) match both the frozen commit and final working tree.

## Limits and evidence

Complete suites, App test execution, UI automation, and Release performance comparisons were not run for this follow-up. No local 10% performance-acceptance claim is made, and prior candidate results are not reused. This change adds no migration, public-interface change, scheduler behavior, or retry timer.

[Verification](verification.json) retains commands and outcomes; [raw-file hashes](raw-artifacts.json) identify local evidence. Raw payloads are local-only and are not downloadable repository or CI attachments. Provenance: `/Volumes/Pro2T/TraceValidation/wrapped-event-precedence-followup`. XCTest bundles remain under the recovery worktree's `build/` directory. Vendor changes, triage records, and prior artifacts were preserved. No merge was performed.
