# Verified transcript scrolling and streaming measurements, 2026-10-05/06

The measured candidate is `54e9a7a1c64e60284dddf9575662d147e77a6905`. Captured main is
`115d9fa905d6f19fbff4e01c2786f43f2d74ac67`, with only the [test-instrumentation patch](benchmarks/2026-10-05/baseline-harness.patch)
(SHA-256 `4cc8f49a9eed570f25e745ade3d251db22b3dd2f7e1a79868b0b1cb2360f0f12`). Its production implementation receives no recovered fixes.
[Run metadata](benchmarks/2026-10-05/ci-macos15-exact-sessions-final-metadata.json) records both commits and
identical test/script hashes. The baseline's MainView instrumentation is unchanged
from the original instrumentation-only baseline; only its test session selection was strengthened.

[CI run 37412715604](https://github.com/hbmartin/Trace-Agent-Sessions/actions/runs/37412715604) runs
baseline first, then candidate, sequentially on one `Apple M1 (Virtual)` runner with
7 GiB RAM. Toolchain: ProductName:		macOS; ProductVersion:		15.7.9; BuildVersion:		24G830; Xcode 26.3; Build version 17C529; Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2); Target: arm64-apple-macosx15.0.
No other Trace build or UI suite runs on that machine during the pair.

Both revisions explicitly select the exact session, verify its loaded message prefix,
and verify the **2,000-message** scroll transcript before warm-up and five 5,000-point
scroll sweeps. Each uses the existing synthetic corpus and the same instrumentation.
Both scrolling and streaming tests pass on both revisions, including completion,
pinned-start, and final-bottom assertions. `XCTCPUMetric(application: app)` measures
Trace CPU time. Scroll measurement uses notifications and completion polling; the
streaming wall time also includes file-marker polling and accessibility message-count waits.
Session selection and initial-content checks occur before measurement.

| Median of five scroll samples | Main baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Trace CPU time | 66.438959 s | 32.121951 s | 51.7% less |
| Wall time | 66.951683 s | 32.262029 s | 51.8% less |

Scroll CPU samples in measurement order, in seconds:

- Baseline: `62.306407721, 66.438959302, 65.572529754, 79.679870967, 89.362271600`.
- Candidate: `32.121951143, 26.098414823, 33.483905010, 30.981824168, 33.793122541`.

Streaming CPU samples in seconds:

- Baseline: `0.832006235, 0.980386301, 0.821525282`; median `0.832006235`.
- Candidate: `0.715804445, 0.754981011, 0.720953512`; median `0.720953512`.

Streaming CPU is 13.3% less; wall time is
0.8% less. No repeatable streaming-speed
improvement is claimed. Instruction and cycle counters exported as zero on virtual
runners are unavailable measurements and are excluded from improvement claims.

The preceding verified pair at `253877f` measured scroll CPU medians
`60.402384` and `2.762558` seconds
(95.4% less). It uses the same exact-session
harness on its own runner. The intervening fix corrects project reveal; differences
between separate virtual machines are not attributed to that change or combined.

The candidate median varies substantially between these two verified pairs
(`2.762558` versus `32.121951` seconds).
Inspection confirmed identical scrolling implementation and benchmark instrumentation
between the candidates; their only source difference is native project-row reveal.
Both test logs complete without failures, and every final candidate scroll sample is
below every final baseline sample. The exports do not establish the cause of the
cross-run variation. No performance effect is attributed to the project-row change;
the final claim uses this pair's 51.7% less CPU result,
with the larger preceding gain retained as a separate observation.

The [run manifest](benchmarks/2026-10-05/runs.json) retains all 20 published
run exports, including individual samples, summary results, source commits, and file
hashes. Earlier timing and investigated regressions are in the
[historical report](transcript-scroll-performance-historical.md), with their original
harness patch preserved separately. Failed/canceled attempts are retained with their
diagnostics in the worktree recovery records; incomplete runs support no performance claim.

`Scripts/benchmark-transcript-comparison.sh` recreates captured main with the recorded
patch, verifies identical harness files, records toolchain metadata, and runs the two
revisions sequentially. Set `TRACE_SCROLL_COMPARISON_OUTPUT_DIR` to a fresh directory.
The benchmark workflow runs the same script with read-only permissions and checkout
credential persistence disabled. Raw xcresults, logs, and metrics are retained.

The scroll reduction applies to this workload and these runs. Virtual-runner timing,
hardware variation, and the historical slower samples limit generalization.
