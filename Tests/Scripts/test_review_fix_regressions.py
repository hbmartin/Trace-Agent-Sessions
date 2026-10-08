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

    def test_two_commit_indexless_clones_recover_pinned_revision_and_detect_stalls(self):
        validator = self.fixture.module('validate-benchmark-baseline')
        preparer = self.fixture.module('prepare-benchmark-baseline')
        for recovery in ['direct', 'staged', 'stalled']:
            with self.subTest(recovery=recovery), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                candidate, cache, _ = self.prepared_fixture(root)
                dependency = root / 'dependency'
                dependency.mkdir()
                self.fixture.git(dependency, 'init', '--quiet')
                (dependency / 'file.c').write_text('pinned')
                self.fixture.git(dependency, 'add', '.')
                self.fixture.git(dependency, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'pinned')
                pinned = self.fixture.git(dependency, 'rev-parse', 'HEAD')
                self.fixture.git(candidate, '-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet', str(dependency), 'Vendor/Dependency')
                self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-am', 'pin dependency')
                (dependency / 'file.c').write_text('default HEAD ahead')
                self.fixture.git(dependency, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-am', 'newer')
                self.fixture.git(cache, 'fetch', '--quiet')
                revision = self.fixture.git(candidate, 'rev-parse', 'HEAD')
                self.fixture.git(cache, 'reset', '--hard', revision)
                target = cache / 'Vendor/Dependency'
                subprocess.run(['git', 'clone', '--quiet', '--no-checkout', str(dependency), str(target)], check=True)
                (target / '.DS_Store').write_bytes(b'Finder')
                records = validator.validate(candidate, cache, revision, allow_uninitialized=True)
                self.assertEqual(records['uninitialized_submodules'], ['Vendor/Dependency'])
                unexpected = target / 'notes.txt'
                unexpected.write_text('unexpected incomplete-cache content')
                with self.assertRaisesRegex(ValueError, 'files in an incomplete dependency'):
                    validator.validate(candidate, cache, revision, allow_uninitialized=True)
                unexpected.unlink()
                if recovery == 'stalled':
                    real_run = validator.subprocess.run
                    mutations = []
                    def stalled(args, **kwargs):
                        if 'checkout' in args:
                            mutations.append(args); return subprocess.CompletedProcess(args, 0)
                        return real_run(args, **kwargs)
                    with patch.object(validator.subprocess, 'run', side_effect=stalled):
                        with self.assertRaisesRegex(ValueError, 'made no progress'):
                            validator.initialize_missing(candidate, cache, revision)
                    self.assertEqual(len(mutations), 1)
                    continue
                with patch.dict(os.environ, GIT_ALLOW_PROTOCOL='file'):
                    if recovery == 'staged': preparer.prepare(candidate, cache, revision)
                    else: validator.initialize_missing(candidate, cache, revision)
                self.assertEqual(self.fixture.git(target, 'rev-parse', 'HEAD'), pinned)
                self.assertEqual((target / 'file.c').read_text(), 'pinned')
                self.fixture.git(target, 'checkout', '--quiet', self.fixture.git(dependency, 'rev-parse', 'HEAD'))
                with self.assertRaisesRegex(ValueError, 'Dependency revision differs'):
                    validator.initialize_missing(candidate, cache, revision)

    def test_foreground_group_signals_during_cleanup_inventory_and_evidence(self):
        runner_source = fixtures.SCRIPTS / 'run-local-benchmark-comparisons.py'
        test = reliability.BenchmarkReliabilityTests()
        test.setUp()
        for first in [signal.SIGINT, signal.SIGTERM]:
            for phase in ['inventory', 'evidence']:
                with self.subTest(signal=first, phase=phase), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    candidate = test.runner_fixture(root, 'sleep 60\n')
                    tools = root / 'tools'; tools.mkdir()
                    fake_ps = tools / 'ps'
                    fake_ps.write_text('#!' + sys.executable + '\nimport os,pathlib,time\nr=pathlib.Path(' + repr(str(root)) + ')\n'
                        "if (r/'cleanup').exists():\n (r/'inventory').touch();time.sleep(.3)\n"
                        "os.execv('/bin/ps',['ps',*__import__('sys').argv[1:]])\n")
                    fake_ps.chmod(0o755)
                    wrapper = root / 'wrapper.py'
                    wrapper.write_text("import importlib.util,pathlib,signal,sys,time\n"
                        f"r=pathlib.Path({str(root)!r})\n"
                        f"s=importlib.util.spec_from_file_location('runner',{str(runner_source)!r});m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
                        "m.wait_for_quiet=lambda *a:None\n"
                        "m.competitors=lambda *a:(_ for _ in ()).throw(SystemExit('fixture cleanup'))\n"
                        "cleanup=m.stop_owned_processes\n"
                        "def stop(p,d):\n (r/'owned-pid').write_text(str(p.pid));(r/'cleanup').touch();cleanup(p,d)\n"
                        "m.stop_owned_processes=stop\n"
                        "write=m.write_json\n"
                        "def publish(p,v):\n write(p,v)\n if p.name=='host-session-check.json':\n  (r/'evidence').touch();time.sleep(.4)\n"
                        "m.write_json=publish\n"
                        "try:m.run(r/'candidate',r/'results')\n"
                        "except m.RunInterrupted as e:sys.exit(128+e.signum)\n")
                    unrelated = subprocess.Popen(['sleep', '60'], start_new_session=True)
                    log = (root / 'signal-test.log').open('w')
                    child = subprocess.Popen([sys.executable, str(wrapper)], stdout=log, stderr=log,
                        start_new_session=True, env=dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH']))
                    try:
                        deadline = time.monotonic() + 12
                        while not (root / phase).exists() and child.poll() is None and time.monotonic() < deadline:
                            time.sleep(.01)
                        self.assertTrue((root / phase).exists(), 'Must reach the real cancellation phase')
                        os.killpg(child.pid, first)
                        time.sleep(.04)
                        os.killpg(child.pid, signal.SIGTERM if first == signal.SIGINT else signal.SIGINT)
                        self.assertEqual(child.wait(timeout=35), 128 + first)
                        self.assertIsNone(unrelated.poll(), 'An unrelated session must survive')
                        host = json.loads(next((root / 'results').rglob('host-session-check.json')).read_text())
                        self.assertFalse(host['valid'])
                        self.assertEqual(host['interruptionSignal'], first)
                        owned = int((root / 'owned-pid').read_text())
                        with self.assertRaises(ProcessLookupError): os.kill(owned, 0)
                    finally:
                        if child.poll() is None: child.kill();child.wait(timeout=5)
                        unrelated.terminate();unrelated.wait(timeout=5)
                        log.close()

    def test_empty_root_cache_is_quarantined_before_default_head_comparison(self):
        preparer = self.fixture.module('prepare-benchmark-baseline')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, _, pinned = self.prepared_fixture(root)
            (candidate / 'Sources/TraceApp/MainView.swift').write_text('new default HEAD')
            self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-am', 'newer')
            cache = root / 'empty-cache'
            subprocess.run(['git', 'clone', '--quiet', '--no-checkout', str(candidate), str(cache)], check=True)
            (cache / '.DS_Store').write_bytes(b'Finder')
            preparer.prepare(candidate, cache, pinned)
            self.assertEqual(self.fixture.git(cache, 'rev-parse', 'HEAD'), pinned)
            previous = next(root.glob('empty-cache.incomplete-*'))
            self.assertTrue((previous / '.DS_Store').exists())
            self.assertFalse((previous / 'Sources').exists())

    def test_cached_recognized_sqlite_overlay_can_be_extended_without_hiding_drift(self):
        preparer = self.fixture.module('prepare-benchmark-baseline')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, cache, _ = self.prepared_fixture(root)
            dependency = root / 'dependency'; dependency.mkdir()
            self.fixture.git(dependency, 'init', '--quiet')
            source = dependency / 'SQLiteCustom/src/sqlite/src/os_unix.c'
            source.parent.mkdir(parents=True); source.write_text('original\n')
            self.fixture.git(dependency, 'add', '.')
            self.fixture.git(dependency, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'SQLite fixture')
            self.fixture.git(candidate, '-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet', str(dependency), 'Vendor/GRDB.swift')
            patch_path = 'GRDBCustomSQLite/SQLiteRegularFiles.patch'
            old_patch = '--- a/sqlite/src/os_unix.c\n+++ b/sqlite/src/os_unix.c\n@@ -1 +1 @@\n-original\n+protected\n'
            (candidate / patch_path).write_text(old_patch)
            configure = candidate / 'Scripts/configure-grdb.sh'
            configure.write_text('#!/bin/sh\nset -eu\ncd "$(dirname "$0")/../Vendor/GRDB.swift/SQLiteCustom/src"\n'
                'patch="../../../../GRDBCustomSQLite/SQLiteRegularFiles.patch"\n'
                'git apply --unidiff-zero --reverse --check "$patch" 2>/dev/null || git apply --unidiff-zero "$patch"\n')
            configure.chmod(0o755)
            self.fixture.git(candidate, 'add', '.')
            self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'recognized overlay')
            revision = self.fixture.git(candidate, 'rev-parse', 'HEAD')
            with patch.dict(os.environ, GIT_ALLOW_PROTOCOL='file'):
                preparer.prepare(candidate, root / 'cache', revision)
            cache = root / 'cache'
            self.assertEqual((cache / 'Vendor/GRDB.swift/SQLiteCustom/src/sqlite/src/os_unix.c').read_text(), 'protected\n')
            (candidate / patch_path).write_text(old_patch.replace('+protected', '+extended protection'))
            self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-am', 'extend overlay')
            preparer.prepare(candidate, cache, revision)
            target = cache / 'Vendor/GRDB.swift/SQLiteCustom/src/sqlite/src/os_unix.c'
            self.assertEqual(target.read_text(), 'extended protection\n')
            target.write_text('unexpected source change\n')
            with self.assertRaisesRegex(ValueError, 'Unexpected SQLite'):
                preparer.prepare(candidate, cache, revision)

    def test_outer_runner_configures_before_freezing_candidate(self):
        runner = self.fixture.module('run-local-benchmark-comparisons')
        test = reliability.BenchmarkReliabilityTests()
        test.setUp()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = test.runner_fixture(root, 'exit 23\n')
            source = candidate / 'GRDBCustomSQLite/SQLiteLib-USER.xcconfig'
            source.parent.mkdir(parents=True, exist_ok=True)
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

    def test_interrupt_after_acceptance_publication_invalidates_final_report(self):
        runner = self.fixture.module('run-local-benchmark-comparisons')
        test = reliability.BenchmarkReliabilityTests(); test.setUp()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = test.runner_fixture(root, 'exit 0\n')
            real_run = runner.subprocess.run
            def publish(args, **kwargs):
                if any(str(arg).endswith('check-local-benchmark-regressions.py') for arg in args):
                    (root / 'results/local-acceptance.json').write_text('{"status":"passed"}')
                    os.kill(os.getpid(), signal.SIGTERM)
                    return subprocess.CompletedProcess(args, 0)
                return real_run(args, **kwargs)
            with patch.object(runner, 'wait_for_quiet'), patch.object(runner, 'competitors', return_value=[]), \
                 patch.object(runner.subprocess, 'run', side_effect=publish):
                with self.assertRaises(runner.RunInterrupted) as interruption:
                    runner.run(candidate, root / 'results')
            self.assertEqual(interruption.exception.signum, signal.SIGTERM)
            report = json.loads((root / 'results/local-acceptance.json').read_text())
            self.assertEqual(report['status'], 'interrupted')
            self.assertFalse(report['valid'])
            host = json.loads((root / 'results/pair-3-attempt-1/runs/run-fixture/host-session-check.json').read_text())
            self.assertFalse(host['valid'])

    def test_signal_pending_during_final_handler_restoration_invalidates_evidence(self):
        runner = self.fixture.module('run-local-benchmark-comparisons')
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / 'host-session-check.json'
            original_signal = signal.signal
            previous = signal.getsignal(signal.SIGTERM)
            injected = False
            def restore(sig, handler):
                nonlocal injected
                result = original_signal(sig, handler)
                if sig == signal.SIGTERM and handler == previous and not injected:
                    injected = True
                    os.kill(os.getpid(), signal.SIGTERM)
                return result
            with patch.object(runner.signal, 'signal', side_effect=restore):
                with self.assertRaises(runner.RunInterrupted) as interruption:
                    with runner.CancellationController() as cancellation:
                        cancellation.publish(evidence, {'valid': True})
            self.assertEqual(interruption.exception.signum, signal.SIGTERM)
            self.assertFalse(json.loads(evidence.read_text())['valid'])
            self.assertEqual(signal.getsignal(signal.SIGTERM), previous)

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
