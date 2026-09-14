# Performance verification

`TraceBench` never uses the production cache unless that path is explicitly supplied.

```sh
xcodebuild -project Trace.xcodeproj -scheme TraceBench -configuration Release -destination 'platform=macOS,arch=arm64' build
TRACE_BENCH="$(xcodebuild -project Trace.xcodeproj -scheme TraceBench -configuration Release -showBuildSettings | awk '/TARGET_BUILD_DIR/{d=$3}/EXECUTABLE_PATH/{e=$3}END{print d "/" e}')"
"$TRACE_BENCH" index --cold --database "$PWD/build/bench/index.sqlite"
"$TRACE_BENCH" search --database "$PWD/build/bench/index.sqlite" --query the --iterations 100
```

The cold-index run scans the default Claude Code, Codex, and Gemini roots and emits machine-readable JSON. Search mode reports median, p95, p99, and maximum FTS query latency after repeated execution.

Before a release milestone passes, record results for the verified 9.12 GB corpus, a 1.33 MB Gemini record, and a synthetic 4,000-message transcript. Use Instruments and an external display refresh graph to validate:

- warm hotkey frame ≤80 ms;
- end-to-end search p99 ≤200 ms and FTS p99 ≤20 ms;
- visible-row hydration ≤30 ms;
- transcript first paint ≤150 ms;
- source write to committed visibility ≤100 ms;
- no repeatable ProMotion animation hitch;
- idle CPU <0.5% and idle RSS <150 MB.

The checked-in harness makes these measurements reproducible but does not claim a budget passes until the release machine’s result is recorded.

## Search and indexing fixes validation — 2026-09-14

Validated on macOS 15.7.9, Apple silicon, with 22 passing tests (19 core and 3 UI), plus Debug and Release builds. UI attachments cover onboarding scope selection/persistence, the scrollable popover, settings, transcript visibility/density, and failure details on hover.

An isolated mixed-provider corpus contained 12,012 messages, seven sessions, six projects, and five source files. Release `TraceBench` cold indexing took 3,162.7 ms. Over 100 searches for `the` returning 200 results, median database-search latency was 0.694 ms, p95 0.728 ms, and p99 0.777 ms. These are representative synthetic/fixture results, not a new measurement of the full 9.12 GB personal corpus or a ProMotion/idle-memory certification.

A Debug app launch created the isolated index; a separately built, development-signed Release app reopened it from another directory. Database inode, message ID/source-key hash, message count, and all source checkpoints matched exactly. The Release launch reported zero indexed files, five unchanged files, no failures, and completed in 1.07 seconds including app startup.

The benchmark CLI accepts `--sources-directory PATH` with `Claude`, `Codex`, and `Gemini` children for reproducible isolated runs. UI/smoke test sources use the same layout under `TRACE_TEST_DIRECTORY/Sources`.
