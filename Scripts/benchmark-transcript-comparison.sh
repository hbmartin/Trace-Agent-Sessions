#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
comparison_root="${TRACE_SCROLL_COMPARISON_OUTPUT_DIR:-$repo_dir/build/transcript-comparison}"
comparison_dir="$comparison_root"
if [[ "$comparison_dir" != /* ]]; then comparison_dir="$PWD/$comparison_dir"; fi
baseline_ref="${TRACE_SCROLL_BASELINE_REF:-61c00dec21762408980afe1a476cfcdb3f859437}"
harness_files=(Tests/TracePerformanceTests/TracePerformanceTests.swift
  Scripts/measure-transcript-scroll.sh Scripts/compare-transcript-scroll-metrics.py
  Scripts/export-benchmark-samples.py Scripts/synchronize-benchmark-harness.py Scripts/configure-grdb.sh
  Sources/TraceCore/Diagnostics/TracePerformance.swift)
order="${TRACE_SCROLL_COMPARISON_ORDER:-baseline-first}"
[[ "$order" == baseline-first || "$order" == candidate-first ]] || { echo "Invalid revision order" >&2; exit 1; }
baseline_checkout="${TRACE_SCROLL_BASELINE_CHECKOUT:-$comparison_dir/baseline-checkout}"
baseline_commit="$(git -C "$repo_dir" rev-parse "${baseline_ref}^{commit}")"
if [[ "$baseline_checkout" != /* ]]; then baseline_checkout="$PWD/$baseline_checkout"; fi

# A separate clone leaves the caller's working tree and worktree registrations
# untouched. Retain it with the raw results for inspection after the run.
mkdir -p "$comparison_dir"
if [[ -e "$baseline_checkout" ]]; then
  python3 "$repo_dir/Scripts/validate-benchmark-baseline.py" "$repo_dir" "$baseline_checkout" "$baseline_commit" > /dev/null
else
  mkdir -p "$(dirname "$baseline_checkout")"
  git clone --quiet --shared --no-checkout "$repo_dir" "$baseline_checkout"
  git -C "$baseline_checkout" checkout --quiet --detach "$baseline_commit"
fi
mkdir -p "$comparison_dir/runs"
comparison_dir="$(mktemp -d "$comparison_dir/runs/run-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
printf 'TRACE_BENCHMARK_RUN_DIRECTORY=%s\n' "$comparison_dir"
# Overlay the current harness automatically. Only benchmark instrumentation is
# copied into baseline production sources; historical patches remain archived.
python3 "$repo_dir/Scripts/synchronize-benchmark-harness.py" "$repo_dir" "$baseline_checkout" \
  > "$comparison_dir/harness-hashes.json"
git -C "$baseline_checkout" submodule update --init --recursive
"$baseline_checkout/Scripts/configure-grdb.sh"
python3 "$repo_dir/Scripts/validate-benchmark-baseline.py" "$repo_dir" "$baseline_checkout" "$baseline_commit" \
  > "$comparison_dir/baseline-build-inputs.json"
python3 "$repo_dir/Scripts/validate-benchmark-baseline.py" "$repo_dir" "$repo_dir" "$(git -C "$repo_dir" rev-parse HEAD)" \
  > "$comparison_dir/candidate-build-inputs.json"

# Both apps use exactly the same corpus, completion checks, and measurement code.
for file in "${harness_files[@]}"; do
  cmp "$repo_dir/$file" "$baseline_checkout/$file"
done
python3 - "$repo_dir" "$baseline_checkout" "$order" "$comparison_dir" <<'PY'
import hashlib, json, pathlib, subprocess, sys
candidate, baseline, output = map(pathlib.Path, [sys.argv[1], sys.argv[2], sys.argv[4]])
order = sys.argv[3]
def command(*args): return subprocess.check_output(args, text=True).strip()
metadata = {
    'candidate_commit': command('git', '-C', str(candidate), 'rev-parse', 'HEAD'),
    'baseline_commit': command('git', '-C', str(baseline), 'rev-parse', 'HEAD'),
    'locale': 'en_US',
    'instrumentation_overlay': 'Sources/TraceCore/Diagnostics/TracePerformance.swift',
    'toolchain': {
        'macOS': command('sw_vers'), 'xcode': command('xcodebuild', '-version'),
        'swift': command('swift', '--version'), 'architecture': command('uname', '-m'),
        'cpu': command('sysctl', '-n', 'machdep.cpu.brand_string'),
        'memory_bytes': command('sysctl', '-n', 'hw.memsize'),
    },
    'identical_harness_files': {
        name: hashlib.sha256((candidate / name).read_bytes()).hexdigest()
        for name in ['Tests/TracePerformanceTests/TracePerformanceTests.swift',
                     'Scripts/measure-transcript-scroll.sh',
                     'Scripts/compare-transcript-scroll-metrics.py',
                     'Scripts/export-benchmark-samples.py',
                     'Scripts/synchronize-benchmark-harness.py',
                     'Scripts/configure-grdb.sh',
                     'Sources/TraceCore/Diagnostics/TracePerformance.swift']
    },
    'baseline_build_inputs': json.loads((output / 'baseline-build-inputs.json').read_text()),
    'candidate_build_inputs': json.loads((output / 'candidate-build-inputs.json').read_text()),
    'order': ['baseline', 'candidate'] if order == 'baseline-first' else ['candidate', 'baseline'],
}
(output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
run_revision() {
  local revision="$1" checkout="$2"
  TRACE_SCROLL_BENCHMARK_OUTPUT_DIR="$comparison_dir/$revision" "$checkout/Scripts/measure-transcript-scroll.sh"
}
if [[ "$order" == baseline-first ]]; then
  run_revision baseline "$baseline_checkout"
  run_revision candidate "$repo_dir"
else
  run_revision candidate "$repo_dir"
  run_revision baseline "$baseline_checkout"
fi
"$repo_dir/Scripts/compare-transcript-scroll-metrics.py" \
  "$comparison_dir/baseline/metrics.json" "$comparison_dir/candidate/metrics.json" \
  > "$comparison_dir/comparison.txt"
cat "$comparison_dir/comparison.txt"
