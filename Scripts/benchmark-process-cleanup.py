#!/usr/bin/env python3
"""Measure one owned cleanup operation; fixture setup is outside execution timing."""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runner', required=True, type=Path)
    parser.add_argument('--mode', required=True, choices=['live', 'zombie', 'early-exit'])
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('cleanup_runner', args.runner)
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    result = {'mode': args.mode, 'correct': False,
        'cpuDefinition': 'Python process CPU during cleanup only; excludes ps subprocess CPU',
        'elapsedDefinition': 'cleanup call after fixture readiness; setup, teardown, and validation excluded'}
    child = None
    descendant = None
    interrupted_signal = None
    def interrupted(signum, frame):
        nonlocal interrupted_signal
        interrupted_signal = signum
        raise InterruptedError('Interrupted by ' + signal.Signals(signum).name)
    handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with tempfile.TemporaryDirectory(prefix='TraceCleanup-') as temp:
            ready, release = Path(temp)/'ready', Path(temp)/'exit'
            code = '''import os,sys,time
from pathlib import Path
mode=sys.argv[3]
if mode=='early-exit':
 if os.fork()==0:
  pending=Path(sys.argv[1]+'.tmp')
  pending.write_text(str(os.getpid()))
  pending.replace(sys.argv[1])
  time.sleep(60)
 else:
  while not Path(sys.argv[2]).exists():time.sleep(.005)
  os._exit(0)
else:
 pending=Path(sys.argv[1]+'.tmp')
 pending.write_text('ready')
 pending.replace(sys.argv[1])
 if mode=='zombie':os._exit(0)
 time.sleep(60)
'''
            child = subprocess.Popen([sys.executable, '-c', code, str(ready), str(release), args.mode],
                start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            result['processGroupID'] = child.pid
            deadline = time.monotonic()+5
            while not ready.exists() and time.monotonic()<deadline: time.sleep(.005)
            if not ready.exists(): raise TimeoutError('fixture readiness timeout')
            if args.mode=='early-exit':
                descendant = int(ready.read_text())
                release.touch()
            if args.mode in ('early-exit', 'zombie'):
                deadline = time.monotonic()+5
                while time.monotonic()<deadline:
                    members = runner.process_group_members(child.pid)
                    if any(m['pid']==child.pid and m['state'].startswith('Z') for m in members): break
                    time.sleep(.005)
                else: raise TimeoutError('fixture leader exit timeout')
            error = None
            cpu_start, start = time.process_time(), time.perf_counter()
            try: runner.cleanup_child(child)
            except Exception as failure: error = failure
            elapsed, cpu = time.perf_counter()-start, time.process_time()-cpu_start
            result.update(elapsedSeconds=elapsed, pythonProcessCPUSeconds=cpu)
            if error is not None: raise error
            remaining = runner.process_group_members(child.pid)
            result['correct'] = child.returncode is not None and not any(not m['state'].startswith('Z') for m in remaining)
    except Exception as error:
        result['error'] = f'{type(error).__name__}: {error}'
        print(result['error'], file=sys.stderr)
    finally:
        # Preserve the original failure even if controlled-fixture teardown fails.
        pending_signals, cleanup_errors = [], []
        try:
            for sig in handlers: signal.signal(sig, lambda signum, frame: pending_signals.append(signum))
            if descendant is not None:
                try: os.kill(descendant, signal.SIGKILL)
                except ProcessLookupError: pass
                except Exception as error: cleanup_errors.append(f'{type(error).__name__}: {error}')
            if child is not None:
                try:
                    if descendant is None and child.returncode is None:
                        runner.cleanup_child(child)
                    if child.poll() is None: child.kill()
                    child.wait(timeout=2)
                except Exception as error:
                    cleanup_errors.append(f'{type(error).__name__}: {error}')
                    # This is our fixed fixture, not an arbitrary desktop group.
                    # Its original unreaped setsid child still owns this PGID.
                    # A broken injected runner must not defeat fixture teardown.
                    try:
                        if child.returncode is None: os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=2)
                    except ProcessLookupError: pass
                    except Exception as teardown: cleanup_errors.append(f'{type(teardown).__name__}: {teardown}')
        finally:
            for sig, handler in handlers.items(): signal.signal(sig, handler)
        if pending_signals and interrupted_signal is None: interrupted_signal = pending_signals[0]
        if cleanup_errors:
            result.update(correct=False, fixtureCleanupErrors=cleanup_errors)
            print('Fixture cleanup failed: ' + '; '.join(cleanup_errors), file=sys.stderr)
    if interrupted_signal is not None: result['interruptedSignal'] = interrupted_signal
    print(json.dumps(result, sort_keys=True))
    return 128 + interrupted_signal if interrupted_signal is not None else 0 if result['correct'] else 2


if __name__ == '__main__':
    sys.exit(main())
