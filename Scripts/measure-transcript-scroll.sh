#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
timestamp="$(date +%Y%m%d-%H%M%S)"
output_dir="${TRACE_SCROLL_BENCHMARK_OUTPUT_DIR:-$repo_dir/build/transcript-scroll/$timestamp}"
if [[ "$output_dir" != /* ]]; then output_dir="$PWD/$output_dir"; fi
result_bundle="$output_dir/TranscriptScroll.xcresult"
derived_data="${TRACE_SCROLL_DERIVED_DATA_PATH:-$repo_dir/build/transcript-scroll-derived-data}"
if [[ "$derived_data" != /* ]]; then derived_data="$PWD/$derived_data"; fi

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
  -only-testing:TracePerformanceTests/TracePerformanceTests/testExternalSidecarTrafficPerformance \
  -resultBundlePath "$result_bundle" \
  CODE_SIGNING_ALLOWED=NO \
  >"$output_dir/xcodebuild.log" 2>&1 || test_status=$?

export_status=0
if [[ -d "$result_bundle" ]]; then
  xcrun xcresulttool get test-results summary --path "$result_bundle" \
    >"$output_dir/summary.json" || export_status=$?
  xcrun xcresulttool get test-results metrics --path "$result_bundle" \
    >"$output_dir/metrics.json" || export_status=$?
  xcrun xcresulttool export attachments --path "$result_bundle" --output-path "$output_dir/attachments" \
    >"$output_dir/attachment-export.log" 2>&1 || export_status=$?
else
  export_status=1
  echo "Missing benchmark result bundle: $result_bundle" >&2
fi
if [[ "$test_status" == 0 ]]; then
  [[ "$export_status" == 0 ]] || exit "$export_status"
  python3 "$repo_dir/Scripts/export-benchmark-samples.py" "$output_dir/attachments" "$output_dir/app-samples.json"
  python3 "$repo_dir/Scripts/compare-transcript-scroll-metrics.py" "$output_dir/metrics.json" "$output_dir/metrics.json" > "$output_dir/validation.txt"
fi

printf 'Transcript scrolling benchmark: %s\n' "$output_dir"
exit "$test_status"
