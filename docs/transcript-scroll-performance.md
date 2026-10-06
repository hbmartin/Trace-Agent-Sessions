# Verified transcript scrolling and streaming measurements, 2026-10-05/06

Measured candidate: `0e7b4d272eb0bb56c87a8f9569b6d198b551e01b`. Captured main:
`115d9fa905d6f19fbff4e01c2786f43f2d74ac67` plus only the [test-instrumentation patch](benchmarks/2026-10-05/baseline-harness.patch),
SHA-256 `0dbdf798f1f475de533e0d0a9da926d6e0199b7013f1ab4e376d7391e3d11c6e`. The baseline receives no recovered production fixes.
Its production MainView code matches captured main. The test-only position probe
now lays out the table before reading maximum scroll position, identically on both
revisions. Exact-session selection and content assertions are also shared.
[Metadata](benchmarks/2026-10-05/ci-macos15-probe-layout-metadata.json) records full commits,
toolchain versions, order, and the three identical test/script hashes.

[CI run 37418657433](https://github.com/hbmartin/Trace-Agent-Sessions/actions/runs/37418657433)
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
| Trace CPU time | 54.638926 s | 29.466610 s | 46.1% less |
| Wall time | 54.872467 s | 29.603107 s | 46.1% less |

Samples in measurement order, in seconds:

- Scroll CPU baseline: `55.457744679, 54.259933615, 50.333160378, 71.137878200, 54.638926053`.
- Scroll CPU candidate: `26.120577947, 31.030131803, 27.890444545, 29.874403262, 29.466609554`.
- Scroll wall baseline: `55.796904510, 54.608334108, 50.560892951, 71.745234652, 54.872466973`.
- Scroll wall candidate: `26.212356816, 31.162403584, 27.967387359, 30.049395157, 29.603107041`.
- Streaming CPU baseline: `0.542562922, 0.502044631, 0.516318166`; median `0.516318166`.
- Streaming CPU candidate: `0.577188160, 0.647253962, 0.456576492`; median `0.577188160`.
- Streaming wall baseline: `1.040848755, 1.047747333, 1.042369814`.
- Streaming wall candidate: `1.043901246, 1.035811741, 1.039109412`.

Streaming CPU is 11.8% more and wall
time is 0.3% less. No repeatable
streaming-speed improvement is claimed. Virtual instruction/cycle counters export
zeros, which are unavailable measurements and support no improvement claim.
The streaming CPU median increased by
0.060870 seconds
(11.8%).
Inspection confirmed completed append batches and final bottom position on both
revisions. The recovered production code matches the preceding candidate: only
the test probe's geometry ordering changed, and the start/final probes run outside
the measured streaming interval. The current streaming audit records 46 layout/bottom updates and 20 follow
operations, versus 44/20 for the preceding candidate; both baseline runs record
40/12. Those counts do not isolate the additional CPU cost. Individual streaming
CPU samples overlap; these
exports do not establish the cause of the increase. It remains a recorded regression
in this pair, with no streaming CPU or speed improvement claim. Wall time includes
polling and accessibility waits and changed by
-0.003260 seconds.

The [preceding verified report](transcript-scroll-performance-0e9b3b0.md) retains
three earlier exact-session pairs: scroll CPU medians 60.402384→2.762558 seconds
at 253877f (95.4% less), 66.438959→32.121951 seconds at 54e9a7a (51.7% less),
and 37.482158→1.278245 seconds at 0e9b3b0 (96.6% less). The first two candidates
have identical scrolling code and instrumentation; only project-row reveal changed.
The third fixes density-anchor materialization. Between that third candidate and
this measurement, recovered production code is unchanged; only the test-probe
geometry ordering changed. Candidate scroll medians still vary substantially
between runners. All measured workloads completed, but the exports do not establish
the cause of that variation or a repeatable percentage gain. The current pair is
reported separately; earlier faster samples are not substituted for it.

The current candidate also fixes a density-restoration edge case: an automatic
height estimate can hide a partially clipped anchor, so it is revealed and measured
before restoring its offset. This report uses a fresh comparison after that fix and the shared test-probe
layout correction.
Separate machines and source revisions are not combined or used to attribute a
performance effect to the fix. The improvement claim applies only to this workload
and this pair; cross-run variation limits generalization.

The [manifest](benchmarks/2026-10-05/runs.json) retains all 24 published
run exports, including individual samples, summaries, commits, and hashes. Eight
exports use exact-session/corpus assertions. The preceding 16 exports and their
investigated regressions are in the [historical report](transcript-scroll-performance-historical.md);
they support no final improvement claim. Failed and canceled attempts, raw
xcresults, logs, and completion diagnostics are saved in the recovery records.

`Scripts/benchmark-transcript-comparison.sh` recreates captured main with the
recorded patch, checks identical harness files, records metadata, and measures the
two revisions sequentially. Set `TRACE_SCROLL_COMPARISON_OUTPUT_DIR` to a fresh
directory. The workflow uses read-only permissions and disables checkout credential
persistence.
