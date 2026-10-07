# Performance verification

Performance regression acceptance runs locally, not in CI. CI comparison jobs
report differences and reject failed builds or missing/invalid measurements;
do not add performance thresholds to CI.

Freeze the candidate commit, then run three Release pairs against `61c00de` on
one quiet local Mac in baseline-first, candidate-first, baseline-first order.
Run `python3 Scripts/run-local-benchmark-comparisons.py`; it retains individual
attempts and calls `Scripts/check-local-benchmark-regressions.py` after three
valid pairs. `Scripts/benchmark-transcript-comparison.sh` stays report-only for
performance differences.
Use synchronized instrumentation and `en_US`. Keep UI tests and profiling
sessions serial. Do not bypass a protected macOS dialog.

The local tolerance is 10%. Compare per-pair medians, then the median of the
three paired changes for CPU, clock, sampled peak footprint, and retained
footprint. For signed XCTest growth, retained growth, and first-to-last retained
drift, compare additional growth with 10% of the baseline median starting
footprint. Preserve negative growth, warm-ups, individual samples, units,
harness/build/dependency hashes, and failed attempts. Do not impose an absolute
memory budget. Missing timing or memory records fail validation.

Use five scrolling, three streaming, and five watcher iterations per revision.
The watcher workload contains 10,000 unrelated changes, 100 target updates, and
50 link-retarget cycles per iteration. Sample physical footprint every 50 ms
with online aggregation and measure retained footprint after two seconds idle.
Keep control handshakes, exports, and profiling outside timed measurements.
