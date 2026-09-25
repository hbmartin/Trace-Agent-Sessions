#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
timestamp="$(date +%Y%m%d-%H%M%S)"
output_dir="${TRACE_SCROLL_BENCHMARK_OUTPUT_DIR:-$repo_dir/build/transcript-scroll/$timestamp}"
result_bundle="$output_dir/TranscriptScroll.xcresult"
derived_data="${TRACE_SCROLL_DERIVED_DATA_PATH:-$repo_dir/build/transcript-scroll-derived-data}"

mkdir -p "$output_dir"
cd "$repo_dir"

# Keep the same Release test and corpus for before/after runs. CPU metrics in
# this test target Trace.app, while signposts report the app's update intervals.
test_status=0
xcodebuild test \
  -project Trace.xcodeproj \
  -scheme TracePerformance \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  -only-testing:TracePerformanceTests/TracePerformanceTests/testTranscriptScrollPerformance \
  -only-testing:TracePerformanceTests/TracePerformanceTests/testStreamingTranscriptFollowPerformance \
  -resultBundlePath "$result_bundle" \
  CODE_SIGNING_ALLOWED=NO \
  >"$output_dir/xcodebuild.log" 2>&1 || test_status=$?

if [[ -d "$result_bundle" ]]; then
  xcrun xcresulttool get test-results summary --path "$result_bundle" \
    >"$output_dir/summary.json"
  xcrun xcresulttool get test-results metrics --path "$result_bundle" \
    >"$output_dir/metrics.json"
fi

printf 'Transcript scrolling benchmark: %s\n' "$output_dir"
exit "$test_status"
