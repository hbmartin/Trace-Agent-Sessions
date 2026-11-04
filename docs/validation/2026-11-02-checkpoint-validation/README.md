# Checkpoint validation follow-up

Follow-up to merged [PR #83](https://github.com/hbmartin/Trace-Agent-Sessions/pull/83).
Implementation candidate: `81c27891aae616813db367e02e1dc5177f06bae0`. Base: `66511124abcbd15e38417009f8c8b792762c6e78`.

## Results

- Nine focused checkpoint/bookmark Core/App tests passed.
- Three held-read ownership cases passed five consecutive repetitions: 15 additional XCTest executions. The checkpoint-completion test exercises four success/failure × replacement/termination combinations internally.
- The UI target compiled and both selected identifiers match compiled XCTest discovery. The two cases remain unrun, pending fresh desktop-idle confirmation. The ready PR is published at the user’s request with this limitation; no UI verification claim is made.
- Debug/Release builds, external-client compatibility, compiled test discovery, 53 script tests, project drift, signing, network surface, and whitespace checks passed.
- The temporary negative control failed as expected on all four assertions: message identity, offset, index, and explicit clear. This is separate from the completed final-candidate non-UI validation, which passed.
- Ten historical source hashes and all 80 historical artifact records reproduced, including 16 tree digests. Original raw files and recorded historical digest values were preserved.

[Verification](verification.json), [source hashes](source-hashes.json), [attempts](attempts.json), [historical verification](historical-verification.json), [focused selection](focused-selectors.json), [race selection](race-selectors.json), [UI selection](ui-selectors.json), and [artifact hashes](raw-artifacts.json) identify the validated inputs. Documentation-only commits may follow the implementation candidate without changing its frozen inputs. The source manifest contains one canonical map, checked against both the commit blobs and the worktree.

## Changes exercised

The bookmark regression now waits for the pending store to drain and checks the latest bookmark or clear without launching a replacement summary refresh. The stale checkpoint test covers successful and failed reads after database replacement and termination, with no obsolete warning, diagnostic, ledger seed, or checkpoint write. The historical candidate used a DEBUG-only post-call seed observer. The follow-up replaces that surrogate with assertions on the actual ledger, including a positive initialization control.

The UI warning assertion waits for accessibility-tree disappearance. The external fixture passes wrapped-stream metadata into reservation creation. Historical evidence identifies the earlier `589d41d` hash map separately from final candidate `f06c853`, specifies the existing digest encoding and path-component ordering precisely, and states the availability of local raw payloads explicitly.

No production behavior, public API, schema, index format, retry policy, or scheduler ownership changed. The temporary revision-validation bypass was restored byte-for-byte before freezing the candidate. Complete suites, optimized performance measurements, and Release comparison pairs were omitted as selected; no local 10% performance-acceptance claim is made.

## Raw evidence and limitations

Raw payloads are local-only and are not attached as downloadable repository or CI artifacts. The paths identify retained provenance, not public download locations.

Raw evidence: `/Volumes/Pro2T/TraceValidation/checkpoint-validation-followup`.
XCTest bundles: `/Volumes/Pro2T/TraceWorktrees/rebuild-live-updates/build/checkpoint-validation-*.xcresult`.
The full per-file tree inventory is retained locally. The primary checkout, unrelated vendor changes, triage metadata, and all earlier validation artifacts were preserved. No merge was performed.
