# Navigation coverage and target recovery

Frozen implementation and measured harness: `3b861a4991864c5a996be51d9e4803d663586ff6`. Base: `92ebbfd290983142bc0b6d8dbdf000e72aca6039` (merged PR #96). Targeted baseline: `9e91cba925975d221fada13acef40eae69a0851a`; full local Release baseline: `61c00de`. Documentation added after the freeze is not an implementation input.

Rebuild and scope-change submissions enroll full-scan navigation work even without file events. Actual qualified source coverage pays older work while newer admissions remain unpaid. Unsent reset work retires with its submission. Absolute coverage keys also preserve the canonical filesystem root `/`; a regression verifies full-scan and path obligations are paid there without introducing `//` keys. Immutable compressed radix indexes replace byte-per-node coverage indexes; prepared admission inputs and off-lock folding keep large observation construction away from the main actor's admission lock.

A genuine current target-lookup failure presents “Could not locate the search target.” and Retry jump while the transcript remains readable. Retry jump coalesces target-only demand without indexing or timers. A legitimate source rewrite reissues the native restore with current source ownership. If an atomic rewrite recreates the session row, stable source identity remaps the reader, bookmark and persistence to its new row without starting a rebuild. New navigation and bookmark changes retain ownership.

Bookmark remapping carries its resolved source reference. Nearest-rank p95 is tested at 1, 20 and 100 observations. Existing numeric-target settlement, stable sorting, schema and index format are unchanged. The documented legacy activity callback may complete once with an empty checkpoint map; qualified callbacks remain checkpoint-only.

## Correctness and compatibility

The affected selection passes 759 cases: 226 indexing, 13 watcher, 64 metadata, 27 sidecar dependency, 4 viewport, and 425 App follow-up cases. Five repetitions of the 109-case ownership selection pass (545 executions). All 22 selected UI cases pass serially, including source-rewrite native ownership and row recreation; compiled discovery contains all selected identifiers. Scripts pass 81 cases. Debug/Release builds, external-client compatibility, project drift, signing, network surface and pinned whitespace checks pass.

Native offsets and persisted bookmarks are −40 points for both same-row and recreated-row rewrites. Per-frame assertions run live; the existing assertion helper consumes its sampling file afterward. Native probe output, restoration receipts and persisted bookmark records are retained.

The isolated `testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData` fails with the same state timeout and cancellation on pinned #96 and the final runtime (one failed test, two assertion issues). It remains outside the passing selection and is an explicit limitation. Complete native suites remain outside scope.

## Measurements

All 28 targeted workloads completed one accepted warm-up and five recorded samples per revision (336 accepted samples: 56 warm-ups and 280 recorded samples). 22 other attempts remain in the manifest and are excluded from the medians. Recorded-sample selection is explicit in `targeted-summary-final.json`; no cleanup reconciliation masks checkpoint correctness.

The 5,000-path short fixture retained 35.33 → 11.11 MiB; the long fixture retained 40.81 → 14.34 MiB. These are measured process physical footprints of isolated coverage-ledger workloads, not whole-app corpus budgets or proof of the analytical 50× estimate.

Median baseline → candidate values follow. CPU is acceptance-thread CPU for checkpoint/acceptance and process workload CPU for other rows. Raw exports retain separate observation/acceptance worker and process CPU metrics, reservation and main-actor latency, peak footprint, signed growth, counts and correctness fields.

| Workload | Inputs | CPU seconds | Elapsed seconds | Retained MiB |
| --- | ---: | ---: | ---: | ---: |
| checkpoint/acceptance | 1,000 | 0.00208 → 0.00210 | 0.00209 → 0.00212 | 7.94 → 7.92 |
| checkpoint/acceptance | 10,000 | 0.02665 → 0.02428 | 0.02706 → 0.02444 | 22.34 → 23.05 |
| checkpoint/backlog | 1,000 | 0.03342 → 0.03374 | 0.03325 → 0.03352 | 8.11 → 8.19 |
| checkpoint/backlog | 10,000 | 0.06605 → 0.06336 | 0.06558 → 0.06396 | 22.11 → 22.08 |
| checkpoint/enqueue | 1,000 | 0.07192 → 0.07110 | 0.07147 → 0.07063 | 4.94 → 4.98 |
| checkpoint/enqueue | 10,000 | 0.70701 → 0.71362 | 0.70193 → 0.70842 | 4.94 → 4.97 |
| ingress/mixed | 1,000 | 0.08144 → 0.06821 | 0.08053 → 0.06740 | 6.16 → 5.92 |
| ingress/mixed | 10,000 | 0.73219 → 0.61952 | 0.72284 → 0.61373 | 23.27 → 22.50 |
| ingress/oversized | 1,000 | 0.04928 → 0.04551 | 0.04977 → 0.04539 | 5.19 → 5.03 |
| ingress/oversized | 10,000 | 0.45137 → 0.40305 | 0.45080 → 0.40264 | 13.50 → 12.88 |
| ingress/plain | 1,000 | 0.08537 → 0.07252 | 0.07515 → 0.07115 | 5.48 → 5.42 |
| ingress/plain | 10,000 | 0.74906 → 0.68400 | 0.64719 → 0.67269 | 17.16 → 16.70 |
| ingress/structural | 1,000 | 0.08276 → 0.07152 | 0.07338 → 0.07025 | 5.77 → 5.75 |
| ingress/structural | 10,000 | 0.74188 → 0.67232 | 0.64274 → 0.66087 | 20.59 → 20.16 |
| navigation/contention-long | 1,000 | 0.09376 → 0.01072 | 0.09253 → 0.01041 | 11.38 → 6.83 |
| navigation/contention-long | 10,000 | 0.95419 → 0.13113 | 0.94424 → 0.12758 | 48.63 → 21.38 |
| navigation/contention-short | 1,000 | 0.02178 → 0.00937 | 0.02067 → 0.00903 | 10.22 → 6.20 |
| navigation/contention-short | 10,000 | 0.22615 → 0.11446 | 0.22023 → 0.11080 | 56.95 → 15.58 |
| navigation/coverage | 1,000 | 0.00753 → 0.00450 | 0.00754 → 0.00450 | 13.05 → 8.91 |
| navigation/coverage | 10,000 | 0.08672 → 0.05022 | 0.08675 → 0.05019 | 37.00 → 26.41 |
| navigation/ledger-long | 1,000 | 0.11587 → 0.00718 | 0.11572 → 0.00717 | 12.52 → 6.97 |
| navigation/ledger-long | 5,000 | 0.61541 → 0.04564 | 0.61513 → 0.04560 | 40.81 → 14.34 |
| navigation/ledger-long | 10,000 | 1.20153 → 0.09294 | 1.20238 → 0.09283 | 58.38 → 23.25 |
| navigation/ledger-short | 1,000 | 0.02627 → 0.00688 | 0.02625 → 0.00692 | 11.00 → 6.39 |
| navigation/ledger-short | 5,000 | 0.13264 → 0.04031 | 0.13254 → 0.04030 | 35.33 → 11.11 |
| navigation/ledger-short | 10,000 | 0.26627 → 0.07688 | 0.26608 → 0.07681 | 65.16 → 16.64 |
| navigation/target | 1,000 | 0.18821 → 0.18456 | 0.18840 → 0.18447 | 6.97 → 6.89 |
| navigation/target | 10,000 | 1.81324 → 1.83235 | 1.80791 → 1.82849 | 7.02 → 6.94 |

Full Release comparison result: **passed**. The three valid pairs against `61c00de` ran baseline-first, candidate-first, baseline-first in `en_US`. The official 10% check reports no regressions. Median paired changes follow; normalized XCTest growth, retained growth and retained drift also pass, with signed values preserved in [local-acceptance.json](local-acceptance.json).

| Workload | CPU | Clock | Sampled peak | Retained |
| --- | ---: | ---: | ---: | ---: |
| scroll | +0.92% | +1.11% | +0.26% | +1.06% |
| streaming | +1.95% | -0.18% | +3.97% | +2.80% |
| watcher | -4.78% | -1.11% | +0.12% | -2.28% |

One completed pair overlapped another native build. It is retained as invalid and excluded; the valid replacement has no competing-session observations. The valid pair paths, build/dependency hashes, individual samples, units and runner command are recorded in [verification.json](verification.json) and the acceptance report.

Both revisions use synchronized CLI measurement code and opt-in instrumentation. Acceptance/observation worker CPU uses same-thread counters; process CPU is reported separately. Mailbox measurements include normalization, reservation and main-actor delivery, with fixtures and timestamp storage released before retained sampling. Mailbox tests validate transfer and unpaid reservation provenance; scheduler workloads separately validate checkpoint results without a cleanup scan. The exact extracted pending-target resolver uses a real database and a coherent 127-row provisional reader; it measures full-snapshot reads and reader publications, excluding AppKit rendering. Coverage/ledger fixtures exercise immutable scopes, prepared admission and observation contention with short and long paths. Physical footprint is measured directly; node counts are not substituted for bytes.

The claimed 50× growth remains an unverified analytical estimate. The measured fixture changes above do not reproduce that ratio. Signed retained growth, warm-ups, individual samples, invalid attempts, units and starting-footprint baselines remain in the recorded evidence.

## Evidence and failed attempts

`source-hashes.json` is one canonical map for the frozen candidate; every entry is verified against its Git blob and checkout bytes. Historical snapshots remain separate and unchanged. Raw payloads are **local-only** and are not downloadable repository or CI artifacts; provenance paths and hashes identify them.

Earlier compile/test failures, the Release-only DEBUG recorder compile failure, diagnostic builds, and interrupted attempts remain preserved. UI diagnosis found pre-reset geometry samples, a fixture whose in-place edit had not indexed its intended target, and a genuine session-row recreation defect. Fixture corrections require atomic replacement, an actually indexed target, and fresh-generation/native receipts. The two rewrite cases initially used accessibility content geometry rather than the native table-row probe; their −40-point assertions were retained and strengthened with persisted native offsets. No assertion tolerance was widened.

The first targeted quiet preflight expired without starting a workload. Timings overlapped by competing native checks are invalidated and retained; interrupted pairs are repeated after quiet recovery. Auxiliary driver correction records remain separate from application failures. No incomplete measurement is called a pass.

The strict full-comparison preflight initially rejected historical untracked triage probes. Their bytes, modes and timestamps were preserved outside the build checkout, with original paths and SHA-256 values in `triage-probe-relocation.json`; only the untracked build-like probes moved. Other triage records, vendor changes and all tracked implementation inputs remain unchanged. The rejected preflight and retry are retained separately.
