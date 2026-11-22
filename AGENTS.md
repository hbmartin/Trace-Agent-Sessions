# Verification routing

Run selected native UI tests on the independent GitHub-hosted Mac through
`.github/workflows/background-ui-verification.yml` and
`Scripts/run-selected-ui-verification.py` by default. See
`docs/background-verification.md` for exact-selector execution and artifacts.
A failed unit-test job must not prevent selected UI verification.

Hosted UI execution does not need the user's local desktop to be idle. A
separately provisioned macOS guest with its own logged-in graphical session
is also suitable for functional UI checks after a successful smoke run.
Do not treat a background shell, another Space, or another monitor in the
same login as independent input/focus isolation. Use the working desktop only
as an explicit fallback, preserving the current permission-dialog policy.

Builds and noninteractive checks can run in the background. Physical-Mac
performance acceptance still requires the quiet-host protocol below; hosted
or shared-host VM measurements remain report-only. Do not request local
window minimization for work actually running on an independent remote Mac.

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
