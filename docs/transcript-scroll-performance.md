# Transcript scrolling performance, 2026-09-24

The baseline is commit `98ad06b88bcafc11591b552c803625d285e8dedf` with the
same test-only benchmark driver and performance test as this branch. The
baseline's product behavior is unchanged. Both runs used Release builds on
the same arm64 Mac with macOS 27 and the same generated corpus.

`testTranscriptScrollPerformance` opens a 2,000-message transcript, performs
one warm-up, then measures five 5,000-point scroll sweeps. Each sweep moves
the viewport down and back in 40 steps and waits for app completion. The test
runner triggers the work without querying the transcript's accessibility
hierarchy inside the measured block. `XCTCPUMetric(application: app)` measures
Trace rather than the test runner.

| Metric, median of five | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Trace CPU time | 3.069 s | 1.858 s | 39.5% less |
| Trace CPU instructions | 24.03 M | 19.69 M | 18.1% less |
| Trace CPU cycles | 9.93 M | 6.09 M | 38.6% less |

Trace CPU time by iteration was `58.763, 3.247, 3.069, 2.751, 2.869` seconds
for baseline and `1.784, 1.779, 3.443, 1.946, 1.858` seconds for candidate.
The first baseline pass was an outlier; the other four baseline samples are
above four of five candidate samples. Wall-clock samples had delays from
cross-process request delivery, so CPU time is the primary comparison.

The separate pinned streaming test appends ten messages per iteration after a
70-message starting corpus. Its median wall time was 1.058 s baseline and
1.048 s candidate. Trace CPU time was 0.316 s baseline and 0.328 s candidate.
It passed its bottom-position assertion, but this change does not improve the
streaming CPU measurement.

Run `Scripts/measure-transcript-scroll.sh` for new measurements and
`Scripts/compare-transcript-scroll-metrics.py` to compare exported
`metrics.json` files. Keep the test harness identical across revisions.
