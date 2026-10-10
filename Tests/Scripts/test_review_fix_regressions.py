import json
import pty
import os
import shutil
import signal
import shlex
import sys
import time
import subprocess
import tempfile
import termios
import unittest
from unittest import mock
from pathlib import Path
from unittest.mock import patch

import test_transcript_benchmark_scripts as fixtures
import test_benchmark_reliability as reliability


class ReviewFixRegressionTests(unittest.TestCase):
    def setUp(self):
        previous_signals = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        self.addCleanup(lambda: [signal.signal(sig, handler) for sig, handler in previous_signals.items()])
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

    def test_direct_empty_cache_cannot_checkout_its_parent_repository(self):
        validator = self.fixture.module('validate-benchmark-baseline')
        with tempfile.TemporaryDirectory() as directory:
            candidate, _, pinned = self.prepared_fixture(Path(directory))
            source = candidate / 'Sources/TraceApp/MainView.swift'
            source.write_text('new developer HEAD')
            self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                             'commit', '--quiet', '-am', 'new developer HEAD')
            head = self.fixture.git(candidate, 'rev-parse', 'HEAD')
            cache = candidate / 'build/local-release-baseline'
            cache.mkdir(parents=True)
            (cache / '.DS_Store').write_bytes(b'Finder')
            with self.assertRaises(ValueError) as error:
                validator.initialize_missing(candidate, cache, pinned)
            self.assertEqual(self.fixture.git(candidate, 'rev-parse', 'HEAD'), head)
            self.assertIn('own repository', str(error.exception))
            self.assertEqual(source.read_text(), 'new developer HEAD')

    def test_complete_harness_manifest_rejects_an_omitted_instrumentation_file(self):
        validator = self.fixture.module('validate-benchmark-baseline')
        with tempfile.TemporaryDirectory() as directory:
            candidate, baseline, revision = self.prepared_fixture(Path(directory))
            (baseline / 'Sources/TraceCore/Diagnostics/TracePerformance.swift').unlink()
            records = validator.validate(candidate, baseline, revision)
            with self.assertRaisesRegex(ValueError, 'Missing synchronized harness'):
                validator.require_complete_harness(candidate, records)

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
                    wrapper.write_text("import fcntl,importlib.util,os,pathlib,signal,sys,termios,time\n"
                        "fcntl.ioctl(sys.stdin.fileno(),termios.TIOCSCTTY,0)\n"
                        "os.tcsetpgrp(sys.stdin.fileno(),os.getpgrp())\n"
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
                    master, slave = pty.openpty()
                    settings = termios.tcgetattr(slave)
                    settings[3] = (settings[3] | termios.ISIG) & ~termios.ECHO
                    settings[6][termios.VINTR] = b'\x03'
                    termios.tcsetattr(slave, termios.TCSANOW, settings)
                    child = subprocess.Popen([sys.executable, str(wrapper)], stdin=slave, stdout=log, stderr=log,
                        start_new_session=True, env=dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH']))
                    os.close(slave)
                    try:
                        deadline = time.monotonic() + 12
                        while not (root / phase).exists() and child.poll() is None and time.monotonic() < deadline:
                            time.sleep(.01)
                        self.assertTrue((root / phase).exists(), 'Must reach the real cancellation phase')
                        self.assertEqual(os.tcgetpgrp(master), child.pid,
                            'The cancellation target must own the real terminal foreground group')
                        def send(signum):
                            if signum == signal.SIGINT:
                                os.write(master, b'\x03')
                            else:
                                os.killpg(os.tcgetpgrp(master), signum)
                        send(first)
                        time.sleep(.04)
                        send(signal.SIGTERM if first == signal.SIGINT else signal.SIGINT)
                        time.sleep(.04)
                        send(first)
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
                        os.close(master)
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
            source.parent.mkdir(parents=True); source.write_text('original\nterminal\n')
            self.fixture.git(dependency, 'add', '.')
            self.fixture.git(dependency, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'SQLite fixture')
            self.fixture.git(candidate, '-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet', str(dependency), 'Vendor/GRDB.swift')
            patch_path = 'GRDBCustomSQLite/SQLiteRegularFiles.patch'
            old_patch = '--- a/sqlite/src/os_unix.c\n+++ b/sqlite/src/os_unix.c\n@@ -1 +1 @@\n-original\n+protected\n'
            (candidate / patch_path).write_text(old_patch)
            terminal_patch = candidate / 'GRDBCustomSQLite/SQLiteNoControllingTerminal.patch'
            terminal_patch.write_text('--- a/sqlite/src/os_unix.c\n+++ b/sqlite/src/os_unix.c\n@@ -2 +2 @@\n-terminal\n+no-controlling-terminal\n')
            configure = candidate / 'Scripts/configure-grdb.sh'
            configure.write_text('#!/bin/sh\nset -eu\ncd "$(dirname "$0")/../Vendor/GRDB.swift/SQLiteCustom/src"\n'
                'for patch in ../../../../GRDBCustomSQLite/SQLiteRegularFiles.patch ../../../../GRDBCustomSQLite/SQLiteNoControllingTerminal.patch; do\n'
                'git apply --unidiff-zero --reverse --check "$patch" 2>/dev/null || git apply --unidiff-zero "$patch"\ndone\n')
            configure.chmod(0o755)
            self.fixture.git(candidate, 'add', '.')
            self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'recognized overlay')
            revision = self.fixture.git(candidate, 'rev-parse', 'HEAD')
            with patch.dict(os.environ, GIT_ALLOW_PROTOCOL='file'):
                preparer.prepare(candidate, root / 'cache', revision)
            cache = root / 'cache'
            self.assertEqual((cache / 'Vendor/GRDB.swift/SQLiteCustom/src/sqlite/src/os_unix.c').read_text(), 'protected\nno-controlling-terminal\n')
            (candidate / patch_path).write_text(old_patch.replace('+protected', '+extended protection'))
            self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-am', 'extend overlay')
            preparer.prepare(candidate, cache, revision)
            target = cache / 'Vendor/GRDB.swift/SQLiteCustom/src/sqlite/src/os_unix.c'
            self.assertEqual(target.read_text(), 'extended protection\nno-controlling-terminal\n')
            target.write_text('unexpected source change\n')
            with self.assertRaisesRegex(ValueError, 'Unexpected SQLite'):
                preparer.prepare(candidate, cache, revision)

    def test_real_sqlite_overlay_preparation_and_upgrade_are_exact_and_idempotent(self):
        validator = self.fixture.module('validate-benchmark-baseline')
        trusted = fixtures.SCRIPTS.parent
        pinned = trusted / 'Vendor/GRDB.swift/SQLiteCustom/src'
        if not pinned.exists(): self.skipTest('Pinned SQLite submodule is required')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, _, _ = self.prepared_fixture(root)
            dependency = root / 'dependency'; dependency.mkdir()
            self.fixture.git(dependency, 'init', '--quiet')
            names = ['sqlite/src/os_unix.c', 'SQLiteLib.xcodeproj/project.pbxproj', 'SQLiteLib.xcconfig']
            for name in names:
                output = dependency / 'SQLiteCustom/src' / name
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(subprocess.check_output(['git', '-C', str(pinned), 'show', 'HEAD:' + name]))
            (dependency / 'GRDBCustom.xcodeproj').mkdir()
            (dependency / 'GRDBCustom.xcodeproj/fixture').write_text('fixture')
            (dependency / '.gitignore').write_text('*-USER.h\n*-USER.xcconfig\n')
            self.fixture.git(dependency, 'add', '.')
            self.fixture.git(dependency, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'pinned SQLite')
            self.fixture.git(candidate, '-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet', str(dependency), 'Vendor/GRDB.swift')
            for path in (trusted / 'GRDBCustomSQLite').iterdir():
                if path.is_file(): shutil.copy2(path, candidate / 'GRDBCustomSQLite' / path.name)
            shutil.copy2(fixtures.SCRIPTS / 'configure-grdb.sh', candidate / 'Scripts/configure-grdb.sh')
            self.fixture.git(candidate, 'add', '.')
            self.fixture.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'current safety overlay')
            revision = self.fixture.git(candidate, 'rev-parse', 'HEAD')
            checkout = candidate / 'Vendor/GRDB.swift/SQLiteCustom/src'
            original = {name: (checkout / name).read_bytes() for name in names}
            for stage in ['pristine', 'regular-only', 'regular-and-terminal', 'terminal-only']:
                with self.subTest(stage=stage):
                    for name,data in original.items(): (checkout / name).write_bytes(data)
                    patches = []
                    if stage.startswith('regular'): patches.append('SQLiteRegularFiles-v1.patch')
                    if stage in ['regular-and-terminal', 'terminal-only']: patches.append('SQLiteNoControllingTerminal.patch')
                    for patch in patches:
                        subprocess.run(['git', 'apply', '--unidiff-zero', str(candidate / 'GRDBCustomSQLite' / patch)], cwd=checkout, check=True, capture_output=True)
                    validator.validate(candidate, candidate, revision, role='candidate', preparation=True)
                    with self.assertRaisesRegex(ValueError, 'Unexpected SQLite'):
                        validator.validate(candidate, candidate, revision, role='candidate')
                    validator.normalize_sqlite(candidate)
                    validator.validate(candidate, candidate, revision, role='candidate')
                    final = {name: (checkout / name).read_bytes() for name in names}
                    times = {name: (checkout / name).stat().st_mtime_ns for name in names}
                    read_git = validator.git
                    def without_history(root, *args):
                        self.assertNotIn('log', args, 'Canonical files must not require historical overlays')
                        return read_git(root, *args)
                    with mock.patch.object(validator, 'git', side_effect=without_history):
                        validator.normalize_sqlite(candidate)
                        validator.validate(candidate, candidate, revision, role='candidate')
                    self.assertEqual(final, {name: (checkout / name).read_bytes() for name in names})
                    self.assertEqual(times, {name: (checkout / name).stat().st_mtime_ns for name in names})
            # Reject drift in the final file before replacing earlier pristine files.
            for name, data in original.items(): (checkout / name).write_bytes(data)
            config = checkout / 'SQLiteLib.xcconfig'
            config.write_bytes(config.read_bytes() + b'\nUNRELATED = YES\n')
            before = {name: (checkout / name).read_bytes() for name in names}
            with self.assertRaisesRegex(ValueError, 'refusing to overwrite'):
                validator.normalize_sqlite(candidate)
            self.assertEqual(before, {name: (checkout / name).read_bytes() for name in names})
            for name, data in final.items(): (checkout / name).write_bytes(data)
            patch = candidate / 'GRDBCustomSQLite/SQLiteRegularFiles.patch'
            patch.write_text(patch.read_text().replace('Nonblocking opens also cover', 'Nonblocking descriptor opens also cover'))
            # An invocation must see changed patch bytes even with an unchanged HEAD.
            self.assertEqual(revision, self.fixture.git(candidate, 'rev-parse', 'HEAD'))
            validator.normalize_sqlite(candidate)
            source = checkout / 'sqlite/src/os_unix.c'
            self.assertIn('Nonblocking descriptor opens also cover', source.read_text())
            source.write_text(source.read_text() + '\n/* unrelated change */\n')
            before = source.read_bytes()
            with self.assertRaisesRegex(ValueError, 'refusing to overwrite'):
                validator.normalize_sqlite(candidate)
            self.assertEqual(source.read_bytes(), before)

    def test_sqlite_reconstruction_cache_distinguishes_source_and_patch_bytes(self):
        validator = self.fixture.module('validate-benchmark-baseline')
        patch = b'--- a/example.c\n+++ b/example.c\n@@ -1 +1 @@\n-original\n+protected\n'
        with tempfile.TemporaryDirectory() as directory:
            resolver = validator.SQLitePatchResolver(Path(directory))
            temporary = validator.tempfile.TemporaryDirectory
            with mock.patch.object(validator.tempfile, 'TemporaryDirectory', wraps=temporary) as directories:
                self.assertEqual(resolver.applied('example.c', b'original\n', [patch]), b'protected\n')
                self.assertEqual(resolver.applied('example.c', b'original\n', [bytes(bytearray(patch))]), b'protected\n')
                self.assertEqual(directories.call_count, 1, 'Identical patch content shares one reconstruction')
                self.assertEqual(resolver.applied('example.c', b'original\nextra\n', [patch]), b'protected\nextra\n')
                changed = patch.replace(b'+protected', b'+safer')
                self.assertEqual(resolver.applied('example.c', b'original\n', [changed]), b'safer\n')
                self.assertEqual(directories.call_count, 3)

    def test_signal_at_former_handler_handoff_invalidates_evidence(self):
        runner_source = fixtures.SCRIPTS / 'run-local-benchmark-comparisons.py'
        for first in [signal.SIGINT, signal.SIGTERM]:
            with self.subTest(signal=first), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                script = root / 'child.py'
                script.write_text("import importlib.util,os,pathlib,signal,sys\n"
                    f"spec=importlib.util.spec_from_file_location('runner',{str(runner_source)!r});m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)\n"
                    f"r=pathlib.Path({str(root)!r});first={int(first)}\n"
                    "previous={sig:signal.getsignal(sig) for sig in (signal.SIGINT,signal.SIGTERM)};install=m.signal.signal\n"
                    "def handoff(sig,handler):\n"
                    " result=install(sig,handler)\n"
                    " if handler==previous[sig]:os.kill(os.getpid(),first)\n"
                    " return result\n"
                    "m.signal.signal=handoff\n"
                    "original=m.CancellationController._drain_pending\n"
                    "def late(self):\n"
                    " os.kill(os.getpid(),first);original(self)\n"
                    "m.CancellationController._drain_pending=late\n"
                    "try:\n"
                    " with m.CancellationController(process_lifetime=True) as c:\n"
                    "  c.acceptance=r/'acceptance.json';c.acceptance.write_text('{\"status\":\"passed\"}')\n"
                    "  c.publish(r/'host.json',{'valid':True})\n"
                    "except m.RunInterrupted as e:sys.exit(128+e.signum)\n")
                child = subprocess.run([sys.executable, str(script)], start_new_session=True,
                                       capture_output=True, text=True, timeout=5)
                self.assertEqual(child.returncode, 128 + first, child.stderr)
                for name in ['acceptance.json','host.json']:
                    result = json.loads((root / name).read_text())
                    self.assertFalse(result['valid'])
                    self.assertEqual(result['interruptionSignal'], first)

    def test_signal_between_final_drain_and_evidence_publication_is_retained(self):
        runner_source = fixtures.SCRIPTS / 'run-local-benchmark-comparisons.py'
        for first in [signal.SIGINT, signal.SIGTERM]:
            with self.subTest(signal=first), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                script = root / 'child.py'
                script.write_text("import importlib.util,os,pathlib,signal,sys\n"
                    f"spec=importlib.util.spec_from_file_location('runner',{str(runner_source)!r});m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)\n"
                    f"r=pathlib.Path({str(root)!r});first={int(first)}\n"
                    "original=m.CancellationController._invalidate_interrupted_evidence\n"
                    "def late(self):\n"
                    " original(self);os.kill(os.getpid(),first)\n"
                    "m.CancellationController._invalidate_interrupted_evidence=late\n"
                    "try:\n"
                    " with m.CancellationController(process_lifetime=True) as c:\n"
                    "  c.acceptance=r/'acceptance.json';c.acceptance.write_text('{\"status\":\"passed\"}')\n"
                    "  c.publish(r/'host.json',{'valid':True})\n"
                    "except m.RunInterrupted as e:sys.exit(128+e.signum)\n")
                child = subprocess.run([sys.executable, str(script)], start_new_session=True,
                                       capture_output=True, text=True, timeout=5)
                self.assertEqual(child.returncode, 128 + first, child.stderr)
                for name in ['acceptance.json', 'host.json']:
                    record = json.loads((root / name).read_text())
                    self.assertFalse(record['valid'])
                    self.assertEqual(record['interruptionSignal'], first)

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

    def test_interrupted_acceptance_tolerates_damaged_or_nonobject_reports(self):
        runner = self.fixture.module('run-local-benchmark-comparisons')
        for content in [b'{"status":', b'[]', b'null', b'"passed"', b'\xff', b'unreadable', None]:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                report = root / 'local-acceptance.json'
                evidence = root / 'host-session-check.json'
                if content is not None:
                    report.write_bytes(content)
                read_text = Path.read_text
                def read_report(path, *args, **kwargs):
                    if path == report and content == b'unreadable':
                        raise OSError('Fixture report read failed')
                    return read_text(path, *args, **kwargs)
                with patch.object(Path, 'read_text', read_report), self.assertRaises(runner.RunInterrupted) as interruption:
                    with runner.CancellationController() as cancellation:
                        cancellation.acceptance = report
                        cancellation.publish(evidence, {'valid': True})
                        cancellation.record(signal.SIGTERM)
                        cancellation.checkpoint()
                self.assertEqual(interruption.exception.signum, signal.SIGTERM)
                result = json.loads(report.read_text())
                self.assertEqual(result['status'], 'interrupted')
                self.assertFalse(result['valid'])
                self.assertEqual(result['interruptionSignal'], signal.SIGTERM)
                self.assertFalse(json.loads(evidence.read_text())['valid'])

    def test_foreground_signal_at_final_unblocking_invalidates_evidence(self):
        runner_source = fixtures.SCRIPTS / 'run-local-benchmark-comparisons.py'
        for first in [signal.SIGINT, signal.SIGTERM]:
            with self.subTest(signal=first), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                wrapper = root / 'wrapper.py'
                wrapper.write_text("import fcntl,importlib.util,json,os,pathlib,signal,sys,termios,time\n"
                    "fcntl.ioctl(sys.stdin.fileno(),termios.TIOCSCTTY,0)\n"
                    "os.tcsetpgrp(sys.stdin.fileno(),os.getpgrp())\n"
                    f"r=pathlib.Path({str(root)!r})\n"
                    f"s=importlib.util.spec_from_file_location('runner',{str(runner_source)!r});m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
                    "previous={sig:signal.getsignal(sig) for sig in m.CancellationController.signals}\n"
                    "mask=signal.pthread_sigmask\n"
                    "def unblock(how,signals):\n"
                    " if how==signal.SIG_SETMASK:\n"
                    "  (r/'unblock').touch();deadline=time.monotonic()+5\n"
                    "  while not (r/'resume').exists():\n"
                    "   if time.monotonic()>deadline:raise RuntimeError('Unblock gate timed out')\n"
                    "   time.sleep(.01)\n"
                    "  (r/'pending.json').write_text(json.dumps(list(signal.sigpending())))\n"
                    " return mask(how,signals)\n"
                    "m.signal.pthread_sigmask=unblock\n"
                    "try:\n"
                    " with m.CancellationController() as c:\n"
                    "  c.acceptance=r/'local-acceptance.json';c.acceptance.write_text('{\"status\":\"passed\"}')\n"
                    "  c.publish(r/'host-session-check.json',{'valid':True})\n"
                    "except m.RunInterrupted as e:\n"
                    " assert all(signal.getsignal(sig)==c.record for sig in previous)\n"
                    " sys.exit(128+e.signum)\n")
                unrelated = subprocess.Popen(['sleep', '60'], start_new_session=True)
                master, slave = pty.openpty()
                settings = termios.tcgetattr(slave)
                settings[3] = (settings[3] | termios.ISIG) & ~termios.ECHO
                settings[6][termios.VINTR] = b'\x03'
                termios.tcsetattr(slave, termios.TCSANOW, settings)
                with (root / 'signal-test.log').open('w') as log:
                    child = subprocess.Popen([sys.executable, str(wrapper)], stdin=slave,
                        stdout=log, stderr=log, start_new_session=True)
                    os.close(slave)
                    try:
                        deadline = time.monotonic() + 5
                        while not (root / 'unblock').exists() and child.poll() is None and time.monotonic() < deadline:
                            time.sleep(.01)
                        self.assertTrue((root / 'unblock').exists(), (root / 'signal-test.log').read_text())
                        self.assertEqual(os.tcgetpgrp(master), child.pid)
                        for _ in range(2):
                            if first == signal.SIGINT:
                                os.write(master, b'\x03')
                            else:
                                os.killpg(os.tcgetpgrp(master), first)
                        (root / 'resume').touch()
                        self.assertEqual(child.wait(timeout=8), 128 + first)
                        self.assertIn(first, json.loads((root / 'pending.json').read_text()))
                        self.assertIsNone(unrelated.poll())
                        for name in ['host-session-check.json', 'local-acceptance.json']:
                            result = json.loads((root / name).read_text())
                            self.assertFalse(result['valid'])
                            self.assertEqual(result['interruptionSignal'], first)
                    finally:
                        if child.poll() is None: child.kill();child.wait(timeout=5)
                        unrelated.terminate();unrelated.wait(timeout=5)
                        os.close(master)

    def test_failed_interruption_publication_restores_imported_mask_and_preserves_first_signal(self):
        runner_source = fixtures.SCRIPTS / 'run-local-benchmark-comparisons.py'
        for first in [signal.SIGINT, signal.SIGTERM]:
            for failed_file in ['host-session-check.json', 'local-acceptance.json']:
                for lifetime in [False, True]:
                    with self.subTest(signal=first, file=failed_file, lifetime=lifetime), tempfile.TemporaryDirectory() as directory:
                        root = Path(directory)
                        child = root / 'child.py'
                        child.write_text("import importlib.util,json,os,pathlib,signal,sys\n"
                            f"s=importlib.util.spec_from_file_location('runner',{str(runner_source)!r});m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
                            f"r=pathlib.Path({str(root)!r});first={int(first)};lifetime={lifetime!r}\n"
                            "before=signal.pthread_sigmask(signal.SIG_BLOCK,[])\n"
                            "host=r/'host-session-check.json';report=r/'local-acceptance.json'\n"
                            "host.write_text('{\"valid\":true}');report.write_text('{\"status\":\"passed\",\"valid\":true}')\n"
                            "write=m.write_json;attempted=[]\n"
                            "def fail(path,value):\n"
                            " attempted.append(path.name)\n"
                            f" if path.name=={failed_file!r}:raise OSError('evidence unavailable')\n"
                            " write(path,value)\n"
                            "m.write_json=fail\n"
                            "try:\n"
                            " with m.CancellationController(process_lifetime=lifetime) as c:\n"
                            "  c.evidence=(host,{'valid':True});c.acceptance=report\n"
                            "  os.kill(os.getpid(),first)\n"
                            "  os.kill(os.getpid(),signal.SIGTERM if first==signal.SIGINT else signal.SIGINT)\n"
                            "except m.RunInterrupted as e:\n"
                            " after=signal.pthread_sigmask(signal.SIG_BLOCK,[])\n"
                            " assert e.signum==first and isinstance(e.__cause__,OSError)\n"
                            " assert set(attempted)=={host.name,report.name}\n"
                            " assert all(signal.getsignal(sig)==c.record for sig in c.signals)\n"
                            " assert (set(c.signals)<=after) if lifetime else (after==before)\n"
                            " other=report if host.name==" + repr(failed_file) + " else host\n"
                            " assert json.loads(other.read_text())['valid'] is False\n"
                            " print(json.dumps({'signal':e.signum,'mask':sorted(int(s) for s in after)}))\n"
                            " sys.exit(128+e.signum if lifetime else 0)\n"
                            "raise AssertionError('interruption must be raised')\n")
                        result = subprocess.run([sys.executable, str(child)], capture_output=True, text=True, timeout=8)
                        self.assertEqual(result.returncode, 128 + first if lifetime else 0, result.stderr)
                        self.assertEqual(json.loads(result.stdout)['signal'], first)

    def test_finalization_failure_without_interrupt_restores_mask_and_propagates_error(self):
        runner_source = fixtures.SCRIPTS / 'run-local-benchmark-comparisons.py'
        code = ("import importlib.util,signal\n"
                f"s=importlib.util.spec_from_file_location('runner',{str(runner_source)!r});m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
                "before=signal.pthread_sigmask(signal.SIG_BLOCK,[])\n"
                "failure=OSError('pending drain unavailable')\n"
                "def fail():raise failure\n"
                "try:\n"
                " with m.CancellationController() as c:c._drain_pending=fail\n"
                "except OSError as e:\n"
                " assert e is failure\n"
                " assert signal.pthread_sigmask(signal.SIG_BLOCK,[])==before\n"
                "else:raise AssertionError('finalization error must propagate')\n")
        result = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)

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
            self.assertNotEqual(signal.getsignal(signal.SIGINT), previous, "recording handlers remain owned through evidence inspection")
            host = json.loads(next((root / 'results').rglob('host-session-check.json')).read_text())
            self.assertFalse(host['valid'])
            self.assertEqual(host['interruptionSignal'], signal.SIGINT)
