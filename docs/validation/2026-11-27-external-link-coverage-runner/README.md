# External-link coverage and verification interruption evidence

Follow-up to merged PR #108. Frozen implementation/test candidate: `fe3427e19fbcdf117de74d1d9e82dc5a88bb7219`.
Base: `89d4e6a741fe797f86950c87ed2eb87df1148941`. Later commits contain validation documentation only.

The changes preserve lexical link membership through default adapter discovery,
reconcile ancestor-directory changes against known external links, withhold
external absence authority for failed/unknown discovery subtrees, and normalize
root qualification separately from case-sensitive external targets. The local UI
runner now requires Python 3.13+, preserves interruption when receipt writes fail,
and bounds its descendant fixture's fallback lifetime.

## Selected validation results

- The complete indexing/watcher/sidecar/viewport selection executed 319 cases: 310 passed and 9 failed. All 275 indexing regressions, including five new cases, passed. The nine failures are live watcher/sidecar controls.
- The six focused App regressions and 67 source safety/metadata cases passed.
- 6 Release behavioral regressions; affected Core test target compiled in Debug and Release.
- 156 script cases; the 64-case runner group also passed on Python 3.13. Unsupported Python 3.9/3.12 CLI checks returned code 2 before command launch.
- Five ownership repetitions: 40 native and 40 script executions, with no missing or skipped cases.
- Production Debug/Release app builds, external-client Release compilation, project drift, signing settings, actual app signatures, source and linked-binary network checks, and pinned whitespace passed.
- All 139 canonical input hashes match both the frozen Git commit and worktree. Pre-existing vendor inputs remain unchanged.

`verification.json`, `native-counts.json`, and `attempts.json` retain exact selectors,
commands, case counts, timing, and results. Source hashes have one canonical map
in `source-hashes.json`; no performance samples are accepted by these records.

## Failed and superseded attempts

The initial development script run (`scripts-first`) exposed a late-save fault
injection setup error and exceeded a 240-second watchdog before a final report.
That attempt and its incomplete output remain local. The corrected focused cases
and full script selection pass; no assertion or timeout inside the production
runner was weakened. This is not classified as an unrelated baseline failure.

The earlier 155-case script selection passed before the last signal-mask regression
was added. The 156-case script selection ran at `14367d9`; its production, script, and script-test inputs are byte-identical to this candidate. Only the Core test fixture parent changed afterward, and native tests were rebuilt. Development probes and earlier snapshots remain retained and excluded from accepted totals.

The initial Core runs exceeded their watchdog while fixture metadata discovery
walked the shared system temporary directory. The preserved baseline also did
not complete that control. The Core fixture helper now owns the metadata parent;
no production source, assertion, or per-test timeout was weakened.

The complete Core selection still fails nine live event cases, each reproduced
on the preserved #108 Release build. Eight reproduced in its complete watcher/
sidecar selection; the ninth was intermittent and reproduced on the fourth
bounded recheck. Passing rechecks are retained. Debug/Release configuration
differences limit that comparison; the underlying cause is undetermined.
`baseline-failure-comparison.json` records case-level evidence. These failures
remain failures, and native verification is not reported as green.

The broad App selection hit a 600-second watchdog without completing. Its
37 completed cases passed and one started case remained unfinished; that partial
run is not accepted. The six directly
relevant App cases subsequently passed in a separate complete invocation; no
baseline classification is made for the incomplete broad attempt.

## Explicit omissions and artifact availability

The user selected tests-only acceptance. UI execution, targeted measurements,
complete native suites, and the three full Release comparison pairs are omitted.
There is no local 10% performance-acceptance or unmeasured improvement claim.
This follow-up does not complete or retroactively waive PR #108's unrun measurements.

Raw payloads are local-only at `/Volumes/Pro2T/TraceValidation/external-link-coverage-runner-followup`. They are not attached as downloadable
repository or CI artifacts. `raw-artifacts.json` records top-level payload hashes
and identifies generated product/diagnostic directories without asserting their
recursive digests. Resource leases coordinate native work; they do not establish
whole-machine isolation or quiet-desktop measurement conditions.
