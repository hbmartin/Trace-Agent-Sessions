# Transcript scrolling and streaming measurements, 2026-10-05

The captured main baseline is `115d9fa905d6f19fbff4e01c2786f43f2d74ac67`. Baseline harness commit `5bff37720c974a4b5953bf29b9260bf77fac1e51`
adds only test instrumentation; its production scrolling and indexing behavior
is unchanged. The measured candidate is `755db6924f1712edc49b11b9dff4944f09f2ba43`. The
[baseline patch](benchmarks/2026-10-05/baseline-harness.patch),
[harness hashes and toolchain](benchmarks/2026-10-05/harness.json), and
[run manifest](benchmarks/2026-10-05/runs.json) make the comparison reproducible.

Both revisions were benchmarked locally in Release on the same arm64 Mac mini with an Apple
M2 Pro and 32 GiB RAM, macOS 27.0 (26A428), Xcode 27.0 (27A266a), and Swift
6.4 (swiftlang-6.4.0.34.1). CI validation separately uses macOS 15 and Xcode 26.3.
Each pair ran baseline first, then candidate,
with no concurrent Trace build or UI test. No other xcodebuild process was present
at the final pair's start check. An unrelated iOS test runner was idle during
the preceding pair's start checks and had exited by its completion.

`testTranscriptScrollPerformance` generates the existing synthetic 2,000-message workload,
completes an explicit warm-up, and measures five 5,000-point sweeps. Each sweep
moves down and back in 40 steps and waits for an app completion marker.
The measured block does not query the transcript accessibility hierarchy.
`XCTCPUMetric(application: app)` measures Trace, rather than the test runner.
The separate streaming test waits for a rendered message in its 70-message session,
then appends ten per sample,
and asserts that the final position remains pinned within two points of bottom.
Completion-marker polling and the XCTest message-count wait are included in wall time;
audit reads occur afterward. The benchmark test source, scripts, test controls, and completion
checks match in both revisions. Historical harness hashes remain in
[historical-harness.json](benchmarks/2026-10-05/historical-harness.json).

| Metric, median of all five scroll samples | Main baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Trace CPU time | 2.915 s | 1.876 s | 35.7% less |
| Trace CPU instructions | 23.340 G | 19.669 G | 15.7% less |
| Trace CPU cycles | 9.480 G | 6.125 G | 35.4% less |
| Wall time | 3.046 s | 2.121 s | 30.4% less |

Scroll CPU time samples in seconds, in measurement order:

- Baseline: `2.722148, 2.881694, 3.008903, 3.282299, 2.915396`.
- Candidate: `1.875880, 1.874540, 1.838674, 3.319037, 1.989663`.

The fourth candidate CPU sample is 3.319 seconds, versus 1.839–1.990 for its
other four and 3.282 for the corresponding baseline sweep. Its retired
instructions also rise to 35.820 G from 19.130–20.458 G, indicating extra app
work rather than just completion polling. Earlier pairs also contain slower
candidate samples; inspection and repeated measurements have not isolated a
single cause. The median does not describe every sweep. Every sample is retained. These are
measurements of this corpus on one machine, rather than a general performance guarantee.
Raw exports preserve CPU, instructions, cycles, wall time, and any signpost metrics:
[baseline](benchmarks/2026-10-05/baseline-ci-final-metrics.json) and
[candidate](benchmarks/2026-10-05/candidate-ci-final-metrics.json).
The export reports instructions in `kI` and cycles in `kC`; the table converts
these to billions, rather than the incorrect millions used in the historical report.

Streaming CPU time samples in seconds:

- Baseline: `0.344399, 0.341493, 0.340955`; median `0.341493`.
- Candidate: `0.356685, 0.346710, 0.340167`; median `0.346710`.

The final streaming median is 1.5% higher.
A separate sequential streaming-only confirmation on the preceding scrolling
implementation measured baseline `0.339420` versus candidate
`0.349707` seconds (3.0%
more CPU time). Its samples are retained in the run manifest.
The final bottom-position checks pass. Streaming changes sign between
comparisons: an earlier full pair measured 2.7% more CPU, the confirmation
measured 3.0% more, and the preceding publication pair measured 8.0% less. The
final pair above uses the updated loading precondition and production fixes. There is no
repeatable streaming performance improvement claim. The raw samples disclose
this variation alongside the position and resize correctness fixes.

The first candidate comparison measured a scrolling CPU median of 4.661 seconds
against 3.123 seconds for main, a 49.2% regression. Inspection found repeated
anchor-row height invalidation on every restoration retry. Commit `8a80280`
measures the anchor once and retries measurement only when a temporary estimate
would hide that row. The final candidate also refreshes disclosure anchors
on interaction retries while keeping passive restores cached. Focused density, external-motion, navigation, slow-scroll,
streaming, and resize checks passed after that change. The preceding publication pair included a 3.474-second candidate CPU sample
against four samples between 1.808 and 1.935 seconds. No single cause was isolated;
that outlier is retained. The preceding review pair also had two slower
candidate samples (2.928 and 2.701 seconds against 1.853–1.882 for its first three);
the final pair above repeats the measurement after the CI fixes.
All earlier comparison
samples remain in the run manifest; none were dropped from a reported median.

Run `Scripts/measure-transcript-scroll.sh` for the complete pair of tests and
`Scripts/compare-transcript-scroll-metrics.py baseline/metrics.json candidate/metrics.json`
for a median comparison. Use `--test 'testStreamingTranscriptFollowPerformance()'`
for streaming. Test failures are propagated by the measurement script.
