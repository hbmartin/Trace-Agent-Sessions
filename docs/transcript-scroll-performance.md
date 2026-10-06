# Transcript scrolling and streaming measurements, 2026-10-05

The captured main baseline is `115d9fa905d6f19fbff4e01c2786f43f2d74ac67`. Baseline harness commit `5bff37720c974a4b5953bf29b9260bf77fac1e51`
adds only test instrumentation; its production scrolling and indexing behavior
is unchanged. The measured candidate is `58c87ebcdfc43fe9caaadf80e26db8b5ab622726`. The
[baseline patch](benchmarks/2026-10-05/baseline-harness.patch),
[harness hashes and toolchain](benchmarks/2026-10-05/harness.json), and
[run manifest](benchmarks/2026-10-05/runs.json) make the comparison reproducible.

Both revisions were benchmarked locally in Release on the same arm64 Mac mini with an Apple
M2 Pro and 32 GiB RAM, macOS 27.0 (26A428), Xcode 27.0 (27A266a), and Swift
6.4 (swiftlang-6.4.0.34.1). CI validation separately uses macOS 15 and Xcode 26.3.
Each pair ran baseline first, then candidate,
with no concurrent Trace build or UI test. An unrelated iOS test runner was idle
at the recorded start checks and had exited by final completion.

`testTranscriptScrollPerformance` generates the existing synthetic 2,000-message workload,
completes an explicit warm-up, and measures five 5,000-point sweeps. Each sweep
moves down and back in 40 steps and waits for an app completion marker.
The measured block does not query the transcript accessibility hierarchy.
`XCTCPUMetric(application: app)` measures Trace, rather than the test runner.
The separate streaming test waits for a rendered message in its 70-message session,
then appends ten per sample,
and asserts that the final position remains pinned within two points of bottom.
Completion-marker polling and the XCTest message-count wait are included in wall time;
audit reads occur afterward. The test source, scripts, test controls, and completion
checks match in both revisions. Historical harness hashes remain in
[historical-harness.json](benchmarks/2026-10-05/historical-harness.json).

| Metric, median of all five scroll samples | Main baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Trace CPU time | 3.085 s | 1.882 s | 39.0% less |
| Trace CPU instructions | 23.752 G | 19.739 G | 16.9% less |
| Trace CPU cycles | 10.064 G | 6.157 G | 38.8% less |
| Wall time | 3.173 s | 2.102 s | 33.7% less |

Scroll CPU time samples in seconds, in measurement order:

- Baseline: `2.890728, 2.592491, 3.085054, 3.151467, 3.185344`.
- Candidate: `1.881544, 1.873148, 1.853189, 2.928274, 2.700650`.

The fourth and fifth candidate CPU samples are slower than its first three;
the reported median does not describe every sweep. Every sample is retained,
including slower candidate samples. These are
measurements of this corpus on one machine, rather than a general performance guarantee.
Raw exports preserve CPU, instructions, cycles, wall time, and any signpost metrics:
[baseline](benchmarks/2026-10-05/baseline-review-final-metrics.json) and
[candidate](benchmarks/2026-10-05/candidate-review-final-metrics.json).
The export reports instructions in `kI` and cycles in `kC`; the table converts
these to billions, rather than the incorrect millions used in the historical report.

Streaming CPU time samples in seconds:

- Baseline: `0.344287, 0.373085, 0.375405`; median `0.373085`.
- Candidate: `0.343334, 0.346579, 0.360786`; median `0.346579`.

The final streaming median is 7.1% lower.
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
would hide that row. Focused density, external-motion, navigation, slow-scroll,
streaming, and resize checks passed after that change. The preceding publication pair included a 3.474-second candidate CPU sample
against four samples between 1.808 and 1.935 seconds. No single cause was isolated;
that outlier is retained, and the final pair above repeats the measurement after review fixes.
All earlier comparison
samples remain in the run manifest; none were dropped from a reported median.

Run `Scripts/measure-transcript-scroll.sh` for the complete pair of tests and
`Scripts/compare-transcript-scroll-metrics.py baseline/metrics.json candidate/metrics.json`
for a median comparison. Use `--test 'testStreamingTranscriptFollowPerformance()'`
for streaming. Test failures are propagated by the measurement script.
