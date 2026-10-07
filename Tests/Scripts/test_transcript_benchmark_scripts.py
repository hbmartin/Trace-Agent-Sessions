import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"


class TranscriptBenchmarkScriptTests(unittest.TestCase):
    def test_incomplete_metric_export_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, identifiers in [("baseline", ["cpu", "clock"]), ("candidate", ["cpu"])]:
                report = [{"testIdentifier": "testTranscriptScrollPerformance()", "testRuns": [{
                    "metrics": [{"identifier": identifier, "displayName": identifier,
                                 "measurements": [1, 2, 3]} for identifier in identifiers]
                }]}]
                (root / f"{name}.json").write_text(json.dumps(report))
            result = subprocess.run([
                sys.executable, str(SCRIPTS / "compare-transcript-scroll-metrics.py"),
                str(root / "baseline.json"), str(root / "candidate.json"),
                "--test", "testTranscriptScrollPerformance()",
            ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("baseline only=['clock']", result.stderr)
            self.assertNotIn("improvement", result.stdout)

    def complete_reports(self, root):
        methods = [("testTranscriptScrollPerformance()", "scroll", 5),
                   ("testStreamingTranscriptFollowPerformance()", "streaming", 3),
                   ("testExternalSidecarTrafficPerformance()", "watcher", 5)]
        metrics, samples = [], []
        for method, workload, count in methods:
            metrics.append({"testIdentifier": method, "testRuns": [{"metrics": [
                {"identifier": name, "displayName": name, "measurements": [1] * count,
                 "unitOfMeasurement": unit}
                for name, unit in [
                    ("com.apple.dt.XCTMetric_CPU-me.haroldmartin.Trace.time", "s"),
                    ("com.apple.dt.XCTMetric_Clock.time.monotonic", "s"),
                    ("com.apple.dt.XCTMetric_Memory-me.haroldmartin.Trace.physical", "kB")]]}]})
            for index in range(count):
                samples.append(dict(id=f"{workload}-{index}", updateCount=3,
                    totalUpdateNanoseconds=400, maximumUpdateNanoseconds=200,
                    startingFootprintBytes=100, sampledPeakFootprintBytes=200,
                    endingFootprintBytes=150, retainedFootprintBytes=125, footprintSampleCount=20))
        (root / "metrics.json").write_text(json.dumps(metrics))
        (root / "app-samples.json").write_text(json.dumps(samples))
        return samples

    def test_counters_and_peak_memory_cannot_replace_required_measurements(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.complete_reports(root)
            path = root / "metrics.json"
            reports = json.loads(path.read_text())
            command = [sys.executable, str(SCRIPTS / "compare-transcript-scroll-metrics.py"),
                       str(path), str(path)]
            reports[0]["testRuns"][0]["metrics"][2]["measurements"][0] = -1
            path.write_text(json.dumps(reports))
            signed = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(signed.returncode, 0, signed.stderr)
            self.assertIn("baseline=[-1,", signed.stdout)
            for original, replacement, expected in [
                (".time", ".instructions_retired", "CPU time"),
                (".time.monotonic", ".time.other", "clock time"),
                (".physical", ".physical_peak", "memory growth"),
            ]:
                damaged = json.loads(json.dumps(reports))
                metrics = damaged[0]["testRuns"][0]["metrics"]
                metric = next(m for m in metrics if m["identifier"].endswith(original))
                metric["identifier"] = metric["identifier"][:-len(original)] + replacement
                path.write_text(json.dumps(damaged))
                failed = subprocess.run(command, capture_output=True, text=True)
                self.assertNotEqual(failed.returncode, 0)
                self.assertIn("Missing required " + expected, failed.stderr)
            reports[0]["testRuns"][0]["metrics"][0]["unitOfMeasurement"] = "ms"
            path.write_text(json.dumps(reports))
            failed = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("Unexpected unit for CPU time", failed.stderr)

    def test_all_workloads_are_summarized_and_missing_memory_or_timings_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            samples = self.complete_reports(root)
            command = [sys.executable, str(SCRIPTS / "compare-transcript-scroll-metrics.py"),
                       str(root / "metrics.json"), str(root / "metrics.json")]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("testStreamingTranscriptFollowPerformance()", result.stdout)
            self.assertIn("testTranscriptScrollPerformance()", result.stdout)
            self.assertIn("testExternalSidecarTrafficPerformance()", result.stdout)
            self.assertIn("retained growth", result.stdout)
            for field in ["sampledPeakFootprintBytes", "totalUpdateNanoseconds"]:
                damaged = [dict(s) for s in samples]
                damaged[0].pop(field)
                (root / "app-samples.json").write_text(json.dumps(damaged))
                failed = subprocess.run(command, capture_output=True, text=True)
                self.assertNotEqual(failed.returncode, 0)
                self.assertIn(field, failed.stderr)
            (root / "app-samples.json").unlink()
            failed = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("Missing memory/timing records", failed.stderr)

    def test_current_harness_is_installed_without_replacing_baseline_production(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("harness", SCRIPTS / "synchronize-benchmark-harness.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            candidate, baseline = Path(directory) / "candidate", Path(directory) / "baseline"
            for name in module.FILES:
                source = candidate / name
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text("current " + name)
            production = baseline / "Sources/TraceApp/MainView.swift"
            production.parent.mkdir(parents=True, exist_ok=True)
            production.write_text("baseline behavior")
            hashes = module.synchronize(candidate, baseline)
            self.assertEqual(set(hashes), set(module.FILES))
            self.assertEqual(production.read_text(), "baseline behavior")
            for name in module.FILES:
                self.assertEqual((candidate / name).read_bytes(), (baseline / name).read_bytes())

    def test_relative_paths_and_xcodebuild_failure_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            caller = root / "caller"
            caller.mkdir()
            binary = root / "bin"
            binary.mkdir()
            arguments = root / "arguments.json"
            fake_build = binary / "xcodebuild"
            fake_build.write_text(f"#!{sys.executable}\n" + """
import json, os, sys
from pathlib import Path
Path(os.environ['TRACE_FAKE_ARGUMENTS']).write_text(json.dumps(sys.argv[1:]))
Path(sys.argv[sys.argv.index('-resultBundlePath') + 1]).mkdir(parents=True)
sys.exit(23)
""")
            fake_build.chmod(0o755)
            fake_export = binary / "xcrun"
            fake_export.write_text("#!/bin/sh\nprintf '{}\\n'\n")
            fake_export.chmod(0o755)
            environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                               TRACE_FAKE_ARGUMENTS=str(arguments),
                               TRACE_SCROLL_BENCHMARK_OUTPUT_DIR="results",
                               TRACE_SCROLL_DERIVED_DATA_PATH="../derived")
            result = subprocess.run([str(SCRIPTS / "measure-transcript-scroll.sh")],
                                    cwd=caller, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 23)
            args = json.loads(arguments.read_text())
            self.assertEqual(Path(args[args.index("-resultBundlePath") + 1]).resolve(),
                             (caller / "results/TranscriptScroll.xcresult").resolve())
            self.assertEqual(Path(args[args.index("-derivedDataPath") + 1]).resolve(),
                             (root / "derived").resolve())
            self.assertTrue((caller / "results/xcodebuild.log").exists())
            self.assertTrue((caller / "results/metrics.json").exists())

    def module(self, name):
        import importlib.util
        spec = importlib.util.spec_from_file_location(name.replace('-', '_'), SCRIPTS / (name + '.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def git(self, root, *args):
        return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL, text=True).strip()

    def baseline_fixture(self, root):
        import shutil
        candidate, baseline = root / 'candidate', root / 'baseline'
        candidate.mkdir()
        for name in self.module('synchronize-benchmark-harness').FILES:
            target = candidate / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('fixture ' + name)
        shutil.copy2(SCRIPTS / 'synchronize-benchmark-harness.py', candidate / 'Scripts/synchronize-benchmark-harness.py')
        for name in ['project.yml', 'Trace.xcodeproj/project.pbxproj', 'Config/Base.xcconfig', 'Sources/TraceApp/MainView.swift']:
            target = candidate / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('baseline')
        self.git(candidate, 'init', '--quiet')
        self.git(candidate, 'add', '.')
        self.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'baseline')
        subprocess.run(['git', 'clone', '--quiet', str(candidate), str(baseline)], check=True)
        return candidate, baseline

    def test_cached_baseline_checks_configuration_untracked_inputs_and_annotated_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate, baseline = self.baseline_fixture(Path(directory))
            validator = self.module('validate-benchmark-baseline')
            self.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'tag', '-a', 'baseline-tag', '-m', 'tag')
            validator.validate(candidate, baseline, 'baseline-tag')
            for name in ['project.yml', 'Trace.xcodeproj/project.pbxproj', 'Config/Base.xcconfig']:
                path = baseline / name
                original = path.read_text()
                path.write_text('unexpected')
                with self.assertRaisesRegex(ValueError, 'unexpected build input'):
                    validator.validate(candidate, baseline, 'baseline-tag')
                path.write_text(original)
            extra = baseline / 'Config/Unexpected.xcconfig'
            extra.write_text('unexpected')
            with self.assertRaisesRegex(ValueError, 'unexpected build input'):
                validator.validate(candidate, baseline, 'baseline-tag')
            extra.unlink()
            (baseline / 'Sources/TraceCore/Diagnostics/TracePerformance.swift').write_text('instrumentation overlay')
            validator.validate(candidate, baseline, 'baseline-tag')

    def test_cached_baseline_rejects_changed_dependency_revision_and_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, baseline = self.baseline_fixture(root)
            dependency = root / 'dependency'
            dependency.mkdir()
            self.git(dependency, 'init', '--quiet')
            (dependency / 'file.c').write_text('first')
            self.git(dependency, 'add', '.')
            self.git(dependency, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'dependency')
            self.git(candidate, '-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet', str(dependency), 'Vendor/Dependency')
            self.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-am', 'module')
            self.git(baseline, 'fetch', '--quiet')
            branch = self.git(candidate, 'symbolic-ref', '--short', 'HEAD')
            self.git(baseline, 'reset', '--hard', 'origin/' + branch)
            self.git(baseline, '-c', 'protocol.file.allow=always', 'submodule', 'update', '--init', '--recursive')
            validator = self.module('validate-benchmark-baseline')
            revision = self.git(candidate, 'rev-parse', 'HEAD')
            validator.validate(candidate, baseline, revision)
            path = baseline / 'Vendor/Dependency/file.c'
            path.write_text('changed')
            with self.assertRaisesRegex(ValueError, 'unexpected build input'):
                validator.validate(candidate, baseline, revision)
            self.git(path.parent, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-am', 'changed')
            with self.assertRaisesRegex(ValueError, 'Dependency revision differs'):
                validator.validate(candidate, baseline, revision)

    def test_exact_sqlite_patch_and_generated_configuration_are_allowed(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, baseline = self.baseline_fixture(root)
            dependency = root / 'dependency'
            (dependency / 'SQLiteCustom/src').mkdir(parents=True)
            self.git(dependency, 'init', '--quiet')
            config = dependency / 'SQLiteCustom/src/SQLiteLib.xcconfig'
            config.write_text('\n' * 9 + '// SQLiteLib targets OS X 10.9\nMACOSX_DEPLOYMENT_TARGET = 10.9\n')
            (dependency / '.gitignore').write_text('*-USER.xcconfig\n*-USER.h\n')
            self.git(dependency, 'add', '.')
            self.git(dependency, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'sqlite')
            self.git(candidate, '-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet', str(dependency), 'Vendor/GRDB.swift')
            patch = candidate / 'GRDBCustomSQLite/SQLiteLib-macOS15.patch'
            patch.parent.mkdir()
            shutil.copy2(SCRIPTS.parent / 'GRDBCustomSQLite/SQLiteLib-macOS15.patch', patch)
            generated = {
                'SQLiteCustom/src/SQLiteLib-USER.xcconfig': 'SQLiteLib-USER.xcconfig',
                'SQLiteCustom/GRDBCustomSQLite-USER.xcconfig': 'GRDBCustomSQLite-USER.xcconfig',
                'SQLiteCustom/GRDBCustomSQLite-USER.h': 'GRDBCustomSQLite-USER.h',
            }
            for name in generated.values(): (patch.parent / name).write_text('configured fixture\n')
            self.git(candidate, 'add', '.')
            self.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'module')
            self.git(baseline, 'fetch', '--quiet')
            self.git(baseline, 'reset', '--hard', self.git(candidate, 'rev-parse', 'HEAD'))
            self.git(baseline, '-c', 'protocol.file.allow=always', 'submodule', 'update', '--init', '--recursive')
            config = baseline / 'Vendor/GRDB.swift/SQLiteCustom/src/SQLiteLib.xcconfig'
            config.write_text(config.read_text().replace('OS X 10.9', 'macOS 15.0').replace('= 10.9', '= 15.0'))
            for output, source in generated.items():
                (baseline / 'Vendor/GRDB.swift' / output).write_bytes((baseline / 'GRDBCustomSQLite' / source).read_bytes())
            validator = self.module('validate-benchmark-baseline')
            revision = self.git(candidate, 'rev-parse', 'HEAD')
            validator.validate(candidate, baseline, revision)
            user_config = baseline / 'Vendor/GRDB.swift/SQLiteCustom/src/SQLiteLib-USER.xcconfig'
            relative = subprocess.run([sys.executable, str(SCRIPTS / 'validate-benchmark-baseline.py'),
                                       '.', '../baseline', revision], cwd=candidate, capture_output=True, text=True)
            self.assertEqual(relative.returncode, 0, relative.stderr)
            user_config.write_text('unexpected configuration\n')
            with self.assertRaisesRegex(ValueError, 'Unexpected generated dependency configuration'):
                validator.validate(candidate, baseline, revision)
            user_config.write_text('configured fixture\n')
            config.write_text(config.read_text() + 'UNEXPECTED = YES\n')
            with self.assertRaisesRegex(ValueError, 'Unexpected SQLite configuration patch'):
                validator.validate(candidate, baseline, revision)

    def test_comparison_reruns_use_fresh_directories_and_preserve_occupied_output(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, baseline = self.baseline_fixture(root)
            scripts = candidate / 'Scripts'
            for name in ['benchmark-transcript-comparison.sh', 'validate-benchmark-baseline.py', 'compare-transcript-scroll-metrics.py']:
                shutil.copy2(SCRIPTS / name, scripts / name)
            (scripts / 'configure-grdb.sh').write_text('#!/bin/sh\nexit 0\n')
            fixture = root / 'fixture'
            fixture.mkdir()
            self.complete_reports(fixture)
            measure = scripts / 'measure-transcript-scroll.sh'
            measure.write_text('#!/bin/sh\nmkdir -p "$TRACE_SCROLL_BENCHMARK_OUTPUT_DIR"\n'
                               'cp "$TRACE_FAKE_FIXTURE"/*.json "$TRACE_SCROLL_BENCHMARK_OUTPUT_DIR/"\n')
            for path in scripts.iterdir(): path.chmod(0o755)
            self.git(candidate, 'add', '.')
            self.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'harness')
            self.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'tag', '-a', 'baseline-tag', '-m', 'tag')
            self.git(baseline, 'fetch', '--quiet')
            self.git(baseline, 'reset', '--hard', self.git(candidate, 'rev-parse', 'HEAD'))
            binary = root / 'bin'
            binary.mkdir()
            for name in ['sw_vers', 'xcodebuild', 'swift', 'uname', 'sysctl']:
                target = binary / name
                target.write_text('#!/bin/sh\nprintf "fixture\\n"\n')
                target.chmod(0o755)
            output = root / 'occupied'
            output.mkdir()
            (output / 'metadata.json').write_text('historical')
            (output / 'candidate').mkdir()
            (output / 'candidate/TranscriptScroll.xcresult').mkdir()
            environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                TRACE_SCROLL_COMPARISON_OUTPUT_DIR=str(output), TRACE_SCROLL_BASELINE_CHECKOUT=str(baseline),
                TRACE_SCROLL_BASELINE_REF='baseline-tag', TRACE_FAKE_FIXTURE=str(fixture))
            for _ in range(2):
                result = subprocess.run([str(scripts / 'benchmark-transcript-comparison.sh')], env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            runs = list((output / 'runs').iterdir())
            self.assertEqual(len(runs), 2)
            self.assertEqual((output / 'metadata.json').read_text(), 'historical')
            for run in runs:
                self.assertTrue((run / 'comparison.txt').exists())
                self.assertTrue((run / 'candidate/app-samples.json').exists())
                self.assertEqual(json.loads((run / 'metadata.json').read_text())['baseline_commit'], self.git(candidate, 'rev-parse', 'baseline-tag^{commit}'))

    def test_local_runner_preserves_build_failure_and_stops_before_acceptance(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, _ = self.baseline_fixture(root)
            command = candidate / 'Scripts/benchmark-transcript-comparison.sh'
            command.write_text('#!/bin/sh\nmkdir -p "$TRACE_SCROLL_COMPARISON_OUTPUT_DIR/runs/run-failed"\n'
                               'printf "build failed\\n"\nexit 23\n')
            command.chmod(0o755)
            self.git(candidate, 'add', '.')
            self.git(candidate, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'failing build')
            runner = self.module('run-local-benchmark-comparisons')
            output = root / 'local-results'
            with patch.object(runner, 'wait_for_quiet'), patch.object(runner, 'competitors', return_value=[]):
                with self.assertRaisesRegex(SystemExit, r'Comparison failed \(23\)'):
                    runner.run(candidate, output)
            host = json.loads(next(output.glob('*/runs/*/host-session-check.json')).read_text())
            self.assertEqual(host['processExitCode'], 23)
            self.assertIn('build failed', (output / 'pair-1-attempt-1.log').read_text())
            self.assertFalse((output / 'local-acceptance.json').exists())

    def local_pairs(self, root):
        checker = self.module('check-local-benchmark-regressions')
        pairs = []
        for index, order in enumerate(checker.ORDERS):
            pair = root / str(index)
            pair.mkdir()
            for revision in ['baseline', 'candidate']:
                target = pair / revision
                target.mkdir()
                self.complete_reports(target)
            (pair / 'metadata.json').write_text(json.dumps(dict(locale='en_US', baseline_commit=checker.BASELINE,
                candidate_commit='frozen', order=order, toolchain={'fixture': True}, identical_harness_files={'fixture': 'equal'})))
            (pair / 'host-session-check.json').write_text(json.dumps(dict(valid=True, competingSessionObservations=[])))
            pairs.append(pair)
        return checker, pairs

    def test_local_acceptance_enforces_median_tolerance_and_preserves_signed_growth(self):
        with tempfile.TemporaryDirectory() as directory:
            checker, pairs = self.local_pairs(Path(directory))
            for pair in pairs:
                path = pair / 'candidate/metrics.json'
                reports = json.loads(path.read_text())
                reports[0]['testRuns'][0]['metrics'][0]['measurements'] = [1.12] * 5
                reports[0]['testRuns'][0]['metrics'][2]['measurements'] = [-1] * 5
                path.write_text(json.dumps(reports))
            report = checker.evaluate(pairs)
            self.assertEqual(report['status'], 'failed')
            self.assertEqual(report['pairs'][0]['workloads']['scroll']['hardwareCounterAvailability']['baseline'],
                             {'cycles': 'not-exported', 'instructions': 'not-exported'})
            self.assertTrue(any(r['metric'] == 'cpuSeconds' for r in report['regressions']))
            self.assertFalse(any(r['metric'] == 'xctestGrowthBytes' for r in report['regressions']))
            # Ordinary comparison remains report-only for valid regression records.
            result = subprocess.run([sys.executable, str(SCRIPTS / 'compare-transcript-scroll-metrics.py'),
                str(pairs[0] / 'baseline/metrics.json'), str(pairs[0] / 'candidate/metrics.json')], capture_output=True)
            self.assertEqual(result.returncode, 0)
            for pair in pairs[:2]:
                path = pair / 'candidate/metrics.json'
                reports = json.loads(path.read_text())
                reports[0]['testRuns'][0]['metrics'][0]['measurements'] = [1.1] * 5
                path.write_text(json.dumps(reports))
            self.assertEqual(checker.evaluate(pairs)['status'], 'passed', 'exactly 10% is within tolerance')
            for pair in pairs[:2]:
                path = pair / 'candidate/metrics.json'
                reports = json.loads(path.read_text())
                reports[0]['testRuns'][0]['metrics'][0]['measurements'] = [1.05] * 5
                path.write_text(json.dumps(reports))
            self.assertEqual(checker.evaluate(pairs)['status'], 'passed')
            (pairs[1] / 'candidate/app-samples.json').unlink()
            with self.assertRaises(subprocess.CalledProcessError): checker.evaluate(pairs)

    def test_local_acceptance_rejects_memory_growth_drift_and_wrong_order(self):
        with tempfile.TemporaryDirectory() as directory:
            checker, pairs = self.local_pairs(Path(directory))
            for pair in pairs:
                path = pair / 'candidate/app-samples.json'
                samples = json.loads(path.read_text())
                for index, sample in enumerate(samples):
                    if sample['id'].startswith('scroll-'): sample['retainedFootprintBytes'] += index * 20
                path.write_text(json.dumps(samples))
            report = checker.evaluate(pairs)
            self.assertTrue(any(r['metric'] == 'retainedDriftBytes' for r in report['regressions']))
            self.assertTrue(any(r['metric'] == 'retainedGrowthBytes' for r in report['regressions']))
            path = pairs[1] / 'metadata.json'
            metadata = json.loads(path.read_text()); metadata['order'] = ['baseline', 'candidate']
            path.write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError, 'revision order'): checker.evaluate(pairs)

    def test_measurement_rejects_existing_bundle_without_overwriting_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'TranscriptScroll.xcresult').mkdir()
            sentinel = root / 'xcodebuild.log'
            sentinel.write_text('prior evidence')
            result = subprocess.run([str(SCRIPTS / 'measure-transcript-scroll.sh')],
                env=dict(os.environ, TRACE_SCROLL_BENCHMARK_OUTPUT_DIR=str(root)), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Refusing to reuse', result.stderr)
            self.assertEqual(sentinel.read_text(), 'prior evidence')


if __name__ == "__main__":
    unittest.main()
