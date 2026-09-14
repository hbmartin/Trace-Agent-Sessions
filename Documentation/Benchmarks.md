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
