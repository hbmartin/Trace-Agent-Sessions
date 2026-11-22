# Navigation source ownership follow-up — November 22, 2026

Follow-up to merged [PR #97](https://github.com/hbmartin/Trace-Agent-Sessions/pull/97). Frozen implementation and harness: `e637490c2cfc39b0364c0172fcd8e1b2b04e43f3`; pinned merge base: `97f2b8de2188a85b7a058aba907dde0c68701aad`. Targeted comparison baseline: published #97 HEAD `9fbae14d6532f5f49dbe524d5b7166c689fdb479`.

**Incomplete checks:** the 28 selected UI cases and paired targeted measurements have not run. Fresh desktop-idle confirmation remains pending; these checks have not been waived. Both optimized revisions and all six workload executables are prepared. There is no new local 10% performance-acceptance claim. The three full Release comparison pairs and complete native suites are omitted as selected.

## Changes and evidence

Navigation obligations now keep provider/configured-root identity through observation and payment, including configured sources with no observations. Empty full scans retire global enrollment and displaced roster metadata. Scope enrollment follows installation-owned accepted/committed scope rather than a missing coverage cache. Uncommitted reset deferral retires only the captured original reset enrollment, retaining ordinary work and its retry budget.

Selection failure cleanup, completion and transcript ownership publish coherently under synchronous reentry. Failed recreated-session restoration can fulfill its requested window visibility through its current automatic owner without consuming Retry or showing the window twice. The shared native sample parser accepts generation-bearing payloads and preserves geometry/ownership checks.

Navigation-contention CPU/elapsed use the union of actual synchronous execution spans. Early observation is included, overlap is counted once, and gates/validation gaps are excluded. Same-thread observation CPU remains separate. Exact legacy fixture synchronization is explicit. These targeted timing corrections do not invalidate #97's separate full Release comparison results, same-thread CPU, or physical-footprint data; historical commands and raw snapshots were preserved.

[Finding dispositions](triage.md) distinguish seven confirmed fixes, two qualified state-retention fixes, and the invalid Sonar content-to-path claim. The qualified findings did not demonstrate an unconditional absence stall. No GitHub review thread or alert state was changed.

## Completed validation

- 769 affected tests: 230 indexing, 13 watcher, 64 metadata, 27 sidecar dependency, four viewport and 431 App follow-up cases.
- 119 ownership cases repeated five times: 595 passing executions.
- Actual Core test target compiled in Debug and Release. Four selected cases executed in Release: three retain behavior assertions; the empty-roster case is a construction/observation smoke run, with its state assertions exercised in DEBUG groups and races.
- Debug and normal Release app builds; external-client compatibility; 83 script tests; project drift, signing, runtime network-surface and pinned whitespace checks passed.
- The exact native parser passed standalone generation/legacy/null and nine malformed-input checks. This does not substitute for UI restoration/geometry execution.
- [Compiled discovery](selector-verification.json) verified all 28 [selected UI identifiers](selected-ui-tests.json) and 119 race identifiers.
- [One canonical source manifest](source-hashes.json) contains 531 regular tracked-file SHA-256 values, each verified against the frozen commit and working files. Symlinks and gitlinks are excluded; vendor state is preserved separately in local paired-build provenance.

One legacy App test remains excluded from the passing group: `testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData`. It reproduces the same timeout and `CancellationError()` as the published #97 runtime: one failed test and two reported issues. [Matching baseline evidence](known-transcript-classification.json) includes source equivalence and the unchanged test-body hash; its failure is retained separately.

## Attempts and limitations

All failed attempts remain local. Initial regressions exposed fixture synchronization mistakes that were corrected before final validation. Earlier candidates were superseded after empty-source review and test-contract hardening; their results were not relabeled as final evidence.

The first Release test recipes either omitted testability or attempted the whole App test scheme with DEBUG-only fixtures. Final validation builds the actual Core target with testability enabled and DEBUG disabled, then uses the direct XCTest launcher with package framework paths. An initial direct launch through `xcrun` lost its loader environment; its failure is preserved. The normal Release app build uses its ordinary configuration.

The first optimized archive build lacked dependency Git metadata required by the existing SQLite overlay setup. Isolated metadata, refs and indexes were added to the archives, sharing source objects read-only; original vendor files and prior artifacts were preserved. Both corrected optimized builds and six workload compilations pass. No timed sample or cleanup scan was run.

The planned targeted matrix has 32 cases: checkpoint enqueue/acceptance/backlog; plain, oversized, structural and alternating tracked/untracked ingress; coverage, pending target, short/long ledger and contention, and shared-root navigation at 1,000/10,000 inputs, plus short/long 5,000-file footprint cases. Each revision requires one warm-up and five recorded samples. CPU definitions, elapsed time, latency, signed physical footprint, retained state and correctness must be retained when those pending runs occur.

## Artifact availability

Raw payloads are **local-only**, not downloadable repository or CI attachments. Provenance root:

`/Volumes/Pro2T/TraceValidation/navigation-source-ownership-followup`

Receipt basenames in [verification.json](verification.json) refer to that directory. It retains command/input snapshots, logs, XCResults, compiled discovery, parser probes, baseline/candidate archives, isolated dependency metadata, binary/framework hashes and the unexecuted gated targeted driver. [Raw artifact manifest](raw-artifacts.json) specifies its selected-file inventory and digest. No upload is required.
