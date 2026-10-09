#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
comparison_root="${TRACE_SCROLL_COMPARISON_OUTPUT_DIR:-$repo_dir/build/transcript-comparison}"
comparison_dir="$comparison_root"
if [[ "$comparison_dir" != /* ]]; then comparison_dir="$PWD/$comparison_dir"; fi
baseline_ref="${TRACE_SCROLL_BASELINE_REF:-61c00dec21762408980afe1a476cfcdb3f859437}"
order="${TRACE_SCROLL_COMPARISON_ORDER:-baseline-first}"
[[ "$order" == baseline-first || "$order" == candidate-first ]] || { echo "Invalid revision order" >&2; exit 1; }
baseline_checkout="${TRACE_SCROLL_BASELINE_CHECKOUT:-$comparison_dir/baseline-checkout}"
baseline_commit="$(git -C "$repo_dir" rev-parse "${baseline_ref}^{commit}")"
candidate_commit="${TRACE_SCROLL_CANDIDATE_COMMIT:-$(git -C "$repo_dir" rev-parse HEAD)}"
if [[ "$baseline_checkout" != /* ]]; then baseline_checkout="$PWD/$baseline_checkout"; fi

# A separate clone leaves the caller's working tree and worktree registrations
# untouched. Retain it with the raw results for inspection after the run.
mkdir -p "$comparison_dir"
mkdir -p "$comparison_dir/runs"
comparison_dir="$(mktemp -d "$comparison_dir/runs/run-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
printf 'TRACE_BENCHMARK_RUN_DIRECTORY=%s\n' "$comparison_dir"
python3 "$repo_dir/Scripts/validate-benchmark-baseline.py" "$repo_dir" "$repo_dir" "$candidate_commit" --role candidate >/dev/null
"$repo_dir/Scripts/configure-grdb.sh"
python3 "$repo_dir/Scripts/validate-benchmark-baseline.py" "$repo_dir" "$repo_dir" "$candidate_commit" --role candidate \
  > "$comparison_dir/candidate-initial-build-inputs.json"
python3 "$repo_dir/Scripts/prepare-benchmark-baseline.py" "$repo_dir" "$baseline_checkout" "$baseline_commit" \
  > "$comparison_dir/baseline-cache-validation.json"
# Preparation already synchronizes, initializes, configures, and validates.
cp "$comparison_dir/baseline-cache-validation.json" "$comparison_dir/baseline-build-inputs.json"
cp "$comparison_dir/baseline-cache-validation.json" "$comparison_dir/baseline-prepared-dependencies.json"
python3 - "$comparison_dir" "$repo_dir" <<'PY_HASHES'
import importlib.util, json, pathlib, sys
output, candidate = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('validator', candidate / 'Scripts/validate-benchmark-baseline.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
records = json.loads((output / 'baseline-cache-validation.json').read_text())
validator.require_complete_harness(candidate, records)
(output / 'harness-hashes.json').write_text(json.dumps(records['harness_sha256'], indent=2) + '\n')
PY_HASHES
python3 "$repo_dir/Scripts/validate-benchmark-baseline.py" "$repo_dir" "$repo_dir" "$candidate_commit" --role candidate \
  > "$comparison_dir/candidate-build-inputs.json"
cmp -s "$comparison_dir/candidate-initial-build-inputs.json" "$comparison_dir/candidate-build-inputs.json" || {
  echo "Candidate build inputs changed during comparison preparation" >&2; exit 1;
}

python3 - "$repo_dir" "$baseline_checkout" "$order" "$comparison_dir" "$candidate_commit" "$baseline_commit" <<'PY'
import hashlib, json, pathlib, subprocess, sys
candidate, baseline, output = map(pathlib.Path, [sys.argv[1], sys.argv[2], sys.argv[4]])
order = sys.argv[3]
def command(*args): return subprocess.check_output(args, text=True).strip()
metadata = {
    'candidate_commit': sys.argv[5],
    'baseline_commit': sys.argv[6],
    'locale': 'en_US',
    'instrumentation_overlay': 'Sources/TraceCore/Diagnostics/TracePerformance.swift',
    'toolchain': {
        'macOS': command('sw_vers'), 'xcode': command('xcodebuild', '-version'),
        'swift': command('swift', '--version'), 'architecture': command('uname', '-m'),
        'cpu': command('sysctl', '-n', 'machdep.cpu.brand_string'),
        'memory_bytes': command('sysctl', '-n', 'hw.memsize'),
    },
    'identical_harness_files': json.loads((output / 'harness-hashes.json').read_text()),
    'baseline_build_inputs': json.loads((output / 'baseline-build-inputs.json').read_text()),
    'candidate_build_inputs': json.loads((output / 'candidate-build-inputs.json').read_text()),
    'build_inputs_validated': False,
    'order': ['baseline', 'candidate'] if order == 'baseline-first' else ['candidate', 'baseline'],
}
for name, expected in metadata['identical_harness_files'].items():
    if hashlib.sha256((candidate / name).read_bytes()).hexdigest() != expected:
        raise SystemExit('Synchronized harness differs: ' + name)
(output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
snapshot_inputs() {
  local phase="$1" side checkout commit
  for side in baseline candidate; do
    if [[ "$side" == baseline ]]; then checkout="$baseline_checkout"; commit="$baseline_commit"
    else checkout="$repo_dir"; commit="$candidate_commit"; fi
    python3 "$repo_dir/Scripts/validate-benchmark-baseline.py" "$repo_dir" "$checkout" "$commit" --role "$side" \
      > "$comparison_dir/$side-build-inputs.$phase.json"
    cmp -s "$comparison_dir/$side-build-inputs.json" "$comparison_dir/$side-build-inputs.$phase.json" || {
      echo "$side build inputs changed during measurements ($phase)" >&2; return 1;
    }
  done
}
run_revision() {
  local revision="$1" checkout="$2" measurement_status=0
  snapshot_inputs "before-$revision"
  if [[ -n "${TRACE_SCROLL_COMPARISON_DERIVED_DATA_ROOT:-}" ]]; then
    TRACE_SCROLL_DERIVED_DATA_PATH="$TRACE_SCROLL_COMPARISON_DERIVED_DATA_ROOT/$revision" \
      TRACE_SCROLL_BENCHMARK_OUTPUT_DIR="$comparison_dir/$revision" "$checkout/Scripts/measure-transcript-scroll.sh" || measurement_status=$?
  else
    TRACE_SCROLL_BENCHMARK_OUTPUT_DIR="$comparison_dir/$revision" "$checkout/Scripts/measure-transcript-scroll.sh" || measurement_status=$?
  fi
  snapshot_inputs "after-$revision"
  return "$measurement_status"
}
if [[ "$order" == baseline-first ]]; then
  run_revision baseline "$baseline_checkout"
  run_revision candidate "$repo_dir"
else
  run_revision candidate "$repo_dir"
  run_revision baseline "$baseline_checkout"
fi
snapshot_inputs after
python3 - "$comparison_dir" <<'PY'
import json, pathlib, sys
output = pathlib.Path(sys.argv[1])
path = output / 'metadata.json'
metadata = json.loads(path.read_text())
for side in ['baseline', 'candidate']:
    metadata[side + '_build_inputs_after'] = json.loads((output / (side + '-build-inputs.after.json')).read_text())
metadata['build_inputs_validated'] = True
path.write_text(json.dumps(metadata, indent=2) + '\n')
PY
"$repo_dir/Scripts/compare-transcript-scroll-metrics.py" \
  "$comparison_dir/baseline/metrics.json" "$comparison_dir/candidate/metrics.json" \
  > "$comparison_dir/comparison.txt"
cat "$comparison_dir/comparison.txt"
