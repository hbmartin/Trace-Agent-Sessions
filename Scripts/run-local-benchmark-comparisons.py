#!/usr/bin/env python3
"""Run three uncontaminated local Release pairs, then apply local acceptance."""
import argparse
from contextlib import contextmanager
import importlib.util
import json
import math
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


class RunInterrupted(BaseException):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f'Interrupted by signal {signum}')


@contextmanager
def defer_interruptions():
    """Keep bounded cleanup and its evidence indivisible from cancellation."""
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    received = []
    def deferred(signum, frame):
        if not received:
            received.append(signum)
    try:
        for sig in previous:
            signal.signal(sig, deferred)
        yield received
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def process_records():
    records = subprocess.check_output(['ps', '-axo', 'pid=,pgid=,comm='], text=True)
    result = []
    for line in records.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            result.append((int(fields[0]), int(fields[1]), fields[2]))
    return result


def owned_process(group, command, owned_group, derived_data):
    if owned_group is None:
        return False
    if group == owned_group:
        return True
    return (derived_data is not None and Path(command).name in {'Trace', 'TracePerformanceTests-Runner'}
            and Path(command).resolve().is_relative_to(derived_data.resolve()))


def competitors(root, owned_group=None, owned_derived_data=None):
    found = []
    for pid, group, command in process_records():
        name = Path(command).name
        owned = owned_process(group, command, owned_group, owned_derived_data)
        if name == 'SecurityAgent': found.append({'pid': pid, 'reason': 'protected-macOS-dialog'})
        elif name in ['xctrace', 'Instruments']: found.append({'pid': pid, 'reason': 'profiling-session'})
        elif not owned and (name == 'xcodebuild' or name.endswith('-Runner') or name == 'xctest'):
            found.append({'pid': pid, 'reason': 'other-build-or-test-session'})
    return found


def stop_owned_processes(process, derived_data):
    """Recheck ownership at every signal; never signal another attempt's runner."""
    for signum, seconds in [(signal.SIGINT, 10), (signal.SIGTERM, 5), (signal.SIGKILL, 5)]:
        records = process_records()
        group_members = [pid for pid, group, _ in records if group == process.pid]
        detached = [(pid, command) for pid, group, command in records
                    if group != process.pid and owned_process(group, command, process.pid, derived_data)]
        if not group_members and not detached:
            break
        if group_members and any(pid in group_members and group == process.pid
                                 for pid, group, _ in process_records()):
            try: os.killpg(process.pid, signum)
            except ProcessLookupError: pass
        for pid, command in detached:
            # The PID may have exited or been reused between snapshots.
            if any(current_pid == pid and current_command == command
                   and owned_process(group, current_command, process.pid, derived_data)
                   for current_pid, group, current_command in process_records()):
                try: os.kill(pid, signum)
                except ProcessLookupError: pass
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            process.poll()  # Reap the direct child even while detached runners exit.
            if not any(owned_process(group, command, process.pid, derived_data)
                       for _, group, command in process_records()):
                break
            time.sleep(0.1)
    process.wait(timeout=5)
    if any(owned_process(group, command, process.pid, derived_data) for _, group, command in process_records()):
        raise RuntimeError('Owned benchmark processes did not stop')


def wait_for_quiet(root, timeout=300):
    quiet_since, last_message = None, 0
    deadline = time.monotonic() + timeout
    while quiet_since is None or time.monotonic() - quiet_since < 10:
        if time.monotonic() >= deadline:
            raise SystemExit('Quiet-desktop timeout; close competing builds/tests/profilers and retry')
        active = competitors(root)
        if any(entry['reason'] == 'protected-macOS-dialog' for entry in active):
            raise SystemExit('Protected macOS dialog detected; resolve it before restarting the benchmark')
        if active:
            quiet_since = None
            if time.monotonic() - last_message >= 30:
                print('Waiting for quiet desktop: ' + ', '.join(sorted({entry['reason'] for entry in active})), flush=True)
                last_message = time.monotonic()
        elif quiet_since is None: quiet_since = time.monotonic()
        time.sleep(2)


def snapshot(root, candidate):
    spec = importlib.util.spec_from_file_location('benchmark_inputs', Path(__file__).with_name('validate-benchmark-baseline.py'))
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    return validator.validate(root, root, candidate, role='candidate')


def foreign_interruptions(destination):
    observations = []
    for test_log in destination.glob('runs/run-*/*/xcodebuild.log'):
        for line in test_log.read_text(errors='replace').splitlines():
            if ('Invoking UI interruption monitors' in line and 'from Application' in line
                    and 'me.haroldmartin.Trace' not in line):
                observations.append({'revision': test_log.parent.name, 'reason': 'foreign-window-interruption'})
    return observations


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def run(root, output, *, max_attempts=3, quiet_timeout=300, attempt_timeout=3600):
    if max_attempts < 1 or quiet_timeout <= 0 or attempt_timeout <= 0:
        raise ValueError('Benchmark limits must be positive')
    output.mkdir(parents=True, exist_ok=False)
    candidate = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    snapshot(root, candidate)  # Reject drift before applying the recognized dependency configuration.
    subprocess.run([str(root / 'Scripts/configure-grdb.sh')], cwd=root, check=True)
    frozen = snapshot(root, candidate)
    write_json(output / 'candidate-inputs.json', frozen)
    pairs = []
    for index, order in enumerate(['baseline-first', 'candidate-first', 'baseline-first'], 1):
        for attempt in range(1, max_attempts + 1):
            wait_for_quiet(root, quiet_timeout)
            if snapshot(root, candidate) != frozen:
                raise SystemExit('Candidate build inputs changed before measurements')
            destination = output / f'pair-{index}-attempt-{attempt}'
            destination.mkdir()
            write_json(destination / 'candidate-inputs.before.json', frozen)
            derived_data = destination / 'derived-data'
            environment = dict(os.environ, TRACE_SCROLL_COMPARISON_OUTPUT_DIR=str(destination),
                               TRACE_SCROLL_COMPARISON_ORDER=order, TRACE_SCROLL_CANDIDATE_COMMIT=candidate,
                               TRACE_SCROLL_COMPARISON_DERIVED_DATA_ROOT=str(derived_data),
                               TRACE_SCROLL_BASELINE_CHECKOUT=str(root / 'build/local-release-baseline'))
            log = output / f'pair-{index}-attempt-{attempt}.log'
            print(f'Starting pair {index}, attempt {attempt}: {order}', flush=True)
            observations, samples, process, failure = [], 0, None, None
            started = time.monotonic()
            try:
                with log.open('w') as stream:
                    process = subprocess.Popen([str(root / 'Scripts/benchmark-transcript-comparison.sh')], cwd=root,
                                               env=environment, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
                    while process.poll() is None:
                        active = competitors(root, process.pid, derived_data)
                        samples += 1
                        if active:
                            observations.append({'elapsedSeconds': time.monotonic() - started, 'sessions': active})
                        if any(entry['reason'] == 'protected-macOS-dialog' for entry in active):
                            raise SystemExit('Protected macOS dialog detected; resolve it before restarting')
                        foreign = foreign_interruptions(destination)
                        if foreign:
                            observations.extend(foreign)
                            raise SystemExit('Foreign-window interruption detected; resolve the dialog before restarting')
                        if time.monotonic() - started >= attempt_timeout:
                            raise SystemExit('Benchmark attempt timeout')
                        time.sleep(2)
                observations.extend(foreign_interruptions(destination))
                after = snapshot(root, candidate)
                write_json(destination / 'candidate-inputs.after.json', after)
                if after != frozen:
                    raise SystemExit('Candidate build inputs changed during measurements')
            except BaseException as error:
                failure = error
            finally:
                with defer_interruptions() as interruptions:
                    cleanup_failure = None
                    try:
                        if process is not None:
                            stop_owned_processes(process, derived_data)
                    except BaseException as cleanup_error:
                        cleanup_failure = str(cleanup_error)
                        if failure is None: failure = cleanup_error
                        else: print(f'Benchmark cleanup failed: {cleanup_error}', file=sys.stderr, flush=True)
                    finally:
                        runs = list((destination / 'runs').glob('run-*'))
                        directory = runs[0] if len(runs) == 1 else destination
                        host = {'valid': failure is None and not interruptions and not observations and process is not None and process.returncode == 0,
                                'sampleCount': samples, 'checkIntervalSeconds': 2, 'ownedDerivedDataPath': str(derived_data),
                                'quietBeforeStartSeconds': 10, 'elapsedSeconds': time.monotonic() - started,
                                'competingSessionObservations': observations,
                                'processExitCode': process.returncode if process else None,
                                'failure': str(failure) if failure else None,
                                'cleanupFailure': cleanup_failure}
                        first_cancellation = (failure.signum if isinstance(failure, RunInterrupted) else
                                              signal.SIGINT if isinstance(failure, KeyboardInterrupt) else
                                              interruptions[0] if interruptions else None)
                        if first_cancellation is not None:
                            host.update(valid=False, interruptionSignal=first_cancellation)
                        write_json(directory / 'host-session-check.json', host)
                        if interruptions:
                            host.update(valid=False, interruptionSignal=first_cancellation or interruptions[0])
                            write_json(directory / 'host-session-check.json', host)
                    if interruptions and not isinstance(failure, (KeyboardInterrupt, RunInterrupted)):
                        failure = RunInterrupted(interruptions[0])
            if failure is not None:
                if isinstance(failure, (KeyboardInterrupt, RunInterrupted)): raise failure
                raise SystemExit(f'{failure}; evidence: {directory}; log: {log}') from failure
            if process.returncode:
                raise SystemExit(f'Comparison failed ({process.returncode}); evidence: {directory}; log: {log}')
            if len(runs) != 1:
                raise SystemExit(f'Comparison did not produce one run: {log}')
            if any(entry.get('reason') == 'foreign-window-interruption' for entry in observations):
                raise SystemExit(f'Foreign-window interruption detected; resolve the dialog; evidence: {directory}')
            if observations:
                print(f'Preserved contaminated attempt: {directory}', flush=True)
                if attempt == max_attempts:
                    raise SystemExit(f'Contaminated-attempt limit reached for pair {index}; evidence: {directory}')
                continue
            pairs.append(directory)
            break
    if snapshot(root, candidate) != frozen:
        raise SystemExit('Candidate build inputs changed after final pair')
    write_json(output / 'pair-manifest.json', {'candidateCommit': candidate, 'pairs': [str(p) for p in pairs]})
    return subprocess.run([sys.executable, str(root / 'Scripts/check-local-benchmark-regressions.py'),
                           *map(str, pairs), '--candidate-commit', candidate,
                           '--output', str(output / 'local-acceptance.json')], cwd=root).returncode


def positive_seconds(value):
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError('Must be finite and positive')
    return result


def positive_count(value):
    result = int(value)
    if result <= 0: raise argparse.ArgumentTypeError('Must be positive')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--max-attempts', type=positive_count, default=3)
    parser.add_argument('--quiet-timeout-seconds', type=positive_seconds, default=300)
    parser.add_argument('--attempt-timeout-seconds', type=positive_seconds, default=3600)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output or root / 'build' / ('local-release-' + time.strftime('%Y%m%d-%H%M%S'))
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    def interrupted(signum, frame):
        # A second cancellation must not interrupt bounded cleanup.
        for sig in previous: signal.signal(sig, signal.SIG_IGN)
        raise RunInterrupted(signum)
    try:
        for sig in previous: signal.signal(sig, interrupted)
        result = run(root, output.resolve(), max_attempts=args.max_attempts,
                     quiet_timeout=args.quiet_timeout_seconds, attempt_timeout=args.attempt_timeout_seconds)
    except RunInterrupted as error: result = 128 + error.signum
    except KeyboardInterrupt: result = 130
    finally:
        for sig, handler in previous.items(): signal.signal(sig, handler)
    raise SystemExit(result)
