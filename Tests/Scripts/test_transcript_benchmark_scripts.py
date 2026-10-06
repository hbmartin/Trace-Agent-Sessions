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


if __name__ == "__main__":
    unittest.main()
