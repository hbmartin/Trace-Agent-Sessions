# Background UI verification proof

The isolated-Mac route executed two real native UI cases twice, with no use of
the working desktop:

- [Initial proof, 45056134715](https://github.com/hbmartin/Trace-Agent-Sessions/actions/runs/45056134715): two passed, zero failed or skipped.
- [Final runner proof, 45056693562](https://github.com/hbmartin/Trace-Agent-Sessions/actions/runs/45056693562): eight runner-contract checks and two native cases passed. Each XCResult summary reports one executed passing test, zero failures and zero skips.

The cases exercise onboarding/radios/scope persistence/search and session
navigation/scroll restoration/restart. Identifiers were verified against fresh
compiled XCTest discovery. Environment: macOS 15.8.2, Xcode 26.3, Apple Silicon.
Downloadable logs, receipts, summaries and XCResults are attached to each Actions
run for 14 days. Local copies are retained at the path in
[verification.json](verification.json).

The final runner was executed at `7d5b7c266047e6b41de4eb0fbce4da23f1630a32`.
Candidate `bd380af` subsequently pinned the four action implementations to the
exact commit SHAs recorded by that passing run. The runner and selection did
not change. Six source-input hashes are verified against the candidate commit;
this evidence-only documentation is outside that map.

[The runbook](../../background-verification.md) makes the independent workflow
the preferred functional UI route. The older CI's UI step was skipped after
unit failures; the new job has no dependency on unit-test outcomes. Failed,
missing, skipped, zero-test and timed-out selections fail explicitly. Prior
omissions remain historical: the previous 28-case selection was not executed
here. Full suites, VM provisioning, local permission/OS-specific acceptance and
performance acceptance are not claimed.

The two scanner findings about mutable third-party action tags were addressed
by immutable pins, also applied to checkout. The remaining `python:S2083`
log-path alert is invalid for the current dataflow: the filename uses a fixed
phase label or a decimal enumeration index, never selection-file content. Its
root is an explicit CLI output directory that must not already exist. No alert
or review-thread state was changed. This rationale does not claim a green
external security gate.

An intermediate queued runner attempt was cancelled after the clean main rebase;
it is not counted as a passing run. Redundant CI runs created by infrastructure
iterations were cancelled; the current PR check remains separate. No app source,
retry policy, performance threshold or historical verification result changed.
