# Navigation debt and verification provenance follow-up

Follow-up to merged PR #102. Frozen implementation/harness: `11c5d0a6860f14d71b22c6f3b8c8eba9339b8fac`; base:
`339899c7046fa59a0481a122a2d8c77279a0bc23`.

Metadata outside configured transcript roots continues indexing without creating
navigation debt. Incremental and deleted inputs use adapter-owned scoped discovery,
including custom filenames, while failures and source aliases retain their actual
coverage. Height capture and anchor correction retire obsolete search before reading
position. Regression fixtures reproduce production search predecessor retirement.

Prepared UI reuse now requires a Debug build provenance receipt tied to actual
native/dependency inputs, SDK/toolchain and product/resource/manifest hashes.
Cleanup failures abort the batch; interruption, terminal receipt handling and
stderr paths remain explicit. No migration, public Core signature break or new
application retry timer.

## Completed validation

- 726 affected Core/App/viewport cases passed without failures or skips.
- Twelve ownership selectors passed five times each: 60 executions.
- 120 affected script tests passed. Comparison-runner messages in those logs are
  mocked fixtures, not performance measurements.
- Debug/Release builds, external-client compatibility, project drift, signing,
  network surface and pinned whitespace checks passed.
- Compiled discovery found 1041 identifiers and verified every selected UI case.
  A dedicated preparation-only build verified all 33 selectors and unchanged
  binaries/resources/manifests. Preparation ran no UI tests.
- Independent height and correction bypasses, and no-op Reader Retry, produced the
  intended failures. Initial height probes unexpectedly passed; they exposed an
  invalid predecessor in the fixture. The corrected height mutant failed and the
  restored geometry/Retry cases passed five times before final affected acceptance.
- 582 regular tracked source hashes were checked against Git and working bytes.
  Vendor modifications and recursive dependency inputs remain preserved.

Exact commands, candidate hashes, failed attempts and omissions are in
`verification.json`. `source-hashes.json` is the single canonical map for the frozen
implementation; prior snapshots remain in the raw directory. Optimized Core/mailbox
inputs and harness equivalence are recorded separately.

## Explicit limitations

The user selected **“Skip UI and measurements; publish with limitations.”** No UI
case or paired performance sample was executed. Discovery and preparation establish
compile/provenance coverage, not native geometry, focus or desktop acceptance.
Baseline/candidate optimized checkpoint, ingress, coverage/target and admission
workloads compiled; their runtime correctness and measurements remain unverified.
No performance improvement or local 10% acceptance is claimed. Complete suites and
the three full Release comparison pairs remain omitted by the approved plan.

## Raw evidence availability

Raw payloads are local-only at:

`/Volumes/Pro2T/TraceValidation/navigation-debt-provenance-followup`

They are not attached as downloadable repository or CI artifacts. Logs, command
receipts, XCResults, failed negative controls, source exports, compiled workloads
and preparation receipts remain at their provenance paths. `raw-artifacts.json`
inventories selected completed regular files; it does not claim whole-XCResult,
DerivedData or exported-source tree digests. Historical results were preserved.
