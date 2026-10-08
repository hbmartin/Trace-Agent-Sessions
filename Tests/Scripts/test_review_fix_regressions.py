import json
import os
import shutil
import signal
import shlex
import sys
import time
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import test_transcript_benchmark_scripts as fixtures
import test_benchmark_reliability as reliability


class ReviewFixRegressionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.TranscriptBenchmarkScriptTests()

    def prepared_fixture(self, root):
        candidate, baseline = self.fixture.baseline_fixture(root)
        shutil.copy2(fixtures.SCRIPTS / 'validate-benchmark-baseline.py', candidate / 'Scripts/validate-benchmark-baseline.py')
        configure = candidate / 'Scripts/configure-grdb.sh'
        configure.write_text('#!/bin/sh\nexit 0\n')
        configure.chmod(0o755)
        self.fixture.git(candidate, 'add', '.')
        self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'prepared harness')
        self.fixture.git(baseline, 'fetch', '--quiet')
        revision = self.fixture.git(candidate, 'rev-parse', 'HEAD')
        self.fixture.git(baseline, 'reset', '--hard', revision)
        return candidate, baseline, revision

    def test_signing_rejects_comment_delimiter_bypass_and_directives(self):
        validator = self.fixture.module('validate-benchmark-baseline')
        with tempfile.TemporaryDirectory() as directory:
            candidate, _, revision = self.prepared_fixture(Path(directory))
            signing = candidate / 'Config/Signing.xcconfig'
            (candidate / '.git/info/exclude').write_text('Config/Signing.xcconfig\n')
            for value in ['// /*\nSWIFT_OPTIMIZATION_LEVEL = -Onone\n// */\n',
                          '#include "Other.xcconfig"\n',
                          '/* DEVELOPMENT_TEAM = ABC123 */\n']:
                signing.write_text(value)
                with self.assertRaisesRegex(ValueError, 'unsupported build setting'):
                    validator.validate(candidate, candidate, revision, role='candidate')
            signing.write_text('// /* irrelevant text\nDEVELOPMENT_TEAM = ABC123 // */\n')
            validator.validate(candidate, candidate, revision, role='candidate')

    def test_finder_metadata_is_ignored_but_configuration_stays_frozen(self):
        validator = self.fixture.module('validate-benchmark-baseline')
        with tempfile.TemporaryDirectory() as directory:
            candidate, _, revision = self.prepared_fixture(Path(directory))
            (candidate / '.git/info/exclude').write_text('.DS_Store\n')
            before = validator.validate(candidate, candidate, revision, role='candidate')
            (candidate / 'Config/.DS_Store').write_bytes(b'Finder metadata')
            self.assertEqual(before, validator.validate(candidate, candidate, revision, role='candidate'))
            (candidate / 'Config/Extra.xcconfig').write_text('SWIFT_OPTIMIZATION_LEVEL = -Onone')
            with self.assertRaisesRegex(ValueError, 'unexpected build input'):
                validator.validate(candidate, candidate, revision, role='candidate')

    def test_checkout_ownership_accepts_an_alternate_case_for_the_same_directory(self):
        validator = self.fixture.module('validate-benchmark-baseline')
        with tempfile.TemporaryDirectory() as directory:
            candidate, _, revision = self.prepared_fixture(Path(directory))
            alternate = candidate.with_name('CANDIDATE')
            if not alternate.exists():
                self.skipTest('Case-sensitive volume has no alternate-case alias')
            self.assertTrue(os.path.samefile(candidate, alternate))
            self.assertEqual(validator.validate(candidate, candidate, revision),
                             validator.validate(candidate, alternate, revision))

    def test_staged_preparation_preserves_interruption_and_retries(self):
        preparer = self.fixture.module('prepare-benchmark-baseline')
        for phase in ['after-clone', 'during-checkout']:
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                candidate, _, revision = self.prepared_fixture(root)
                marker = root / 'checkout-filter-entered'
                filter_script = root / 'checkout-filter.py'
                filter_script.write_text('import pathlib,sys,time\npathlib.Path(sys.argv[1]).touch()\ntime.sleep(60)\nsys.stdout.buffer.write(sys.stdin.buffer.read())\n')
                if phase == 'during-checkout':
                    (candidate / '.gitattributes').write_text('Sources/TraceApp/MainView.swift filter=review\n')
                    self.fixture.git(candidate, 'add', '.')
                    self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'gated checkout')
                    revision = self.fixture.git(candidate, 'rev-parse', 'HEAD')
                cache = root / 'cache'
                real_run = preparer.subprocess.run
                def interrupted(args, **kwargs):
                    if phase == 'during-checkout' and 'checkout' in args:
                        child = subprocess.Popen(args, start_new_session=True)
                        try:
                            deadline = time.monotonic() + 5
                            while not marker.exists() and time.monotonic() < deadline and child.poll() is None:
                                time.sleep(0.01)
                            self.assertTrue(marker.exists(), 'Real Git checkout must reach its smudge filter before interruption')
                        finally:
                            os.killpg(child.pid, signal.SIGTERM)
                            child.wait(timeout=5)
                        raise subprocess.CalledProcessError(child.returncode, args)
                    result = real_run(args, **kwargs)
                    if 'clone' in args:
                        if phase == 'after-clone':
                            raise KeyboardInterrupt()
                        stage = Path(args[-1])
                        command = shlex.join([sys.executable, str(filter_script), str(marker)])
                        real_run(['git', '-C', str(stage), 'config', 'filter.review.smudge', command], check=True)
                    return result
                with patch.object(preparer.subprocess, 'run', side_effect=interrupted):
                    with self.assertRaises((KeyboardInterrupt, subprocess.CalledProcessError)):
                        preparer.prepare(candidate, cache, revision)
                self.assertFalse(cache.exists())
                evidence = next(root.glob('cache.preparing-*.json'))
                record = json.loads(evidence.read_text())
                self.assertEqual(record['status'], 'interrupted')
                self.assertTrue(Path(record['staging']).exists())
                preparer.prepare(candidate, cache, revision)
                self.assertEqual(self.fixture.git(cache, 'rev-parse', 'HEAD'), revision)
                self.assertTrue(Path(record['staging']).exists(), 'Failed preparation remains available for inspection')
                (cache / 'Sources/TraceApp/MainView.swift').write_text('unexpected change')
                with self.assertRaisesRegex(ValueError, 'unexpected build input'):
                    preparer.prepare(candidate, cache, revision)

    def test_clone_without_checkout_dependency_is_recreated_without_hiding_drift(self):
        preparer = self.fixture.module('prepare-benchmark-baseline')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, cache, _ = self.prepared_fixture(root)
            dependency = root / 'dependency'
            dependency.mkdir()
            self.fixture.git(dependency, 'init', '--quiet')
            (dependency / 'file.c').write_text('source')
            self.fixture.git(dependency, 'add', '.')
            self.fixture.git(dependency, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'dependency')
            self.fixture.git(candidate, '-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet', str(dependency), 'Vendor/Dependency')
            self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-am', 'module')
            self.fixture.git(cache, 'fetch', '--quiet')
            revision = self.fixture.git(candidate, 'rev-parse', 'HEAD')
            self.fixture.git(cache, 'reset', '--hard', revision)
            subprocess.run(['git', 'clone', '--quiet', '--no-checkout', str(dependency), str(cache / 'Vendor/Dependency')], check=True)
            with patch.dict(os.environ, GIT_ALLOW_PROTOCOL='file'):
                preparer.prepare(candidate, cache, revision)
            self.assertTrue((cache / 'Vendor/Dependency/file.c').exists())
            self.assertTrue(list(root.glob('baseline.incomplete-*')))
            with patch.dict(os.environ, GIT_ALLOW_PROTOCOL='file'):
                records = json.loads(subprocess.check_output(
                    [sys.executable, str(fixtures.SCRIPTS / 'prepare-benchmark-baseline.py'),
                     str(candidate), str(root / 'cli-cache'), revision], text=True))
            self.assertEqual(records['.']['commit'], revision)
            self.assertEqual(records['Vendor/Dependency/']['commit'], self.fixture.git(dependency, 'rev-parse', 'HEAD'))
            (cache / 'Vendor/Dependency/file.c').write_text('drift')
            with self.assertRaisesRegex(ValueError, 'unexpected build input'):
                preparer.prepare(candidate, cache, revision)

    def test_outer_runner_configures_before_freezing_candidate(self):
        runner = self.fixture.module('run-local-benchmark-comparisons')
        test = reliability.BenchmarkReliabilityTests()
        test.setUp()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = test.runner_fixture(root, 'exit 23\n')
            source = candidate / 'GRDBCustomSQLite/SQLiteLib-USER.xcconfig'
            source.parent.mkdir(parents=True)
            source.write_text('GRDB_SQLITE_ENABLE_FTS5 = YES\n')
            (candidate / '.gitignore').write_text('Vendor/\n')
            (candidate / 'Scripts/configure-grdb.sh').write_text(
                '#!/bin/sh\nmkdir -p Vendor/GRDB.swift/SQLiteCustom/src\n'
                'cp GRDBCustomSQLite/SQLiteLib-USER.xcconfig Vendor/GRDB.swift/SQLiteCustom/src/SQLiteLib-USER.xcconfig\n')
            self.fixture.git(candidate, 'add', '.')
            self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'first build configuration')
            output = root / 'results'
            with patch.object(runner, 'wait_for_quiet'), patch.object(runner, 'competitors', return_value=[]):
                with self.assertRaisesRegex(SystemExit, 'Comparison failed'):
                    runner.run(candidate, output)
            before = json.loads((output / 'candidate-inputs.json').read_text())
            after = json.loads((output / 'pair-1-attempt-1/candidate-inputs.after.json').read_text())
            self.assertEqual(before, after)
            self.assertIn('Vendor/GRDB.swift/SQLiteCustom/src/SQLiteLib-USER.xcconfig', before['build_input_sha256'])

    def test_initial_interrupt_during_cleanup_is_deferred_until_evidence_is_written(self):
        runner = self.fixture.module('run-local-benchmark-comparisons')
        test = reliability.BenchmarkReliabilityTests()
        test.setUp()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = test.runner_fixture(root, 'sleep 60\n')
            cleanup = runner.stop_owned_processes
            children = []
            def interrupted_cleanup(process, derived):
                children.append(process)
                os.kill(os.getpid(), signal.SIGINT)
                cleanup(process, derived)
                os.kill(os.getpid(), signal.SIGTERM)
            previous = signal.getsignal(signal.SIGINT)
            with patch.object(runner, 'wait_for_quiet'), patch.object(runner, 'competitors', side_effect=SystemExit('timeout')), \
                    patch.object(runner, 'stop_owned_processes', side_effect=interrupted_cleanup):
                with self.assertRaises(runner.RunInterrupted) as result:
                    runner.run(candidate, root / 'results')
            self.assertEqual(result.exception.signum, signal.SIGINT)
            self.assertIsNotNone(children[0].returncode)
            self.assertEqual(signal.getsignal(signal.SIGINT), previous)
            host = json.loads(next((root / 'results').rglob('host-session-check.json')).read_text())
            self.assertFalse(host['valid'])
            self.assertEqual(host['interruptionSignal'], signal.SIGINT)
