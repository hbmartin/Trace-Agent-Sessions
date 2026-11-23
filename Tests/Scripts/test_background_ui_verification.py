import importlib.util
import json
from pathlib import Path
import tempfile
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("background_ui", ROOT / "Scripts/run-selected-ui-verification.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BackgroundUIVerificationTests(unittest.TestCase):
    def selection(self, value):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "selection.json"
            path.write_text(json.dumps(value))
            return module.load_selection(path)

    def test_ci_environments_are_rejected(self):
        for env in [{"CI": "true"}, {"CI": "1"}, {"GITHUB_ACTIONS": "true"}, {"GITHUB_ACTIONS": "TRUE"}]:
            with self.subTest(environment=env), self.assertRaisesRegex(ValueError, "local-only"):
                module.require_local_execution(env)
        module.require_local_execution({})
        module.require_local_execution({"CI": "false", "GITHUB_ACTIONS": "false"})

    def test_ci_has_no_ui_execution_entrypoints(self):
        directory = ROOT / ".github/workflows"
        self.assertFalse((directory / "background-ui-verification.yml").exists())
        self.assertFalse((directory / "transcript-scroll-benchmark.yml").exists())
        for path in directory.glob("*.yml"):
            text = path.read_text()
            for forbidden in ["-only-testing:TraceUITests", "-only-testing:TracePerformanceTests",
                              "run-selected-ui-verification.py", "benchmark-transcript-comparison.sh",
                              "measure-transcript-scroll.sh"]:
                self.assertNotIn(forbidden, text, str(path))
        text = (directory / "ci.yml").read_text()
        self.assertIn("-only-testing:TraceCoreTests", text)
        self.assertIn("-only-testing:TraceAppTests", text)
        self.assertIn("TraceExternalClientFixture", text)

    def test_exact_nonempty_selection(self):
        self.assertEqual(self.selection(["TraceUITests/TraceUITests/testExample"]),
                         ["TraceUITests/TraceUITests/testExample"])

    def test_empty_duplicate_and_broad_selection_rejected(self):
        for values in [[], {}, ["TraceUITests"], ["-skip-testing:TraceUITests"], [1],
                       ["TraceUITests/TraceUITests/testA"] * 2]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.selection(values)

    def test_compiled_discovery_uses_target_class_and_method(self):
        catalog = {"values": [{"kind": "plan", "name": "Trace", "children": [
            {"kind": "target", "name": "TraceUITests", "children": [
                {"kind": "class", "name": "TraceUITests", "children": [
                    {"kind": "test", "name": "testExample()"}]}]}]}]}
        self.assertEqual(module.discovered_identifiers(catalog), {"TraceUITests/TraceUITests/testExample"})

    def test_zero_or_skipped_tests_cannot_count_as_passed(self):
        for summary in [{}, {"passedTests": 0}, {"passedTests": 1, "failedTests": 1},
                        {"passedTests": 1, "skippedTests": 1}]:
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                module.require_executed(summary)
        module.require_executed({"passedTests": 1, "failedTests": 0, "skippedTests": 0})

    def test_output_cannot_overwrite_historical_attempt(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(FileExistsError):
                module.Runner(Path(temp), {})

    def test_command_failure_is_retained(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "attempt"
            runner = module.Runner(output, {"revision": "fixture"})
            code = runner.command("failure", ["/bin/sh", "-c", "echo detail; exit 7"], 5)
            self.assertEqual(code, 7)
            receipt = json.loads((output / "verification.json").read_text())
            self.assertEqual(receipt["phases"][0]["status"], "failed")
            self.assertIn("detail", (output / "failure.log").read_text())

    def test_timeout_terminates_command_and_preserves_receipt(self):
        with tempfile.TemporaryDirectory() as temp:
            runner = module.Runner(Path(temp) / "attempt", {})
            self.assertEqual(runner.command("timeout", [sys.executable, "-c", "import time; time.sleep(30)"], .05), 124)
            self.assertEqual(runner.receipt["phases"][0]["status"], "timeout")

    def test_launch_failure_does_not_leave_running_phase(self):
        with tempfile.TemporaryDirectory() as temp:
            runner = module.Runner(Path(temp) / "attempt", {})
            with self.assertRaises(FileNotFoundError):
                runner.command("launch", [str(Path(temp) / "missing")], 1)
            self.assertEqual(runner.receipt["phases"][0]["status"], "launch-failed")


if __name__ == "__main__":
    unittest.main()
