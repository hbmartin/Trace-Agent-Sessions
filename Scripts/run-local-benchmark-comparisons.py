#!/usr/bin/env python3
"""Run three uncontaminated local Release pairs, then apply local acceptance."""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def competitors(root, owned_group=None, owned_derived_data=None):
    records = subprocess.check_output(['ps', '-axo', 'pid=,pgid=,comm='], text=True)
    found = []
    for line in records.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3: continue
        pid, group, command = int(fields[0]), int(fields[1]), fields[2]
        name = Path(command).name
        # macOS may launch the UI runner outside xcodebuild's process group.
        # Only this attempt's fresh build directory establishes ownership then.
        owned = owned_group is not None and (group == owned_group or (
            name == 'TracePerformanceTests-Runner' and owned_derived_data is not None
            and Path(command).resolve().is_relative_to(owned_derived_data.resolve())))
        if name == 'SecurityAgent': found.append({'pid': pid, 'reason': 'protected-macOS-dialog'})
        elif name in ['xctrace', 'Instruments']: found.append({'pid': pid, 'reason': 'profiling-session'})
        elif not owned and (name == 'xcodebuild' or name.endswith('-Runner') or name == 'xctest'):
            found.append({'pid': pid, 'reason': 'other-build-or-test-session'})
    return found


def wait_for_quiet(root):
    quiet_since, last_message = None, 0
    while quiet_since is None or time.monotonic() - quiet_since < 10:
        active = competitors(root)
        if active:
            quiet_since = None
            if time.monotonic() - last_message >= 30:
                print('Waiting for quiet desktop: ' + ', '.join(sorted({entry['reason'] for entry in active})), flush=True)
                last_message = time.monotonic()
        elif quiet_since is None: quiet_since = time.monotonic()
        time.sleep(2)


def run(root, output):
    output.mkdir(parents=True, exist_ok=False)
    candidate = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    pairs = []
    for index, order in enumerate(['baseline-first', 'candidate-first', 'baseline-first'], 1):
        attempt = 0
        while True:
            wait_for_quiet(root)
            if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip() != candidate:
                raise SystemExit('Candidate commit changed during measurements')
            subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', '.', ':(exclude)Vendor/GRDB.swift'], cwd=root, check=True)
            attempt += 1
            destination = output / f'pair-{index}-attempt-{attempt}'
            derived_data = destination / 'derived-data'
            environment = dict(os.environ, TRACE_SCROLL_COMPARISON_OUTPUT_DIR=str(destination),
                               TRACE_SCROLL_COMPARISON_ORDER=order,
                               TRACE_SCROLL_COMPARISON_DERIVED_DATA_ROOT=str(derived_data),
                               TRACE_SCROLL_BASELINE_CHECKOUT=str(root / 'build/local-release-baseline'))
            log = output / f'pair-{index}-attempt-{attempt}.log'
            print(f'Starting pair {index}, attempt {attempt}: {order}', flush=True)
            observations, samples = [], 0
            started = time.monotonic()
            with log.open('w') as stream:
                process = subprocess.Popen([str(root / 'Scripts/benchmark-transcript-comparison.sh')], cwd=root,
                                           env=environment, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
                while process.poll() is None:
                    active = competitors(root, process.pid, derived_data)
                    samples += 1
                    if active:
                        observations.append({'elapsedSeconds': time.monotonic() - started, 'sessions': active})
                    time.sleep(2)
            runs = list((destination / 'runs').glob('run-*'))
            if len(runs) != 1: raise SystemExit(f'Comparison did not produce one run: {log}')
            directory = runs[0]
            for test_log in directory.glob('*/xcodebuild.log'):
                for line in test_log.read_text().splitlines():
                    if 'Invoking UI interruption monitors' in line and 'from Application' in line and 'me.haroldmartin.Trace' not in line:
                        observations.append({'revision': test_log.parent.name, 'reason': 'foreign-window-interruption'})
            host = {'valid': not observations, 'sampleCount': samples, 'checkIntervalSeconds': 2,
                    'ownedDerivedDataPath': str(derived_data),
                    'quietBeforeStartSeconds': 10, 'elapsedSeconds': time.monotonic() - started,
                    'competingSessionObservations': observations, 'processExitCode': process.returncode}
            (directory / 'host-session-check.json').write_text(json.dumps(host, indent=2) + '\n')
            if observations:
                print(f'Preserved contaminated attempt: {directory}; waiting before retry', flush=True)
                continue
            if process.returncode: raise SystemExit(f'Comparison failed ({process.returncode}); evidence: {directory}')
            pairs.append(directory)
            break
    (output / 'pair-manifest.json').write_text(json.dumps({'candidateCommit': candidate, 'pairs': [str(p) for p in pairs]}, indent=2) + '\n')
    return subprocess.run([sys.executable, str(root / 'Scripts/check-local-benchmark-regressions.py'),
                           *map(str, pairs), '--output', str(output / 'local-acceptance.json')], cwd=root).returncode


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output or root / 'build' / ('local-release-' + time.strftime('%Y%m%d-%H%M%S'))
    raise SystemExit(run(root, output.resolve()))
