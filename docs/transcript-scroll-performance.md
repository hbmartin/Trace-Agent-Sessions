# Verified transcript scrolling and streaming measurements, 2026-10-05/06

Measured candidate: `0e9b3b013317e51ae95ee9a90853e23ea879039e`. Captured main:
`115d9fa905d6f19fbff4e01c2786f43f2d74ac67` plus only the [test-instrumentation patch](benchmarks/2026-10-05/baseline-harness.patch),
SHA-256 `4cc8f49a9eed570f25e745ade3d251db22b3dd2f7e1a79868b0b1cb2360f0f12`. The baseline receives no recovered production fixes.
Its MainView instrumentation is byte-identical to the original instrumentation-only
baseline; only exact-session selection and content assertions were strengthened.
[Metadata](benchmarks/2026-10-05/ci-macos15-anchor-restoration-metadata.json) records full commits,
toolchain versions, order, and the three identical test/script hashes.

[CI run 37416160092](https://github.com/hbmartin/Trace-Agent-Sessions/actions/runs/37416160092)
runs baseline then candidate sequentially on one `Apple M1 (Virtual)` runner with
7 GiB RAM, macOS 15.7.9
(24G830); Xcode 26.3; Build version 17C529; Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2); Target: arm64-apple-macosx15.0. No other Trace build or UI suite runs on that
machine during the pair.

Both revisions select the exact session and verify its loaded content and the
**2,000-message** transcript before warm-up and five 5,000-point scroll sweeps.
The existing corpus and instrumentation are identical. Both scroll and streaming
tests pass on both revisions, including completion, pinned-start, and final-bottom
assertions. `XCTCPUMetric(application: app)` measures Trace CPU. Wall time includes
completion polling; streaming also includes accessibility message-count waits.
Session selection and initial-content assertions occur before measurement.

| Median of five scroll samples | Main baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Trace CPU time | 37.482158 s | 1.278245 s | 96.6% less |
| Wall time | 37.548303 s | 1.706548 s | 95.5% less |

Samples in measurement order, in seconds:

- Scroll CPU baseline: `37.482157852, 36.317397175, 43.787310093, 32.430671262, 47.786125414`.
- Scroll CPU candidate: `1.371475420, 1.246318533, 2.091414674, 1.122412105, 1.278245315`.
- Scroll wall baseline: `37.548302824, 36.382144908, 43.895923439, 32.474439336, 47.905105774`.
- Scroll wall candidate: `1.601111090, 1.706547510, 2.430672946, 1.646703459, 1.707076943`.
- Streaming CPU baseline: `0.504483106, 0.521291384, 0.509812245`; median `0.509812245`.
- Streaming CPU candidate: `0.412395425, 0.358418474, 0.389584870`; median `0.389584870`.
- Streaming wall baseline: `1.037089301, 1.038939467, 1.043147215`.
- Streaming wall candidate: `1.076097152, 1.062148542, 1.070818853`.

Streaming CPU is 23.6% less and wall
time is 3.1% more. No repeatable
streaming-speed improvement is claimed. Virtual instruction/cycle counters export
zeros, which are unavailable measurements and support no improvement claim.
The streaming wall-time increase is
0.031879 seconds.
Inspection confirmed completed append batches and final bottom position, while CPU
time decreased. This end-to-end interval includes polling and accessibility waits;
the exports do not isolate the cause of the small wall-time increase.

The [preceding verified report](transcript-scroll-performance-54e9a7a.md) retains
both earlier exact-session pairs: scroll CPU medians 60.402384→2.762558 seconds
at 253877f (95.4% less), and 66.438959→32.121951 seconds at 54e9a7a (51.7% less).
Inspection found identical scrolling code and instrumentation between those
candidates; only project-row reveal changed. Their logs passed, but the exports
do not establish the cause of the substantial candidate timing variation.

The current candidate also fixes a density-restoration edge case: an automatic
height estimate can hide a partially clipped anchor, so it is revealed and measured
before restoring its offset. This report uses a fresh comparison after that fix.
Separate machines and source revisions are not combined or used to attribute a
performance effect to the fix. The improvement claim applies only to this workload
and this pair; cross-run variation limits generalization.

The [manifest](benchmarks/2026-10-05/runs.json) retains all 22 published
run exports, including individual samples, summaries, commits, and hashes. Six
exports use exact-session/corpus assertions. The preceding 16 exports and their
investigated regressions are in the [historical report](transcript-scroll-performance-historical.md);
they support no final improvement claim. Failed and canceled attempts, raw
xcresults, logs, and completion diagnostics are saved in the recovery records.

`Scripts/benchmark-transcript-comparison.sh` recreates captured main with the
recorded patch, checks identical harness files, records metadata, and measures the
two revisions sequentially. Set `TRACE_SCROLL_COMPARISON_OUTPUT_DIR` to a fresh
directory. The workflow uses read-only permissions and disables checkout credential
persistence.
