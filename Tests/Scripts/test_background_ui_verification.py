import importlib.util
import json
from pathlib import Path
import tempfile
import sys
import unittest
import os
import signal
import subprocess
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("background_ui", ROOT / "Scripts/run-selected-ui-verification.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BackgroundUIVerificationTests(unittest.TestCase):
    def test_malformed_summaries_and_discovery_fail_with_schema_errors(self):
        for summary in [[], None, "text", {"passedTests": "one"}, {"passedTests": True},
                        {"passedTests": 1, "failedTests": -1}]:
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                module.require_executed(summary)
        for catalog in [[], {"values": "text"}, {"values": [{"kind": "test", "name": 1}]}]:
            with self.subTest(catalog=catalog), self.assertRaises(ValueError):
                module.discovered_identifiers(catalog)

    def invoke(self, output, exports=None, *, selection="Tests/Verification/ui-smoke.json", timeout=360, inputs=None):
        exports = iter(exports or [{"passedTests": 1}, {"passedTests": 1}])
        selectors = module.load_selection(ROOT / "Tests/Verification/ui-smoke.json")
        def command(runner, label, args, watchdog):
            if label in ("toolchain", "macOS"):
                (runner.output / (label + ".log")).write_text("fixture")
            elif label == "discovery":
                Path(args[-1]).write_text(json.dumps({"values": [{"kind": "target", "name": "TraceUITests", "children": [
                    {"kind": "class", "name": "TraceUITests", "children": [
                        {"kind": "test", "name": item.split("/")[-1] + "()"} for item in selectors]}]}]}))
            elif label.endswith("-export"):
                value = next(exports)
                if isinstance(value, BaseException):
                    raise value
                (runner.output / (label + ".log")).write_text(json.dumps(value))
            elif label.startswith("ui-"):
                Path(args[args.index("-resultBundlePath") + 1]).mkdir()
            return 0
        values = inputs or [{"revision": "fixture"}] * 2
        with patch.object(sys, "argv", ["runner", "--selection", selection, "--output", str(output),
                                       "--test-timeout", str(timeout)]), \
             patch.dict(os.environ, {"CI": "false", "GITHUB_ACTIONS": "false"}), \
             patch.object(module, "capture_inputs", side_effect=values), \
             patch.object(module.subprocess, "check_output", return_value="fixture"), \
             patch.object(module.Runner, "command", command):
            return module.main()

    def test_export_timeout_or_missing_tool_records_case_and_continues(self):
        for failure in [subprocess.TimeoutExpired("xcrun", 60), FileNotFoundError("missing xcrun")]:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "attempt"
                self.assertEqual(self.invoke(output, [failure, {"passedTests": 1}]), 1)
                receipt = json.loads((output / "verification.json").read_text())
                self.assertEqual(receipt["status"], "failed")
                self.assertEqual(len(receipt["tests"]), 2)
                self.assertFalse(receipt["tests"][0]["passed"])
                self.assertTrue(receipt["tests"][1]["passed"])
                self.assertIn(type(failure).__name__, receipt["tests"][0]["error"])
                self.assertFalse((output / "ui-001-summary.json").exists())

    def test_invalid_summary_cannot_leave_running_receipt_or_skip_successor(self):
        for summary in [[], {"passedTests": "one"}]:
            with self.subTest(summary=summary), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "attempt"
                self.assertEqual(self.invoke(output, [summary, {"passedTests": 1}]), 1)
                receipt = json.loads((output / "verification.json").read_text())
                self.assertEqual(receipt["status"], "failed")
                self.assertEqual([t["status"] for t in receipt["tests"]], ["failed", "passed"])

    def test_sigterm_and_keyboard_interrupt_finalize_the_active_case(self):
        for error, code in [(module.RunInterrupted(signal.SIGTERM), 143), (KeyboardInterrupt(), 130)]:
            with self.subTest(error=error), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "attempt"
                self.assertEqual(self.invoke(output, [error]), code)
                receipt = json.loads((output / "verification.json").read_text())
                self.assertEqual(receipt["status"], "interrupted")
                self.assertEqual(receipt["tests"][0]["status"], "interrupted")
                self.assertTrue(receipt["error"])

    def test_setup_failure_and_short_watchdog_leave_receipts(self):
        for kwargs in [{"selection": "Tests/Verification/mistyped.json"}, {"timeout": 30}]:
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "attempt"
                self.assertEqual(self.invoke(output, **kwargs), 1)
                receipt = json.loads((output / "verification.json").read_text())
                self.assertEqual(receipt["status"], "failed")
                self.assertTrue(receipt["error"])
                self.assertEqual(receipt["phases"], [])

    def test_relative_output_uses_invocation_directory_and_restores_cwd(self):
        original = Path.cwd()
        with tempfile.TemporaryDirectory() as temp:
            try:
                os.chdir(temp)
                self.assertEqual(self.invoke(Path("attempt")), 0)
                self.assertEqual(Path.cwd(), Path(temp).resolve())
                self.assertTrue((Path(temp) / "attempt/verification.json").exists())
            finally:
                os.chdir(original)

    def test_input_change_rejects_otherwise_successful_verification(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "attempt"
            self.assertEqual(self.invoke(output, inputs=[{"revision": "a"}, {"revision": "b"}]), 1)
            receipt = json.loads((output / "verification.json").read_text())
            self.assertFalse(receipt["inputsUnchanged"])
            self.assertEqual(receipt["status"], "failed")

    def test_actual_dirty_and_untracked_input_bytes_are_recorded(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)
            git("init")
            (root / "Sources").mkdir()
            source = root / "Sources/main.swift"
            source.write_text("let value = 1")
            git("add", ".")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture")
            before = module.capture_inputs(root)
            source.write_text("let value = 2")
            (root / "Sources/new.swift").write_text("let extra = 3")
            after = module.capture_inputs(root)
            self.assertEqual(before["revision"], after["revision"])
            self.assertNotEqual(before["files"]["Sources/main.swift"], after["files"]["Sources/main.swift"])
            self.assertNotEqual(before["trackedDiffSHA256"], after["trackedDiffSHA256"])
            self.assertIn("Sources/new.swift", after["untrackedInputs"])

    def test_real_sigterm_joins_child_and_records_interruption(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "attempt"
            code = """
import importlib.util,pathlib,signal,sys
spec=importlib.util.spec_from_file_location('runner',sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
r=m.Runner(pathlib.Path(sys.argv[2]),{})
def stop(signum,frame):raise m.RunInterrupted(signum)
signal.signal(signal.SIGTERM,stop)
try:r.command('held',[sys.executable,'-c','import os,time;print(os.getpid(),flush=True);time.sleep(30)'],40)
except m.RunInterrupted as e:
 r.receipt.update(status='interrupted',error=str(e));r.save();sys.exit(128+e.signum)
"""
            child = subprocess.Popen([sys.executable, "-c", code, str(ROOT / "Scripts/run-selected-ui-verification.py"), str(output)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 5
                log = output / "held.log"
                while not log.exists() or not log.read_text().strip():
                    if time.monotonic() > deadline:
                        self.fail("The held subprocess did not start")
                    time.sleep(.01)
                held_pid = int(log.read_text().strip())
                child.send_signal(signal.SIGTERM)
                stdout, stderr = child.communicate(timeout=5)
                self.assertEqual(child.returncode, 143, stdout + stderr)
                receipt = json.loads((output / "verification.json").read_text())
                self.assertEqual(receipt["status"], "interrupted")
                self.assertEqual(receipt["phases"][0]["status"], "interrupted")
                self.assertIn("SIGTERM", receipt["error"])
                with self.assertRaises(ProcessLookupError):
                    os.kill(held_pid, 0)
            finally:
                if child.poll() is None:
                    child.send_signal(signal.SIGTERM)
                    child.communicate(timeout=5)

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
