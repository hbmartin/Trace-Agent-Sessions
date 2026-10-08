import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import test_transcript_benchmark_scripts as fixtures


class BenchmarkReliabilityTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.TranscriptBenchmarkScriptTests()

    def test_candidate_signing_is_allowed_hashed_and_restricted(self):
        validator = self.fixture.module('validate-benchmark-baseline')
        with tempfile.TemporaryDirectory() as directory:
            candidate, _ = self.fixture.baseline_fixture(Path(directory))
            revision = self.fixture.git(candidate, 'rev-parse', 'HEAD')
            (candidate / '.git/info/exclude').write_text('Config/Signing.xcconfig\n')
            signing = candidate / 'Config/Signing.xcconfig'
            signing.write_text('// Local signing\nDEVELOPMENT_TEAM = ABC123\n')
            before = validator.validate(candidate, candidate, revision, role='candidate')
            self.assertIn('Config/Signing.xcconfig', before['build_input_sha256'])
            signing.write_text('DEVELOPMENT_TEAM = DEF456\n')
            self.assertNotEqual(before, validator.validate(candidate, candidate, revision, role='candidate'))
            signing.write_text('DEVELOPMENT_TEAM = ABC123\nSWIFT_OPTIMIZATION_LEVEL = -Onone\n')
            with self.assertRaisesRegex(ValueError, 'Candidate.*unsupported build setting'):
                validator.validate(candidate, candidate, revision, role='candidate')
            signing.unlink()
            (candidate / 'unknown.swift').write_text('unrecorded build input')
            with self.assertRaisesRegex(ValueError, 'Candidate.*unexpected build input'):
                validator.validate(candidate, candidate, revision, role='candidate')

    def test_missing_submodule_is_initialized_without_repairing_revision_drift(self):
        validator = self.fixture.module('validate-benchmark-baseline')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, baseline = self.fixture.baseline_fixture(root)
            dependency = root / 'dependency'
            dependency.mkdir()
            self.fixture.git(dependency, 'init', '--quiet')
            (dependency / 'file.c').write_text('first')
            self.fixture.git(dependency, 'add', '.')
            self.fixture.git(dependency, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                             'commit', '--quiet', '-m', 'dependency')
            self.fixture.git(candidate, '-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet',
                             str(dependency), 'Vendor/Dependency')
            self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                             'commit', '--quiet', '-am', 'module')
            self.fixture.git(baseline, 'fetch', '--quiet')
            revision = self.fixture.git(candidate, 'rev-parse', 'HEAD')
            self.fixture.git(baseline, 'reset', '--hard', revision)
            with self.assertRaisesRegex(ValueError, 'uninitialized dependency'):
                validator.validate(candidate, baseline, revision)
            with patch.dict(os.environ, GIT_ALLOW_PROTOCOL='file'):
                validator.initialize_missing(candidate, baseline, revision)
            validator.validate(candidate, baseline, revision)
            submodule = baseline / 'Vendor/Dependency'
            (submodule / 'file.c').write_text('different revision')
            self.fixture.git(submodule, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                             'commit', '--quiet', '-am', 'drift')
            drift = self.fixture.git(submodule, 'rev-parse', 'HEAD')
            with self.assertRaisesRegex(ValueError, 'Dependency revision differs'):
                validator.initialize_missing(candidate, baseline, revision)
            self.assertEqual(self.fixture.git(submodule, 'rev-parse', 'HEAD'), drift)

    def test_interrupted_missing_submodule_initialization_can_resume(self):
        validator = self.fixture.module('validate-benchmark-baseline')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, baseline = self.fixture.baseline_fixture(root)
            dependency = root / 'dependency'
            dependency.mkdir()
            self.fixture.git(dependency, 'init', '--quiet')
            (dependency / 'file.c').write_text('first')
            self.fixture.git(dependency, 'add', '.')
            self.fixture.git(dependency, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                             'commit', '--quiet', '-m', 'dependency')
            self.fixture.git(candidate, '-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet',
                             str(dependency), 'Vendor/Dependency')
            self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                             'commit', '--quiet', '-am', 'module')
            self.fixture.git(baseline, 'fetch', '--quiet')
            revision = self.fixture.git(candidate, 'rev-parse', 'HEAD')
            self.fixture.git(baseline, 'reset', '--hard', revision)
            shutil.rmtree(baseline / 'Vendor/Dependency')
            real_run = validator.subprocess.run
            def interrupted(args, **kwargs):
                if 'submodule' in args:
                    raise subprocess.CalledProcessError(130, args)
                return real_run(args, **kwargs)
            with patch.object(validator.subprocess, 'run', side_effect=interrupted):
                with self.assertRaises(subprocess.CalledProcessError):
                    validator.initialize_missing(candidate, baseline, revision)
            with patch.dict(os.environ, GIT_ALLOW_PROTOCOL='file'):
                validator.initialize_missing(candidate, baseline, revision)
            records = validator.validate(candidate, baseline, revision)
            self.assertIn('Vendor/Dependency/', records)

    def test_positive_limits_and_protected_dialog_are_enforced(self):
        runner = self.fixture.module('run-local-benchmark-comparisons')
        for value in ['0', '-1', 'nan', 'inf']:
            with self.assertRaises(Exception): runner.positive_seconds(value)
        for value in ['0', '-1']:
            with self.assertRaises(Exception): runner.positive_count(value)
        with patch.object(runner, 'competitors', return_value=[{'pid': 1, 'reason': 'protected-macOS-dialog'}]):
            with self.assertRaisesRegex(SystemExit, 'Protected macOS dialog'):
                runner.wait_for_quiet(Path('/fixture'))

    def runner_fixture(self, root, body):
        candidate, _ = self.fixture.baseline_fixture(root)
        configure = candidate / 'Scripts/configure-grdb.sh'
        configure.write_text('#!/bin/sh\nexit 0\n')
        configure.chmod(0o755)
        script = candidate / 'Scripts/benchmark-transcript-comparison.sh'
        script.write_text('#!/bin/sh\nset -eu\nmkdir -p "$TRACE_SCROLL_COMPARISON_OUTPUT_DIR/runs/run-fixture"\n' + body)
        script.chmod(0o755)
        self.fixture.git(candidate, 'add', '.')
        self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                         'commit', '--quiet', '-m', 'runner fixture')
        return candidate

    def test_last_pair_commit_and_working_file_changes_are_rejected(self):
        for commit in [False, True]:
            with self.subTest(commit=commit), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                body = ('case "$TRACE_SCROLL_COMPARISON_OUTPUT_DIR" in *pair-3-*)\n'
                        'printf changed > Sources/TraceApp/MainView.swift\n')
                if commit:
                    body += 'git -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -am drift\n'
                body += ';; esac\n'
                candidate = self.runner_fixture(root, body)
                runner = self.fixture.module('run-local-benchmark-comparisons')
                with patch.object(runner, 'wait_for_quiet'), patch.object(runner, 'competitors', return_value=[]):
                    with self.assertRaisesRegex(SystemExit, '(different revision|unexpected build input)'):
                        runner.run(candidate, root / 'results')
                host = json.loads((root / 'results/pair-3-attempt-1/runs/run-fixture/host-session-check.json').read_text())
                self.assertFalse(host['valid'])
                self.assertFalse((root / 'results/pair-manifest.json').exists())
                self.assertFalse((root / 'results/local-acceptance.json').exists())

    def test_failed_contaminated_attempt_stops_without_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = self.runner_fixture(root, 'sleep 0.2\nexit 23\n')
            runner = self.fixture.module('run-local-benchmark-comparisons')
            with patch.object(runner, 'wait_for_quiet'), patch.object(runner, 'competitors',
                    return_value=[{'pid': 1, 'reason': 'profiling-session'}]):
                with self.assertRaisesRegex(SystemExit, 'Comparison failed \\(23\\)'):
                    runner.run(candidate, root / 'results')
            self.assertFalse((root / 'results/pair-1-attempt-2').exists())
            host = json.loads((root / 'results/pair-1-attempt-1/runs/run-fixture/host-session-check.json').read_text())
            self.assertFalse(host['valid'])
            self.assertTrue(host['competingSessionObservations'])

    def test_successful_contaminated_attempts_stop_at_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = self.runner_fixture(root, 'sleep 0.1\n')
            runner = self.fixture.module('run-local-benchmark-comparisons')
            with patch.object(runner, 'wait_for_quiet'), patch.object(runner, 'competitors',
                    return_value=[{'pid': 1, 'reason': 'profiling-session'}]):
                with self.assertRaisesRegex(SystemExit, 'Contaminated-attempt limit'):
                    runner.run(candidate, root / 'results', max_attempts=2)
            self.assertEqual(len([p for p in (root / 'results').glob('pair-*-attempt-*') if p.is_dir()]), 2)

    def test_foreign_dialog_stops_and_preserves_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = self.runner_fixture(root,
                'mkdir -p "$TRACE_SCROLL_COMPARISON_OUTPUT_DIR/runs/run-fixture/candidate"\n'
                'printf "Invoking UI interruption monitors from Application com.apple.dt.mcp-server\\n" '
                '> "$TRACE_SCROLL_COMPARISON_OUTPUT_DIR/runs/run-fixture/candidate/xcodebuild.log"\n')
            runner = self.fixture.module('run-local-benchmark-comparisons')
            with patch.object(runner, 'wait_for_quiet'), patch.object(runner, 'competitors', return_value=[]):
                with self.assertRaisesRegex(SystemExit, 'Foreign-window interruption'):
                    runner.run(candidate, root / 'results')
            self.assertFalse((root / 'results/pair-1-attempt-2').exists())
            self.assertTrue((root / 'results/pair-1-attempt-1/runs/run-fixture/host-session-check.json').exists())

    def test_interrupt_and_termination_cleanup_owned_processes(self):
        runner = self.fixture.module('run-local-benchmark-comparisons')
        for interruption in [KeyboardInterrupt(), runner.RunInterrupted(signal.SIGINT), runner.RunInterrupted(signal.SIGTERM)]:
            with self.subTest(interruption=type(interruption)), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                candidate = self.runner_fixture(root, 'sleep 60\n')
                with patch.object(runner, 'wait_for_quiet'), patch.object(runner, 'competitors', side_effect=interruption), \
                        patch.object(runner, 'stop_owned_processes', wraps=runner.stop_owned_processes) as cleanup:
                    with self.assertRaises(type(interruption)):
                        runner.run(candidate, root / 'results')
                    cleanup.assert_called_once()
                    self.assertIsNotNone(cleanup.call_args.args[0].returncode)
                host = json.loads((root / 'results/pair-1-attempt-1/host-session-check.json').read_text()) \
                    if (root / 'results/pair-1-attempt-1/host-session-check.json').exists() else json.loads(
                    (root / 'results/pair-1-attempt-1/runs/run-fixture/host-session-check.json').read_text())
                self.assertFalse(host['valid'])
                self.assertEqual(host['interruptionSignal'], getattr(interruption, 'signum', signal.SIGINT))

    def test_cleanup_reaps_detached_owned_runner_and_preserves_unrelated_process(self):
        runner = self.fixture.module('run-local-benchmark-comparisons')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            derived = root / 'attempt/derived-data'
            derived.mkdir(parents=True)
            binary = derived / 'TracePerformanceTests-Runner'
            shutil.copyfile('/bin/sleep', binary)
            binary.chmod(0o755)
            if sys.platform == 'darwin':
                subprocess.run(['codesign', '-f', '-s', '-', str(binary)], check=True, capture_output=True)
            parent = subprocess.Popen(['/bin/sleep', '60'], start_new_session=True)
            detached = subprocess.Popen([str(binary), '60'], start_new_session=True)
            unrelated = subprocess.Popen(['/bin/sleep', '60'], start_new_session=True)
            try:
                import time
                time.sleep(0.1)
                self.assertIsNone(detached.poll(), 'Detached runner must survive before cleanup')
                self.assertTrue(any(pid == detached.pid and runner.owned_process(group, command, parent.pid, derived)
                                    for pid, group, command in runner.process_records()))
                runner.stop_owned_processes(parent, derived)
                self.assertIsNotNone(parent.poll())
                self.assertIsNotNone(detached.wait(timeout=5))
                self.assertIsNone(unrelated.poll())
            finally:
                for process in [parent, detached, unrelated]:
                    if process.poll() is None: process.terminate()
                    process.wait(timeout=5)

    def test_cleanup_escalates_with_bounded_waits_and_rechecks_detached_identity(self):
        runner = self.fixture.module('run-local-benchmark-comparisons')
        from unittest.mock import Mock
        from itertools import count
        process = Mock(pid=400)
        killed = [False]
        process.poll.side_effect = lambda: 0 if killed[0] else None
        records = lambda: [] if killed[0] else [(401, 400, '/bin/sleep')]
        def signal_group(group, signum):
            if signum == signal.SIGKILL: killed[0] = True
        ticks = count()
        with patch.object(runner, 'process_records', side_effect=records), \
                patch.object(runner.os, 'killpg', side_effect=signal_group) as sent, \
                patch.object(runner.time, 'monotonic', side_effect=lambda: next(ticks)), \
                patch.object(runner.time, 'sleep'):
            runner.stop_owned_processes(process, Path('/attempt/derived-data'))
        self.assertEqual([call.args for call in sent.call_args_list],
                         [(400, signal.SIGINT), (400, signal.SIGTERM), (400, signal.SIGKILL)])
        process.wait.assert_called_once_with(timeout=5)
        snapshots = [[(402, 500, '/attempt/derived-data/Trace')], [(402, 500, '/unrelated/Trace')]]
        with patch.object(runner, 'process_records', side_effect=lambda: snapshots.pop(0) if snapshots else []), \
                patch.object(runner.os, 'kill') as sent_detached:
            runner.stop_owned_processes(process, Path('/attempt/derived-data'))
        sent_detached.assert_not_called()

    def test_quiet_and_attempt_timeouts_are_bounded(self):
        runner = self.fixture.module('run-local-benchmark-comparisons')
        with patch.object(runner, 'competitors', return_value=[]), \
                patch.object(runner.time, 'monotonic', side_effect=[0, 301]):
            with self.assertRaisesRegex(SystemExit, 'Quiet-desktop timeout'):
                runner.wait_for_quiet(Path('/fixture'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = self.runner_fixture(root, 'sleep 60\n')
            with patch.object(runner, 'wait_for_quiet'), patch.object(runner, 'competitors', return_value=[]):
                with self.assertRaisesRegex(SystemExit, 'attempt timeout'):
                    runner.run(candidate, root / 'results', attempt_timeout=0.01)

    def test_acceptance_rejects_missing_changed_or_false_provenance(self):
        for defect in ['missing', 'changed', 'false', 'wrong-commit', 'different-inputs']:
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as directory:
                checker, pairs = self.fixture.local_pairs(Path(directory))
                metadata_path = pairs[2] / 'metadata.json'
                metadata = json.loads(metadata_path.read_text())
                if defect == 'missing': (pairs[2] / 'candidate-build-inputs.after.json').unlink()
                elif defect == 'changed':
                    (pairs[2] / 'candidate-build-inputs.after-candidate.json').write_text('{}')
                elif defect == 'false': metadata['build_inputs_validated'] = False
                elif defect == 'wrong-commit': metadata['candidate_commit'] = 'wrong'
                else:
                    for suffix in ['_build_inputs', '_build_inputs_after']:
                        metadata['candidate' + suffix]['production_sources_sha256'] = 'different'
                    for phase in ['before-baseline', 'after-baseline', 'before-candidate', 'after-candidate', 'after']:
                        (pairs[2] / ('candidate-build-inputs.' + phase + '.json')).write_text(
                            json.dumps(metadata['candidate_build_inputs']))
                metadata_path.write_text(json.dumps(metadata))
                with self.assertRaises((ValueError, FileNotFoundError)):
                    checker.evaluate(pairs)
