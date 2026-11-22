import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("navigation_benchmark", ROOT / "Scripts/prepare-navigation-recovery-benchmark.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

class NavigationRecoveryBenchmarkTests(unittest.TestCase):
    def test_fixture_is_idempotent_and_resolver_is_extracted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ["Sources/TraceApp/TraceModel.swift", "Sources/TraceCore/Models.swift"]:
                target = root / name; target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            output = root / "resolver.swift"
            MODULE.prepare(root, output)
            first = (root / "Sources/TraceCore/Models.swift").read_text()
            MODULE.prepare(root, output)
            self.assertEqual(first, (root / "Sources/TraceCore/Models.swift").read_text())
            self.assertEqual(first.count("public static func benchmarkFixture("), 1)
            self.assertIn("snapshotReads += 1", output.read_text())
            self.assertIn("pending.demand != demand", output.read_text())

    def test_workload_keeps_setup_and_correctness_outside_measurement(self):
        source = (ROOT / "Scripts/benchmark-navigation-recovery.swift").read_text()
        self.assertLess(source.index("let beforeFixtures = memoryBytes()"), source.index("let database ="))
        self.assertIn("resolver = nil", source)
        self.assertIn("processCPUDefinition", source)

    def test_nearest_rank_percentile_uses_one_based_rank(self):
        source = (ROOT / "Scripts/benchmark-navigation-recovery.swift").read_text()
        start = source.index("func nearestRankPercentile(")
        end = source.index("\n}", start) + 2
        with tempfile.TemporaryDirectory() as tmp:
            probe = Path(tmp) / "percentile.swift"
            probe.write_text("import Foundation\n" + source[start:end] + '\nfor n in [1, 20, 100] { print(Int(nearestRankPercentile((1...n).map(Double.init), fraction: 0.95))) }\n')
            result = subprocess.run(["xcrun", "swift", str(probe)], check=True, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.stdout.splitlines(), ["1", "19", "95"])

    def test_ledger_adapter_rejects_conflicting_instrumentation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ["Sources/TraceApp/TraceModel.swift", "Sources/TraceCore/Models.swift"]:
                target = root / name; target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            output = root / "resolver.swift"
            MODULE.prepare(root, output)
            models = root / "Sources/TraceCore/Models.swift"
            models.write_text(models.read_text().replace("CheckpointAcceptanceBenchmark.end(stamp)", "CheckpointAcceptanceBenchmark.reset()"))
            with self.assertRaisesRegex(ValueError, "Conflicting navigation ledger"):
                MODULE.prepare(root, output)

    def test_ledger_measurements_have_explicit_modes_and_thread_cpu(self):
        source = (ROOT / "Scripts/benchmark-navigation-recovery.swift").read_text()
        for value in ["ledger-short", "ledger-long", "contention-short", "contention-long"]:
            self.assertIn(value, source)
        self.assertIn("Same worker thread", source)
        self.assertLess(source.index("await gate.release()"), source.index("let startCPU = processCPU(), start = ContinuousClock.now", source.index("await gate.release()")))
        self.assertIn("admissions = nil; names = nil", source)
