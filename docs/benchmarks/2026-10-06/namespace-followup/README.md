Implementation is committed locally through `900901b`. Acceptance is incomplete:
the 86-test UI suite, five repetitions of affected UI races, and three local
Release pairs have not run. No final CPU, clock, update-timing, or memory samples
exist for this candidate. These follow-up commits had not been pushed when this
verification snapshot was recorded. PR #37 has since been confirmed merged;
the follow-up changes are being published in a separate ready pull request at
the user's request, with UI and performance acceptance still pending.

The final core suite passes all 205 tests. The affected core race selection passes
135 executions across five repetitions; the home-recreation case additionally
passes ten repetitions. All 14 script tests, project drift, signing settings,
and source/binary network checks pass. Debug UI tests compile. Both the candidate
and instrumented `61c00de` baseline build for Release testing. The baseline's
recursive dependency revisions and configured SQLite inputs validate; candidate
and baseline build-input hashes and toolchain details are included here.

The archive retains two development failures. An empty watcher's deinitializer
initially queued a closure retaining itself; moving the empty-stream guard ahead
of scheduling fixed the crash. The first home-recreation test could advance on a
delayed deletion callback and write before its target stream was installed. The
test now waits for the installed content-stream topology rather than a fixed
200 ms sleep. Its ten-repeat run and the full five-repeat race selection pass.
Device identifiers and local home/worktree paths have been removed from the
summaries. Raw xcresult bundles remain under the ignored `build/` directory.

The implementation separates recursive metadata/content streams from
nonrecursive namespace descriptor monitors, coalesces topology checks, retries
failed monitors, rechecks startup snapshots, and drains teardown on utility
queues. Monitoring warnings appear in index-status details and preserve other
startup errors. Deferred rename tracking uses source-path/external-session keys.
Sidebar materialization waits for a target row, and interruption uses the full
Projects scroll bounds. The gated sidebar clock pauses during preparation; a
separate virtual-clock case exercises the unchanged three-second native deadline.
The onboarding test gates the actual metadata startup return to exercise the
generation check after its await. These new UI cases are compiled but unexecuted.

The comparison harness allocates a new run directory, accepts annotated baseline
references, and validates project, configuration, production, and recursive
dependency inputs. Its tests cover occupied outputs, fresh reruns, exact SQLite
patch/generated-file allowances, input drift, incomplete metrics, build failures,
signed memory growth, and the local threshold. Hardware counter availability is
reported separately for each revision. Ordinary comparisons remain report-only
for performance changes; CI still fails invalid measurements and build failures.
The local 10% policy and runner commands are in the repository's `AGENTS.md`.

The local Mac still has an active SecurityAgent process, and clearance of the
protected dialog has not been verified. Other xcodebuild/UI sessions were also
observed during preparation. No protected UI restriction was bypassed. The user
must clear that dialog and competing sessions before UI execution or measurement.
This is recorded as a blocker, not a successful performance check.

After clearance, repeat affected UI races five times and run the entire UI target
without exclusions. Freeze the final code revision and run
`python3 Scripts/run-local-benchmark-comparisons.py`. It performs baseline-first,
candidate-first, baseline-first pairs with five scrolling, three streaming, and
five watcher iterations. Each watcher iteration retains 10,000 unrelated changes,
100 target updates, and 50 retargets. The runner preserves failed or contaminated
attempts and requires complete CPU, clock, timing, signed XCTest growth, and
50 ms physical-footprint records before evaluating the local 10% gate. Individual
samples, paired/aggregate medians, bytes/MiB, update nanoseconds, toolchain, hashes,
and signed retained drift must be published after validation. A failing frozen
candidate must be profiled, fixed, and compared in three new pairs.

The older checkout, unrelated GRDB changes, `nativeMenu`, and historical exports
and patches are preserved. The adjacent `review-followup/` archive contains the
earlier failing CI evidence and profiling observations; those measurements are
not combined with future local results.
