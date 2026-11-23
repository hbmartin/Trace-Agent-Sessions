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

For the previously skipped selection:

```sh
python3 Scripts/run-selected-ui-verification.py \
  --selection docs/validation/2026-11-22-navigation-source-ownership/selected-ui-tests.json \
  --derived-data build/DerivedData \
  --output /absolute/path/to/a/new/local-ui-attempt
```

Obtain one fresh desktop-idle confirmation for the complete batch. Keep the Mac
unlocked and input-free, wait for competing native checks, and run cases
serially. Follow AGENTS.md's permission-dialog policy. The runner performs real
mouse, keyboard and window-focus actions; a background shell or another Space
cannot make that input independent of the user's desktop.

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
