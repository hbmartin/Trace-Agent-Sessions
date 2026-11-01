# Checkpoint order and durable navigation validation

Follow-up to merged [PR #81](https://github.com/hbmartin/Trace-Agent-Sessions/pull/81).
Implementation candidate: `e795963b970b80d0ed38dbf11dcbcd9df1e87813`. Base: `5b3668ac35f93cc159f23bede659016ffefbbf79`.

## Result

- 430 focused Core/App tests passed.
- 56 ownership, navigation, and checkpoint cases passed five consecutive runs: 280 additional test executions.
- Debug and Release app builds, external-client compatibility, project drift, signing, network-surface, 53 script tests, and whitespace checks passed against the frozen source hashes.
- The UI target compiled, including chained rename/relaunch restoration and latest-scroll-during-reset coverage. The selected 24 UI cases have not executed; desktop-idle confirmation remains pending at publication.
- The targeted optimized event-burst harness and baseline/candidate executables compiled. Workload execution is pending; no timing, memory, or performance result is claimed.
- Complete suites and the three Release comparison pairs were omitted as selected. The repository's local 10% performance rule was not evaluated.

[Verification results](verification.json), [focused selection](focused-selectors.json), [repeated cases](race-selectors.json), [compiled UI selection](compiled-ui-selectors.json), and [source hashes](source-hashes.json) identify the validated inputs. Documentation-only commits may follow the implementation candidate without changing its source inputs.

The compiled UI selector list was corrected in the follow-up to use the actual
`testPendingLaunchRestorationResumesWithoutUserIntent` method. The original unrun
raw selection remains retained with the original validation artifacts.

## Changes exercised

A database-owned checkpoint ledger reserves work before asynchronous capture or buffering and survives scheduler replacement. Watermark ordering fences newer completion behind unfinished older inputs; accepted prefixes can advance despite later pending work. Stream epochs qualify wrap recovery and reject obsolete callbacks. Transactional persistence compares the unsigned watermark range and never regresses within an epoch. Coalesced watermark-only tails retain bounded storage; execution leases and revisions prevent older workers from accepting newer input. Scheduler stop retains shared obligations through worker completion and cannot enroll a new retry after stopping.

Schema version 19 adds durable move aliases and checkpoint epochs. Index format 7 and row-ID allocation remain unchanged. Committed moves bind a prior source locator to the same source row and content generation. Alias resolution and expected-reference validation occur inside the same SQL snapshot, survive reopening, and reject content replacement, deletion, reset, and unrelated sources with the same external ID. Existing historical move proof cannot be reconstructed by the migration.

Message anchor keys and external IDs are preserved as a pair. Bookmark recovery keys session identity independently of the anchor and honors the latest user revision, including explicit clears. Accepted moved-session metadata refreshes cached navigation references. Closed selections cannot seed pending restoration with another session's reference.

The startup envelope is owned by the newly installed database before notification. Delivery is tracked separately from current watcher settlement, preserving undelivered obligations while avoiding replay of work already accepted by the same scheduler. External-client compilation covers the additive checkpoint reservation and navigation APIs; existing request signatures remain available.

## Retained attempts and limitations

The first focused run failed `testV15ImmediateChecksAllowPreexistingOrphan`: deferred foreign-key validation in the new migration rejected an orphan deliberately tolerated by earlier migrations. The migration now uses immediate checks, preserving that behavior. The unchanged regression and all final selections passed. An intermediate 427-test run passed before three additional Core cases and the final freeze.

[Attempt outcomes](attempts.json) retain the distinction between intermediate and final evidence. [Raw artifact hashes](raw-artifacts.json) identify logs, inputs, compiled workload artifacts, and XCTest bundle trees. The full per-file tree inventory is retained locally. No failed attempt is classified as unrelated or baseline-safe.

Pending UI and optimized-workload execution are validation limitations, not passing results or a waiver of the original checks. No broad-suite or local performance-acceptance claim is made. The ordinary-retry earliest-deadline policy remains unchanged. No monotonic-ID redesign, automatic retry timer, or broader scheduler redesign was introduced.

Raw evidence: `/Volumes/Pro2T/TraceValidation/checkpoint-navigation-durability-followup`.
XCTest bundles: `/Volumes/Pro2T/TraceWorktrees/rebuild-live-updates/build/durability-*.xcresult`.
The primary checkout, unrelated vendor changes, and prior validation artifacts were preserved. No merge was performed.
