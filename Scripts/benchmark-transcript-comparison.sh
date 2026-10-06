#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
comparison_dir="${TRACE_SCROLL_COMPARISON_OUTPUT_DIR:-$repo_dir/build/transcript-comparison}"
if [[ "$comparison_dir" != /* ]]; then comparison_dir="$PWD/$comparison_dir"; fi
baseline_ref="${TRACE_SCROLL_BASELINE_REF:-115d9fa905d6f19fbff4e01c2786f43f2d74ac67}"
harness_patch="$repo_dir/docs/benchmarks/2026-10-05/baseline-harness.patch"
baseline_checkout="$comparison_dir/baseline-checkout"

# A separate clone leaves the caller's working tree and worktree registrations
# untouched. Retain it with the raw results for inspection after the run.
mkdir -p "$comparison_dir"
git clone --quiet --shared --no-checkout "$repo_dir" "$baseline_checkout"
git -C "$baseline_checkout" checkout --quiet --detach "$baseline_ref"
git -C "$baseline_checkout" apply --check "$harness_patch"
git -C "$baseline_checkout" apply "$harness_patch"
git -C "$baseline_checkout" submodule update --init --recursive
"$baseline_checkout/Scripts/configure-grdb.sh"

# Both apps use exactly the same corpus, completion checks, and measurement code.
for file in Tests/TracePerformanceTests/TracePerformanceTests.swift \
    Scripts/measure-transcript-scroll.sh Scripts/compare-transcript-scroll-metrics.py; do
  cmp "$repo_dir/$file" "$baseline_checkout/$file"
done
python3 - "$repo_dir" "$baseline_checkout" "$harness_patch" "$comparison_dir" <<'PY'
import hashlib, json, pathlib, subprocess, sys
candidate, baseline, patch, output = map(pathlib.Path, sys.argv[1:])
def command(*args): return subprocess.check_output(args, text=True).strip()
metadata = {
    'candidate_commit': command('git', '-C', str(candidate), 'rev-parse', 'HEAD'),
    'baseline_commit': command('git', '-C', str(baseline), 'rev-parse', 'HEAD'),
    'baseline_harness_patch_sha256': hashlib.sha256(patch.read_bytes()).hexdigest(),
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
                     'Scripts/compare-transcript-scroll-metrics.py']
    },
    'order': ['baseline', 'candidate'],
}
(output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
TRACE_SCROLL_BENCHMARK_OUTPUT_DIR="$comparison_dir/baseline" \
  "$baseline_checkout/Scripts/measure-transcript-scroll.sh"
TRACE_SCROLL_BENCHMARK_OUTPUT_DIR="$comparison_dir/candidate" \
  "$repo_dir/Scripts/measure-transcript-scroll.sh"
"$repo_dir/Scripts/compare-transcript-scroll-metrics.py" \
  "$comparison_dir/baseline/metrics.json" "$comparison_dir/candidate/metrics.json" \
  > "$comparison_dir/comparison.txt"
cat "$comparison_dir/comparison.txt"
