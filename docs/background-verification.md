# Local verification without repeated desktop interruptions

Builds, script checks, and noninteractive Core/App tests can run in the
background. Native UI tests run on the current physical Mac, with one exclusive
desktop window after preparation. No VM, UTM, extra account or CI UI execution
is part of this setup.

## Prepare first

Freeze the candidate and preserve its source/toolchain/dependency hashes. Build
the UI target and verify the selected identifiers through compiled XCTest
discovery before requesting desktop time. Reuse that DerivedData directory for
the selected run so compilation is already complete.

Prepare a dedicated Debug build and record its provenance before desktop time:

```sh
python3 Scripts/run-selected-ui-verification.py \
  --selection /absolute/path/within/repo/selected-ui-tests.json \
  --derived-data /absolute/path/to/new/PreparedUI \
  --output /absolute/path/to/new/preparation-attempt --prepare-only
```

Then reuse those products without building or changing their manifests:

```sh
python3 Scripts/run-selected-ui-verification.py \
  --selection /absolute/path/within/repo/selected-ui-tests.json \
  --derived-data /absolute/path/to/PreparedUI \
  --output /absolute/path/to/new/local-ui-attempt
```

Preparation requires a nonexistent DerivedData directory and runs no UI cases.
Existing products without a preparation receipt cannot be adopted retroactively.

Obtain one fresh desktop-idle confirmation for the complete batch. Keep the Mac
unlocked and input-free, wait for competing native checks, and run cases
serially. Follow AGENTS.md's permission-dialog policy. The runner performs real
mouse, keyboard and window-focus actions; a background shell or another Space
cannot make that input independent of the user's desktop.

Keep the normal Debug signing settings for UI products; disabling signing can
prevent XCTest from launching the app before any test assertion executes.

The runner rechecks build/discovery using the prepared products, executes one
exact selector per invocation, and retains logs, command receipts, summaries and
XCResults. Missing selectors, skipped or zero-test runs, failures and timeouts
fail verification. Each attempt uses a new output directory. Preserve failed
attempts; rerun after an identified correction rather than automatically retrying
a failure until it passes.

Raw local UI payloads remain local-only. Commit source hashes, result counts,
provenance paths and limitations as the review evidence. The earlier hosted UI
proofs remain historical evidence; they do not complete a later local selection.

## CI policy

CI retains builds, noninteractive Core/App tests, script checks and CLI fixtures.
It does not launch TraceUITests or interactive TracePerformanceTests. The former
hosted UI and transcript-scroll workflows are retired; their local scripts and
historical results remain available. The selected runner rejects CI environments
before creating an attempt or launching tools.

## Performance policy

This follow-up performs no performance acceptance. The existing quiet-Mac,
paired Release protocol and 10% local rule remain unchanged. Neither background
builds nor an active working desktop establish valid performance measurements.

## Attempt and interruption contracts

Selection paths are repository-relative. Relative output and DerivedData paths
are resolved from the invocation directory. Each new attempt starts its receipt
before setup checks; an unusable output path or CI rejection fails on stderr
without creating an attempt. The outer per-case watchdog is at least 360 seconds
for XCTest's 300-second allowance plus launch/reporting overhead.

Every case is registered before launch. Export/schema failures retain that case
and continue the selection; interruption stops the batch, terminates and joins
the active process group, and records the signal. Export logs retain errors;
summary files contain JSON only. No failed, missing, skipped or interrupted case
can count as successful verification.

Receipts include actual tracked input hashes, relevant untracked inputs and
submodule state, including permitted vendor modifications. Inputs are rechecked
at the end; changes reject acceptance even if the selected tests passed.

Explicit `--derived-data` is reuse-only unless `--prepare-only` is supplied.
Preparation binds native/build inputs, recursive vendor inputs, Debug/SDK/arm64,
Xcode toolchain, manifests, binaries, frameworks, resources and symlinks to the
build invocation. Reuse rejects stale or missing provenance, Release products,
missing dependencies, or changed products before launch. Documentation-only
revision differences require exact native-input equivalence and both revisions
remain visible. Product inventories are checked around discovery, every case,
and finalization. Without explicit DerivedData, a private build records the same
provenance. Paths remain invocation-relative.

Summary exports retain stdout and stderr separately. Interruptions received during
timeout cleanup are propagated after bounded TERM/KILL process-group cleanup. Interruption remains the primary result even if cleanup also fails. Any error
that prevents confirming cleanup aborts the batch and records the remaining group; do
not resume desktop work until remaining validation processes are checked. Vendor
provenance recursively hashes initialized submodule inputs and identifies missing
checkouts explicitly.

Finalization failures fail verification and retain terminal diagnostics while always
restoring signal handlers and the invocation directory. Every phase identifies
both stdout and stderr logs; summary parsing uses stdout only.
