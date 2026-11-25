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
    shutdown_read = shutdown_write = None
    interrupted_signal = None
    def interrupted(signum, frame):
        nonlocal interrupted_signal
        interrupted_signal = signum
        raise InterruptedError('Interrupted by ' + signal.Signals(signum).name)
    handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with tempfile.TemporaryDirectory(prefix='TraceCleanup-') as temp:
            ready, release = Path(temp)/'ready', Path(temp)/'exit'
            shutdown_read, shutdown_write = os.pipe()
            code = '''import os,sys,time,select
from pathlib import Path
mode=sys.argv[3]
if mode=='early-exit':
 if os.fork()==0:
  pending=Path(sys.argv[1]+'.tmp')
  pending.write_text(str(os.getpid()))
  pending.replace(sys.argv[1])
  os.read(int(sys.argv[4]),1)
 else:
  while not Path(sys.argv[2]).exists():
   if select.select([int(sys.argv[4])],[],[],.005)[0]:sys.exit(0)
  os._exit(0)
else:
 pending=Path(sys.argv[1]+'.tmp')
 pending.write_text('ready')
 pending.replace(sys.argv[1])
 if mode=='zombie':os._exit(0)
 os.read(int(sys.argv[4]),1)
'''
            child = subprocess.Popen([sys.executable, '-c', code, str(ready), str(release), args.mode, str(shutdown_read)],
                pass_fds=(shutdown_read,), start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.close(shutdown_read); shutdown_read = None
            result['processGroupID'] = child.pid
            deadline = time.monotonic()+5
            while not ready.exists() and time.monotonic()<deadline: time.sleep(.005)
            if not ready.exists(): raise TimeoutError('fixture readiness timeout')
            if args.mode=='early-exit':
                if int(ready.read_text()) <= 0: raise ValueError('Invalid fixture PID')
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
            # The pipe belongs to this invocation, not a reusable numeric PID.
            # EOF also retires a descendant if a deliberately broken runner
            # failed before signaling anything. This is outside execution timing.
            for descriptor in (shutdown_write, shutdown_read):
                if descriptor is not None:
                    try: os.close(descriptor)
                    except Exception as error: cleanup_errors.append(f'{type(error).__name__}: {error}')
            if child is not None:
                try:
                    child.wait(timeout=2)
                    deadline = time.monotonic() + 2
                    while hasattr(runner, 'process_group_members') and any(not member['state'].startswith('Z') for member in runner.process_group_members(child.pid)):
                        if time.monotonic() >= deadline: raise TimeoutError('Controlled fixture did not retire after shutdown')
                        time.sleep(.01)
                except Exception as error:
                    cleanup_errors.append(f'{type(error).__name__}: {error}')
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
