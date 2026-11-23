# Local verification gates and recovered UI coverage

Follow-up to merged [PR #99](https://github.com/hbmartin/Trace-Agent-Sessions/pull/99). Frozen implementation: `cbb8faeb1b8d09c6e738f6b6ec93d3bd574b02da`; pinned baseline: `8f6c816732eda0b11752f662fc88dfe50bbf8c74`. Later documentation-only commits append evidence without changing that candidate.

## Changes

The terminal reread fixture now distinguishes cancellation before admission from cancellation after synchronous terminal publication. The former is rejected without a read; the latter must preserve workflow-owned rereading. The root-refresh-debt fixture explicitly holds and settles the independent Costs worker before asserting that retained metadata debt is idle. Recovery fixtures join the failed pass before advancing virtual time, and the monitoring fixture waits for replacement startup completion before reading reconciled rows. Production model behavior is unchanged. The local UI runner retains normal Debug signing after disabling signing prevented launch before app code.

UI verification is local-only on the current physical desktop. Hosted UI and interactive transcript-scroll entrypoints are disabled and removed. Ordinary CI retains builds, noninteractive Core/App tests, script checks and CLI fixtures, and uploads unit-test result bundles even after failure. The selected runner rejects CI environments and reuses prepared DerivedData. No VM, UTM or extra account was used.

## Validation

All 28 selected UI identifiers have an accepted passing result with zero skips: the main attempt passed 26; the two cases interrupted by unrelated windows passed once each after clearing that interference. The original 28-case attempt remains failed and is not relabeled. See [per-case evidence](ui-coverage.json).

Final checks passed against the frozen implementation:

- 834 Core/App cases, with no failures or skips.
- 20 ownership cases repeated five times: 100 passing executions. XCResult summaries count 20 unique cases; detailed logs establish all 100 executions.
- 93 script tests.
- Debug/Release builds, external-client compatibility, project drift, signing, runtime network-surface and pinned whitespace checks.
- Final compiled discovery verified all 28 UI and 20 ownership selectors.

[Full CI also passed for the frozen implementation](ci-completion.json), including the unit tests and both CLI build stages. This completion record appends to the earlier in-progress snapshot; documentation-only refresh checks run separately.

[Machine-readable verification](verification.json) records exact commands, hashes and limitations. Every selected UI identifier must be present in compiled discovery and execute successfully without skips. Each local case has a separate log, XCResult and exported summary; failures remain evidence rather than being retried automatically. Accepted UI summaries contain 21 SwiftUI “Publishing changes from within view updates” warnings and one QoS inversion warning. These entries are retained in the per-case evidence; their baseline status was not investigated and no warning-free claim is made.

The UI batch runs the frozen UI revision `5de596b90e2fcb63c67b1ddc5519c44169eb7aa4`. Its differences from the final implementation are non-UI test-fixture synchronization changes. Runtime, UI-test, project, configuration and runner inputs are byte-identical, as verified in ui-input-equivalence.json.

The canonical source manifest covers regular tracked Git blobs from the frozen implementation. Each entry was verified against that commit and working bytes. Symlinks and gitlinks are excluded. Existing vendor changes and prior artifacts remain preserved separately.

## Failures and corrections

The unchanged baseline terminal fixture timed out because it cancelled delivery before admission, then waited for an inadmissible read. Temporary diagnostic publications established that boundary and were removed before the candidate. The root-only baseline repetitions passed; the root fixture correction addresses its observed independent Costs-worker timing rather than claiming a universal baseline failure.

Earlier CI attempts exposed retry tests advancing TestClock before delayed-retry bookkeeping, the monitoring fixture reading after submission rather than completion, and a summary-recovery test assuming its initial virtual sleep was already registered. Exact scope-enrollment fixtures also now suppress uncontrolled live ingress before watcher installation, rather than after initial work could already be admitted. Those synchronization fixes preserve the existing publication gates and exact behavioral/count assertions. Their logs and candidates are preserved. Local setup failures include an accessor typo corrected to existing worker controls and a discovery output/receipt filename collision corrected with distinct paths. The first unsigned UI launch failed before app code. A signed diagnostic run reached the rebuild action, but the retained recording shows another app taking focus during synthesis; its missing marker and reporting timeout are not accepted restoration evidence. Both attempts and process samples remain preserved. No failed attempt was relabeled as passing evidence.

## External gate limitation

The confirmed log-path false positive in [GitHub alert 122](https://github.com/hbmartin/Trace-Agent-Sessions/security/code-scanning/122) was dismissed and its [PR #99 review thread](https://github.com/hbmartin/Trace-Agent-Sessions/pull/99#discussion_r4660804111) resolved. Log names use fixed phase labels or decimal enumeration indices; selection contents do not control the destination.

The separate [SonarCloud issue AaIFfB2dBLOuwLylZxaf](https://sonarcloud.io/project/issues?id=hbmartin_Trace-Agent-Sessions&issues=AaIFfB2dBLOuwLylZxaf&open=AaIFfB2dBLOuwLylZxaf) remains unresolved: updating its disposition returned HTTP 401 and requires account authentication. The user explicitly selected “Leave upstream gate as a limitation.” No green SonarCloud gate is claimed and no code was changed solely to silence it.

## Scope and artifacts

No performance measurements or local 10% acceptance claim. Complete UI suites, migrations, public API changes and retry timers remain outside scope.

Raw local payloads are local-only and are not downloadable repository or CI attachments. Provenance root: `/Volumes/Pro2T/TraceValidation/local-ui-gates-recovery-followup`. The committed inventory records hashes, paths and outcomes; the separate noninteractive CI unit-test artifacts are downloadable from their workflow runs.
