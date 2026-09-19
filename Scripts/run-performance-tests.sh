#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
timestamp="$(date +%Y%m%d-%H%M%S)"
output_dir="${TRACE_PERFORMANCE_OUTPUT_DIR:-$repo_dir/build/performance/$timestamp}"
fixture_dir="$output_dir/fixture"
database="$output_dir/index.sqlite"
result_bundle="$output_dir/TracePerformance.xcresult"

mkdir -p "$output_dir"
cd "$repo_dir"

xcodebuild build \
  -project Trace.xcodeproj \
  -scheme TraceBench \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  >"$output_dir/tracebench-build.log"

products_dir="$(xcodebuild -project Trace.xcodeproj -scheme TraceBench -configuration Release -showBuildSettings | awk '/TARGET_BUILD_DIR =/{print $3; exit}')"
bench="$products_dir/TraceBench"

"$bench" generate --sources-directory "$fixture_dir" --sessions 100 --messages 100 \
  >"$output_dir/corpus.json"
"$bench" index --cold --sources-directory "$fixture_dir" --database "$database" \
  >"$output_dir/index.json"
"$bench" search-suite --database "$database" --iterations 50 --warmup 5 \
  >"$output_dir/search.json"

xcodebuild test \
  -project Trace.xcodeproj \
  -scheme TracePerformance \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath "$result_bundle" \
  >"$output_dir/ui-performance.log"

printf 'Performance artifacts: %s\n' "$output_dir"
