# Verification routing

UI tests run locally on the current physical desktop. Do not execute
TraceUITests or interactive TracePerformanceTests on CI, in a VM, or in UTM.
CI runs builds, noninteractive Core/App tests, script checks and CLI fixtures.

Prepare builds and compiled discovery in the background. After preparation,
obtain one fresh desktop-idle confirmation for the complete selected UI batch.
Keep the Mac unlocked and input-free, wait for competing native checks, and run
UI cases serially through Scripts/run-selected-ui-verification.py. Preserve
failures, exact selectors and per-case results; missing or skipped tests fail
verification. Use no additional macOS account or virtual-machine setup.

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
sessions serial. Always approve disk-access and other macOS permission dialogs
needed for repository validation.

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
