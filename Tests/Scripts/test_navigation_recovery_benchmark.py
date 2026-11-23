import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import re

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
            # The extracted resolver and its fixture must agree on every state
            # field it writes, including genuine reader failures after lookup.
            assigned = set(re.findall(r"\$0\.(\w+)\s*=(?!=)", output.read_text()))
            state = re.search(r"struct TranscriptState \{([^}]+)\}", MODULE.HEADER).group(1)
            declared = set(re.findall(r"var (\w+)", state))
            self.assertTrue(assigned <= declared, f"Fixture lacks resolver state: {assigned - declared}")

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
        self.assertIn("intervals.measure { ledger.benchmarkObserve(initial, work: enrolled) }", source)
        self.assertIn("intervals.measure { ledger.benchmarkObserve(accepted, work: delivered) }", source)
        validation = source.index('let unfinished = ledger.benchmarkCounts')
        self.assertLess(source.index('if let observation { await observation.value }'), validation)
        self.assertLess(validation, source.index('let accepted = half > 0'))
        self.assertIn("overlapping spans counted once", source)
        self.assertIn("admissions = nil; names = nil", source)

    def test_execution_intervals_count_overlap_once_and_exclude_control_gaps(self):
        source = (ROOT / "Scripts/benchmark-navigation-recovery.swift").read_text()
        start = source.index("private final class ExecutionIntervals:")
        end = source.index("private actor LedgerStart", start)
        helper = source[start:end]
        with tempfile.TemporaryDirectory() as tmp:
            probe = Path(tmp) / "intervals.swift"
            probe.write_text("import Foundation\nimport os\nfunc processCPU() -> Double { 0 }\n" + helper + r'''
let clock = OSAllocatedUnfairLock(initialState: (wall: 0.0, cpu: 0.0))
private let spans = ExecutionIntervals(now: { clock.withLock { $0.wall } }, cpu: { clock.withLock { $0.cpu } })
func advance(_ wall: Double, _ cpu: Double) { clock.withLock { $0.wall += wall; $0.cpu += cpu } }
advance(100, 100) // Release/setup before an early observer starts.
spans.begin(); advance(2, 1)
spans.begin(); advance(3, 2) // Concurrent admission; overlap counts once.
spans.end(); advance(4, 3); spans.end()
advance(200, 200) // Correctness checks and awaited control gaps count zero.
spans.measure { advance(5, 4) }
let result = spans.snapshot
precondition(result.elapsed == 14 && result.cpu == 10 && result.intervals == 2)
print("14.0 10.0 2")
''')
            result = subprocess.run(["xcrun", "swift", str(probe)], check=True, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.stdout.strip(), "14.0 10.0 2")

    def test_legacy_fixture_synchronization_is_explicit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ["Sources/TraceApp/TraceModel.swift", "Sources/TraceCore/Models.swift"]:
                target = root / name; target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            models = root / "Sources/TraceCore/Models.swift"
            models.write_text(models.read_text().replace(MODULE.FACTORY, MODULE.LEGACY_FACTORY))
            output = root / "resolver.swift"
            with self.assertRaisesRegex(ValueError, "synchronize-existing"):
                MODULE.prepare(root, output)
            MODULE.prepare(root, output, synchronize_existing=True)
            self.assertEqual(models.read_text().count(MODULE.FACTORY), 1)
            self.assertIn("benchmarkSharedFixture", models.read_text())
            MODULE.prepare(root, output)
