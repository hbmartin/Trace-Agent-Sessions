#!/usr/bin/env bash
set -euo pipefail

trace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scheme=TraceSnapshots
case "${1:-}" in
  "") ;;
  --record) scheme=TraceSnapshotsRecord ;;
  *) echo "Usage: $0 [--record]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [--record]" >&2
  exit 2
fi
cd "$trace_root"
if [[ "$scheme" == TraceSnapshots && ! -f Tests/TraceSnapshotTests/__Snapshots__/environment.json ]]; then
  echo "No visual baselines found. Record and review all eight with $0 --record." >&2
  exit 1
fi
output="$trace_root/build/snapshots"
mkdir -p "$output"
result="$output/$(date -u +%Y%m%dT%H%M%SZ)-$scheme.xcresult"
record_log="$(mktemp)"
trap 'rm -f "$record_log"' EXIT
xcodebuild test \
  -project Trace.xcodeproj -scheme "$scheme" -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath "$result" \
  -parallel-testing-enabled NO | tee "$record_log"
printf 'Visual test results: %s\n' "$result"
if [[ "$scheme" == TraceSnapshotsRecord ]]; then
  # UI runners are sandboxed. Promote their temporary images only after every
  # capture succeeds; assertion failures other than recording remain failures.
  recorded_directories=()
  while IFS= read -r directory; do recorded_directories+=("$directory"); done < <(
    sed -n 's/.*TRACE_SNAPSHOT_RECORDED_DIRECTORY=//p' "$record_log"
  )
  if [[ ${#recorded_directories[@]} -ne 2 ]]; then
    echo "Recording did not produce both appearances; references were not changed." >&2
    exit 1
  fi
  cmp "${recorded_directories[0]}/environment.json" "${recorded_directories[1]}/environment.json"
  for appearance in dark light; do
    for screen in project-browser search-results transcript-view compact-transcript; do
      found=0
      for directory in "${recorded_directories[@]}"; do
        [[ -f "$directory/showcase.$appearance-$screen.png" ]] && found=$((found + 1))
      done
      if [[ $found -ne 1 ]]; then
        echo "Missing or duplicate $appearance $screen capture; references were not changed." >&2
        exit 1
      fi
    done
  done
  references="$trace_root/Tests/TraceSnapshotTests/__Snapshots__"
  mkdir -p "$references"
  for directory in "${recorded_directories[@]}"; do
    cp "$directory"/*.png "$references/"
  done
  cp "${recorded_directories[0]}/environment.json" "$references/environment.json"
  for directory in "${recorded_directories[@]}"; do rm -rf "$directory"; done
  echo "Review all eight PNGs and environment.json, then run the comparison command without --record."
fi
