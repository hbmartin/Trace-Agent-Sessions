import importlib.util
from pathlib import Path
import shutil
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
