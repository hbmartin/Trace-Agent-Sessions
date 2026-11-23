# Navigation coverage and local verification — 2026-11-23

Follow-up to merged PR #101, also correcting the remaining test and historical-evidence findings from #100.

## Frozen candidate

- Implementation/harness: `5235d472894bd9db137d32f9bad16df34f2726c2`; base: `853f19f72a4cf45c63d36d0d835d89714485d161`.
- Native build/test candidate: `2177005106c1d98465212b7dbb4cfd05d149e12a`. The only final difference is `Tests/Scripts/test_background_ui_verification.py`, adding process-readiness handshakes before short fixture watchdogs. Every runtime, Core/App/UI/viewport test, project and configuration input is verified byte-identical. Final script acceptance runs at the final candidate.
- `source-hashes.json` is the canonical 569-file map, checked against committed Git blobs and working bytes. Symlinks/gitlinks and future validation-only files are excluded. Earlier maps and raw attempt receipts remain local.
- Existing vendor modifications, including nested dirty inputs, are recursively verified unchanged.

## Resulting behavior

Coverage follows each adapter/root's actual acceptance independently of the single ingestion winner. Shared failures/incomplete reads cannot become negative evidence for accepting aliases. Directory notifications run discovery; unmatched generic and newer admissions survive an older roster. Only already-qualified removed-source debt can retire through authoritative configuration removal. The custom-adapter regression prevents filename heuristics from overriding a discovered file's failure.

Renderer update, geometry, refinement and scheduled application retire obsolete search restores before priority decisions and allow valid incoming work. Exact deferred/discarded uncommitted reset captures retire while active unsent captures, committed navigation, newer intent and durable reset debt remain protected. Recreated readers can refresh and use Retry.

The local UI runner treats explicit DerivedData as reuse-only, pins the active SDK manifest, separates export stdout/stderr, preserves signals received during timeout cleanup and bounds process-group termination/join. Unconfirmed cleanup aborts the batch. Recursive vendor provenance records missing checkouts instead of falling back to the parent repository. Fixture commits disable ambient signing/hooks; CI policy tests include YAML and broad test invocations.

The terminal-cancellation test now has a selected-session positive read control. Virtual-clock synchronization uses an invocation-owned start gate and one bounded advancement. Required retry-bookkeeping joins unwrap the scheduler; this is defensive test hardening, not a demonstrated nil-scheduler production race. Shared-build interference was a contract risk; prepared-manifest reuse is verified without claiming a previously broken Core/App run.

## Accepted checks

- 723 affected indexing/watcher/sidecar/App/viewport cases: zero failures or skips.
- 11 ownership selectors, five repetitions each: 55 passing executions. Per-selector counts are verified from execution logs; unique XCTest summary counts are not mislabeled as repetitions.
- 114 script cases pass, including real interruption during timeout cleanup, TERM-resistant descendants after leader exit, bounded unreaped cleanup, nested dirty submodules, hostile global Git settings, prepared reuse and YAML-policy negative fixtures.
- Debug build-for-testing, Release app build, external-client compatibility, project drift, Debug/Release signing, network surface and pinned implementation whitespace checks pass.
- Compiled discovery verifies all 31 selected UI identifiers. Real reuse-only UI discovery preserves shared manifests. Exact commands, commits and logs appear in `verification.json`.

## Limitations and retained evidence

UI execution was explicitly waived: **“Skip UI and publish with that limitation.”** No UI case ran on this candidate; compiled discovery does not establish native geometry, focus or desktop restoration acceptance. The 29 prior selectors and two new stale-search/deferred-reader cases remain selected and discoverable.

Comparison-runner lines in script logs are fixture output, not performance measurements.

Performance workloads, full Release comparison pairs and complete native suites are omitted by the selected plan. No local 10% performance-acceptance, timing improvement or physical-footprint claim is made. Standard CI status is a publication-time snapshot, not an assertion of completion.

Failed initial build/script/UI-build attempts remain preserved with their original hashes and diagnostics. Their causes were test-fixture syntax errors, not unrelated application failures. Earlier successful candidates are superseded evidence; adapter acceptance and final script contracts were validated again.

The #100 UI equivalence record now includes accepted revision `74ca740`; its only difference from the recorded final implementation is the App test file. `ci-log-inventory-supplement.json` appends the matching success log's hash without rewriting its original raw inventory. Historical benchmark reports retain their results and annotate workflow retirement.

Raw payloads, XCResults and logs are **local-only**, not downloadable repository or CI attachments. `raw-artifacts.json` gives their provenance and selected file hashes; it is not a whole-XCResult tree digest. Existing ordinary CI diagnostics keep their own workflow retention policy.

No migration, index-format change, public Core signature break or application retry timer. Do not merge automatically.
