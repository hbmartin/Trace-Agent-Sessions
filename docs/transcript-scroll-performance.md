# Transcript scrolling and streaming measurements, 2026-10-05

The captured main baseline is `115d9fa905d6f19fbff4e01c2786f43f2d74ac67`. Baseline harness commit `b31df2aed3e7cf1b658a352870777e8fe56742c2`
adds only test instrumentation; its production scrolling and indexing behavior
is unchanged. The measured candidate is `3034725497d6942fb3d586ae034f834dc038c75c`. The
[baseline patch](benchmarks/2026-10-05/baseline-harness.patch),
[harness hashes and toolchain](benchmarks/2026-10-05/harness.json), and
[run manifest](benchmarks/2026-10-05/runs.json) make the comparison reproducible.

Both revisions used Release builds on the same arm64 Mac mini with an Apple
M2 Pro and 32 GiB RAM, macOS 27.0 (26A428), Xcode 27.0 (27A266a), and Swift
6.4 (swiftlang-6.4.0.34.1). Each pair ran baseline first, then candidate,
without another local build or UI test running during measurement.

`testTranscriptScrollPerformance` opens the existing 2,000-message corpus,
completes an explicit warm-up, and measures five 5,000-point sweeps. Each sweep
moves down and back in 40 steps and waits for an app completion marker.
The measured block does not query the transcript accessibility hierarchy.
`XCTCPUMetric(application: app)` measures Trace, rather than the test runner.
The separate streaming test starts with 70 messages, appends ten per sample,
and asserts that the final position remains pinned within two points of bottom.
The test source, scripts, test controls, and completion checks match in both revisions.

| Metric, median of all five scroll samples | Main baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Trace CPU time | 2.676 s | 1.898 s | 29.1% less |
| Trace CPU instructions | 24.032 G | 19.298 G | 19.7% less |
| Trace CPU cycles | 9.055 G | 6.176 G | 31.8% less |
| Wall time | 2.875 s | 2.141 s | 25.5% less |

Scroll CPU time samples in seconds, in measurement order:

- Baseline: `2.551156, 2.455634, 2.724461, 2.675890, 2.831819`.
- Candidate: `1.807595, 1.871941, 1.898391, 1.934619, 3.474236`.

Every sample is retained, including slower candidate samples. These are
measurements of this corpus on one machine, rather than a general performance guarantee.
Raw exports preserve CPU, instructions, cycles, wall time, and any signpost metrics:
[baseline](benchmarks/2026-10-05/baseline-publication-metrics.json) and
[candidate](benchmarks/2026-10-05/candidate-publication-metrics.json).
The export reports instructions in `kI` and cycles in `kC`; the table converts
these to billions, rather than the incorrect millions used in the historical report.

Streaming CPU time samples in seconds:

- Baseline: `0.384021, 0.369384, 0.354268`; median `0.369384`.
- Candidate: `0.355531, 0.339909, 0.323999`; median `0.339909`.

The publication streaming median is 8.0% lower.
A separate sequential streaming-only confirmation on the preceding scrolling
implementation measured `0.339420` versus
`0.349707` seconds (3.0%
more CPU time). Its samples are retained in the run manifest.
The final bottom-position checks pass. Streaming changes sign between
comparisons: the earlier full pair measured 2.7% more CPU, the confirmation
measured 3.0% more, and the publication pair measured 8.0% less. There is no
repeatable streaming performance improvement claim. The raw samples disclose
this variation alongside the position and resize correctness fixes.

The first candidate comparison measured a scrolling CPU median of 4.661 seconds
against 3.123 seconds for main, a 49.2% regression. Inspection found repeated
anchor-row height invalidation on every restoration retry. Commit `8a80280`
measures the anchor once and retries measurement only when a temporary estimate
would hide that row. Focused density, external-motion, navigation, slow-scroll,
streaming, and resize checks passed after that change. All earlier comparison
samples remain in the run manifest; none were dropped from a reported median.

Run `Scripts/measure-transcript-scroll.sh` for the complete pair of tests and
`Scripts/compare-transcript-scroll-metrics.py baseline/metrics.json candidate/metrics.json`
for a median comparison. Use `--test 'testStreamingTranscriptFollowPerformance()'`
for streaming. Test failures are propagated by the measurement script.
