import importlib.util
import json
import plistlib
import re
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
    def products(self, derived):
        products = derived / "Build/Products"
        for name in ("Trace.app", "TraceUITests-Runner.app"):
            path = products / "Debug" / name / "Contents/MacOS/executable"
            path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b"fixture executable")
        (products/"Debug/TraceUITests-Runner.app/Contents/PlugIns/TraceUITests.xctest").mkdir(parents=True, exist_ok=True)
        manifest = products / "Trace_macosxfixture-arm64.xctestrun"
        manifest.write_bytes(plistlib.dumps({"TraceUITests": {"IsUITestBundle": True,
            "TestHostPath": "__TESTROOT__/Debug/TraceUITests-Runner.app", "UITargetAppPath": "__TESTROOT__/Debug/Trace.app", "TestBundlePath": "__TESTHOST__/Contents/PlugIns/TraceUITests.xctest"},
            "TraceCoreTests": {}, "TraceAppTests": {}}))
        return manifest

    def context(self):
        return {"configuration": "Debug", "architecture": "arm64", "sdk": "fixture", "toolchain": "fixture",
                "developerDirectory": os.environ.get("DEVELOPER_DIR", "default")}

    def test_malformed_summaries_and_discovery_fail_with_schema_errors(self):
        for summary in [[], None, "text", {"passedTests": "one"}, {"passedTests": True},
                        {"passedTests": 1, "failedTests": -1}]:
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                module.require_executed(summary)
        for catalog in [[], {"values": "text"}, {"values": [{"kind": "test", "name": 1}]}]:
            with self.subTest(catalog=catalog), self.assertRaises(ValueError):
                module.discovered_identifiers(catalog)

    def invoke(self, output, exports=None, *, selection="Tests/Verification/ui-smoke.json", timeout=360, inputs=None, derived=None, commands=None):
        exports = iter(exports or [{"passedTests": 1}, {"passedTests": 1}])
        selectors = module.load_selection(ROOT / "Tests/Verification/ui-smoke.json")
        def command(runner, label, args, watchdog):
            if commands is not None: commands.append((label, args))
            if label in ("toolchain", "macOS"):
                (runner.output / (label + ".log")).write_text("fixture")
            elif label == "build":
                self.products(Path(runner.receipt["derivedData"]))
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
        if derived is None: values = [values[0], values[0], values[-1]]
        with patch.object(sys, "argv", ["runner", "--selection", selection, "--output", str(output),
                                       "--test-timeout", str(timeout)] + (["--derived-data", str(derived)] if derived is not None else [])), \
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
                subprocess.run(["git", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", *args], cwd=root, check=True, capture_output=True)
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
        for path in list(directory.glob("*.yml")) + list(directory.glob("*.yaml")):
            self.assert_noninteractive_workflow(path.read_text())
        text = (directory / "ci.yml").read_text()
        self.assertIn("-only-testing:TraceCoreTests", text)
        self.assertIn("-only-testing:TraceAppTests", text)
        self.assertIn("TraceExternalClientFixture", text)

    def assert_noninteractive_workflow(self, text):
        for forbidden in ["-only-testing:TraceUITests", "-only-testing:TracePerformanceTests",
                          "run-selected-ui-verification.py", "benchmark-transcript-comparison.sh", "measure-transcript-scroll.sh"]:
            self.assertNotIn(forbidden, text)
        # Fold shell continuations and YAML folded run blocks, then examine each
        # xcodebuild invocation independently. Builds alone do not execute tests.
        text = text.replace("\\\n", " ")
        invocations = re.findall(r"\bxcodebuild\b[^\n]*(?:\n[ \t]{10,}(?!xcodebuild\b)[^\n]*)*", text)
        for command in invocations:
            if not re.search(r"\btest(?:-without-building)?\b", command): continue
            selected = re.findall(r"-only-testing:([^\s]+)", command)
            self.assertTrue(selected, "Every CI test invocation requires an explicit Core/App selection")
            self.assertTrue(all(v.split('/')[0] in ("TraceCoreTests", "TraceAppTests") for v in selected), command)

    def test_ci_policy_rejects_broad_commands_and_yaml_workflows(self):
        for text in ["run: xcodebuild test -scheme Trace", "run: xcodebuild test-without-building -scheme Trace",
                     "run: xcodebuild test -only-testing:TraceUITests", "run: python3 Scripts/run-selected-ui-verification.py"]:
            with self.subTest(text=text), self.assertRaises(AssertionError): self.assert_noninteractive_workflow(text)
        self.assert_noninteractive_workflow("run: xcodebuild test -only-testing:TraceCoreTests -only-testing:TraceAppTests")
        self.assert_noninteractive_workflow("run: xcodebuild build -scheme Trace")

    def test_reuse_is_read_only_and_relative_to_invocation(self):
        original = Path.cwd()
        with tempfile.TemporaryDirectory() as temp:
            try:
                os.chdir(temp)
                derived = Path("prepared"); products = derived / "Build/Products"; products.mkdir(parents=True)
                manifest = self.products(derived)
                payload = manifest.read_bytes()
                module.record_preparation(derived, {"revision": "fixture"}, self.context())
                commands = []
                self.assertEqual(self.invoke(Path("attempt"), derived=derived, commands=commands), 0)
                receipt = json.loads(Path("attempt/verification.json").read_text())
                self.assertEqual(receipt["buildMode"], "reuse-only")
                self.assertEqual(receipt["derivedData"], str(derived.resolve()))
                self.assertTrue(receipt["preparedManifestsUnchanged"])
                self.assertNotIn("build", [label for label, _ in commands])
                self.assertEqual(manifest.read_bytes(), payload)
                self.assertIn("TraceCoreTests", plistlib.loads(manifest.read_bytes()))
            finally: os.chdir(original)

    def test_missing_prepared_products_fail_without_rebuild(self):
        with tempfile.TemporaryDirectory() as temp:
            commands = []
            self.assertEqual(self.invoke(Path(temp)/"attempt", derived=Path(temp)/"missing", commands=commands), 1)
            self.assertNotIn("build", [label for label, _ in commands])
            self.assertFalse(any(label.startswith("ui-") for label, _ in commands))

    def test_prepared_provenance_rejects_stale_binary_context_and_native_inputs(self):
        with tempfile.TemporaryDirectory() as temp:
            derived = Path(temp)/"derived"; manifest = self.products(derived)
            inputs = {"revision": "A", "files": {"Sources/main.swift": {"sha256": "A"}, "docs/README.md": {"sha256": "A"}}}
            with self.assertRaisesRegex(ValueError, "provenance is missing"):
                module.verify_preparation(derived, inputs, self.context())
            module.record_preparation(derived, inputs, self.context())
            equivalent = {"revision": "B", "files": {**inputs["files"], "docs/README.md": {"sha256": "B"}}}
            self.assertEqual(module.verify_preparation(derived, equivalent, self.context())["revision"], "A")
            with self.assertRaisesRegex(ValueError, "native inputs"):
                module.verify_preparation(derived, {"revision": "B", "files": {"Sources/main.swift": {"sha256": "B"}}}, self.context())
            with self.assertRaisesRegex(ValueError, "configuration"):
                module.verify_preparation(derived, inputs, {**self.context(), "configuration": "Release"})
            executable = derived/"Build/Products/Debug/Trace.app/Contents/MacOS/executable"
            executable.write_bytes(b"rebuilt behind unchanged manifest")
            with self.assertRaisesRegex(ValueError, "hashes changed"):
                module.verify_preparation(derived, inputs, self.context())
            value = plistlib.loads(manifest.read_bytes());value["TraceUITests"]["TestHostPath"] = "__TESTROOT__/Release/TraceUITests-Runner.app"
            manifest.write_bytes(plistlib.dumps(value))
            with self.assertRaisesRegex(ValueError, "Debug configuration"):
                module.prepared_manifest(derived, "fixture")

    def test_prepared_provenance_is_relocatable_and_rejects_legacy_format(self):
        import shutil
        with tempfile.TemporaryDirectory() as temp:
            original, relocated = Path(temp)/"original", Path(temp)/"relocated"
            self.products(original)
            inputs = {"revision": "fixture"}
            module.record_preparation(original, inputs, self.context())
            shutil.copytree(original, relocated)
            self.assertEqual(module.product_hashes(original), module.product_hashes(relocated))
            self.assertEqual(module.verify_preparation(relocated, inputs, self.context())["format"], 2)
            provenance = relocated/module.PREPARATION_RECEIPT
            value = json.loads(provenance.read_text()); value["format"] = 1
            provenance.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "reprepare"):
                module.verify_preparation(relocated, inputs, self.context())

    def test_product_hashing_streams_large_files(self):
        import hashlib
        with tempfile.TemporaryDirectory() as temp:
            derived = Path(temp)/"derived"; self.products(derived)
            payload = derived/"Build/Products/Debug/large"
            data = b"payload" * 400000; payload.write_bytes(data)
            with patch.object(Path, "read_bytes", side_effect=AssertionError("whole file read")):
                observed = module.product_hashes(derived)
            self.assertEqual(observed["products"]["Debug/large"]["sha256"], hashlib.sha256(data).hexdigest())

    def test_final_inventory_exception_still_saves_and_restores_process_state(self):
        with tempfile.TemporaryDirectory() as temp:
            derived=Path(temp)/"derived";self.products(derived)
            module.record_preparation(derived,{"revision":"fixture"},self.context())
            original = module.finalize_verification
            def finalize(*args, **kwargs):
                with patch.object(module, "product_hashes", side_effect=PermissionError("final inventory denied")):
                    return original(*args, **kwargs)
            cwd=Path.cwd();handlers={s:signal.getsignal(s) for s in (signal.SIGINT,signal.SIGTERM)}
            with patch.object(module, "finalize_verification", side_effect=finalize):
                self.assertEqual(self.invoke(Path(temp)/"attempt",derived=derived),1)
            receipt=json.loads((Path(temp)/"attempt/verification.json").read_text())
            self.assertEqual(receipt["status"],"failed");self.assertIn("denied",str(receipt["finalizationErrors"]))
            self.assertEqual(Path.cwd(),cwd)
            self.assertTrue(all(signal.getsignal(s)==h for s,h in handlers.items()))

    def test_final_receipt_write_failure_or_signal_preserves_failure_and_restores(self):
        import io
        from contextlib import redirect_stderr
        for event in ("write", "signal"):
            with self.subTest(event=event), tempfile.TemporaryDirectory() as temp:
                save = module.Runner.save; injected = False
                def interrupted_save(runner):
                    nonlocal injected
                    if runner.receipt["status"] == "passed" and not injected:
                        injected = True
                        if event == "write": raise PermissionError("receipt replace denied")
                        signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
                    return save(runner)
                cwd=Path.cwd();handlers={sig:signal.getsignal(sig) for sig in (signal.SIGINT,signal.SIGTERM)}
                with patch.object(module.Runner,"save",interrupted_save),redirect_stderr(io.StringIO()):
                    self.assertEqual(self.invoke(Path(temp)/"attempt"),1 if event == "write" else 143)
                receipt=json.loads((Path(temp)/"attempt/verification.json").read_text())
                self.assertEqual(receipt["status"],"failed" if event == "write" else "interrupted")
                self.assertEqual(Path.cwd(),cwd)
                self.assertTrue(all(signal.getsignal(sig)==handler for sig,handler in handlers.items()))

    def test_permission_error_in_cleanup_is_batch_fatal(self):
        from unittest.mock import Mock
        child=Mock(pid=123,returncode=None)
        with patch.object(module.os,"killpg",side_effect=PermissionError("denied")), patch.object(module,"process_group_members",return_value=[{"pid":123,"parent":1,"uid":os.getuid(),"state":"S","start":"original"}]):
            with self.assertRaisesRegex(module.CleanupFailed,"123"): module.cleanup_child(child)
        with tempfile.TemporaryDirectory() as temp:
            self.assertEqual(self.invoke(Path(temp)/"attempt",[module.CleanupFailed("denied")]),1)
            receipt=json.loads((Path(temp)/"attempt/verification.json").read_text())
            self.assertEqual(len(receipt["tests"]),1)

    def test_interruption_wins_when_cleanup_also_fails(self):
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as temp:
            runner=module.Runner(Path(temp)/"command",{})
            child=Mock(pid=123,returncode=None);child.wait.side_effect=subprocess.TimeoutExpired("held",1)
            def cleanup(child):
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM,None)
                raise module.CleanupFailed("unconfirmed group")
            with patch.object(module.subprocess,"Popen",return_value=child),patch.object(module,"cleanup_child",side_effect=cleanup):
                with self.assertRaises(module.RunInterrupted) as interrupted: runner.command("held",["fixture"],1)
            self.assertEqual(interrupted.exception.signum,signal.SIGTERM)
            self.assertEqual(runner.receipt["phases"][0]["processGroupID"],123)
            self.assertIn("unconfirmed",runner.receipt["phases"][0]["cleanupError"])
            self.assertEqual(self.invoke(Path(temp)/"batch",[interrupted.exception]),143)

    def test_stderr_failure_path_is_recorded(self):
        with tempfile.TemporaryDirectory() as temp:
            runner=module.Runner(Path(temp)/"attempt",{})
            self.assertEqual(runner.command("error",[sys.executable,"-c","import sys; print('detail',file=sys.stderr);sys.exit(7)"],5),7)
            phase=runner.receipt["phases"][0]
            self.assertIn("detail",(runner.output/phase["stderrLog"]).read_text())

    def test_export_stderr_warning_does_not_corrupt_json(self):
        with tempfile.TemporaryDirectory() as temp:
            runner = module.Runner(Path(temp)/"attempt", {})
            self.assertEqual(runner.command("export", [sys.executable, "-c", "import sys,json; print(json.dumps({'passedTests':1})); print('warning',file=sys.stderr)"], 5), 0)
            module.require_executed(json.loads((runner.output/"export.log").read_text()))
            self.assertIn("warning", (runner.output/"export.stderr.log").read_text())

    def test_empty_exception_is_not_an_interrupt(self):
        self.assertNotIn("SIGINT", module.error_description(RuntimeError()))
        self.assertIn("SIGINT", module.error_description(KeyboardInterrupt()))

    def test_missing_and_nested_dirty_submodule_provenance(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(path, *args):
                return subprocess.check_output(["git", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", *args], cwd=path, text=True, stderr=subprocess.DEVNULL).strip()
            def init(path):
                path.mkdir(parents=True, exist_ok=True); git(path,"init","-q")
                (path/"input").write_text("initial"); git(path,"add",".")
                git(path,"-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","fixture")
            init(root)
            missing=root/"Vendor/Missing"; missing.mkdir(parents=True)
            git(root,"update-index","--add","--cacheinfo","160000",git(root,"rev-parse","HEAD"),"Vendor/Missing")
            self.assertFalse(module.capture_inputs(root)["submodules"]["Vendor/Missing"]["initialized"])
            parent=root/"Vendor/Parent"; init(parent); nested=parent/"Nested"; init(nested)
            git(parent,"update-index","--add","--cacheinfo","160000",git(nested,"rev-parse","HEAD"),"Nested")
            git(root,"update-index","--add","--cacheinfo","160000",git(parent,"rev-parse","HEAD"),"Vendor/Parent")
            (nested/"input").write_text("dirty one")
            first=module.capture_inputs(root)
            self.assertEqual(first,module.capture_inputs(root))
            (nested/"input").write_text("dirty two")
            self.assertNotEqual(first,module.capture_inputs(root))

    def test_cleanup_failure_aborts_successor_cases(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)/"attempt"
            self.assertEqual(self.invoke(output, [module.CleanupFailed("unreaped group")]), 1)
            receipt = json.loads((output/"verification.json").read_text())
            self.assertEqual(len(receipt["tests"]), 1)
            self.assertEqual(receipt["tests"][0]["status"], "cleanup-failed")

    def test_final_kill_join_is_bounded(self):
        from unittest.mock import Mock
        child = Mock(pid=123, returncode=None)
        with patch.object(module.os, "killpg"), patch.object(module, "process_group_members", return_value=[{"pid":123,"parent":1,"uid":os.getuid(),"state":"S","start":"original"}]), \
             patch.object(module.time, "monotonic", side_effect=[0, 20, 21, 40]):
            with self.assertRaises(module.CleanupFailed): module.cleanup_child(child)
        child.wait.assert_not_called()

    def test_cleanup_distinguishes_zombies_live_denial_and_recycled_identity(self):
        from unittest.mock import Mock
        def member(pid, state="S", start="original"):
            return {"pid":pid,"parent":1,"uid":os.getuid(),"state":state,"start":start}
        for records, reaped, expected in [([], True, True), ([member(124,"Z")], True, True),
            ([member(123)], True, False), ([member(123)], False, False)]:
            with self.subTest(records=records,reaped=reaped):
                child=Mock(pid=123,returncode=0 if reaped else None)
                with patch.object(module,"process_group_members",return_value=records), patch.object(module.os,"killpg",side_effect=PermissionError("denied")) as kill:
                    if expected:
                        module.cleanup_child(child)
                        kill.assert_not_called()
                    else:
                        with self.assertRaises(module.CleanupFailed):module.cleanup_child(child)
        child=Mock(pid=123,returncode=None)
        with patch.object(module,"process_group_members",side_effect=TimeoutError("snapshot stalled")):
            with self.assertRaisesRegex(module.CleanupFailed,"snapshot stalled"):module.cleanup_child(child)

    def test_cleanup_admits_owned_descendants_before_reaping_exited_leader(self):
        with tempfile.TemporaryDirectory() as temp:
            pidfile, release = Path(temp)/"pid", Path(temp)/"exit"
            code = """import os,sys,time,signal
from pathlib import Path
if os.fork()==0:
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 temporary = Path(sys.argv[1] + '.tmp')
 temporary.write_text(str(os.getpid()))
 temporary.replace(sys.argv[1])
 while True: time.sleep(.1)
while not Path(sys.argv[2]).exists(): time.sleep(.005)
os._exit(0)
"""
            child = subprocess.Popen([sys.executable,"-c",code,str(pidfile),str(release)],
                start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            descendant = None
            try:
                deadline = time.monotonic()+5
                while not pidfile.exists() and time.monotonic()<deadline: time.sleep(.005)
                descendant = int(pidfile.read_text())
                release.touch()
                deadline = time.monotonic()+5
                while time.monotonic()<deadline:
                    members = module.process_group_members(child.pid)
                    if any(m["pid"]==child.pid and m["state"].startswith("Z") for m in members): break
                    time.sleep(.005)
                else: self.fail("Leader did not reach unreaped exit")
                self.assertIsNone(child.returncode)
                module.cleanup_child(child)
                self.assertIsNotNone(child.returncode)
                self.assertFalse(any(not m["state"].startswith("Z") for m in module.process_group_members(child.pid)))
            finally:
                if descendant is not None:
                    try: os.kill(descendant,signal.SIGKILL)
                    except ProcessLookupError: pass
                elif child.returncode is None:
                    # Readiness failure must also retire the original owned group.
                    module.cleanup_child(child)
                if child.poll() is None: child.kill()
                child.wait(timeout=2)

    def test_cleanup_benchmark_preserves_failure_and_retires_fixture(self):
        with tempfile.TemporaryDirectory() as temp:
            runner = Path(temp)/"runner.py"
            runner.write_text("def cleanup_child(child):\n raise RuntimeError('original probe failure')\n")
            result = subprocess.run([sys.executable, str(ROOT/'Scripts/benchmark-process-cleanup.py'),
                '--runner', str(runner), '--mode', 'live'], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2, result.stderr)
            value = json.loads(result.stdout)
            self.assertFalse(value['correct'])
            self.assertIn('original probe failure', value['error'])
            self.assertIn('original probe failure', result.stderr)
            self.assertFalse(any(not m['state'].startswith('Z') for m in module.process_group_members(value['processGroupID'])))

    def test_pre_reap_snapshot_does_not_adopt_recycled_leader(self):
        from unittest.mock import Mock
        original={"pid":123,"parent":os.getpid(),"uid":os.getuid(),"state":"Z","start":"original"}
        recycled={**original,"state":"S","start":"replacement"}
        child=Mock(pid=123,returncode=None)
        def poll(): child.returncode=0
        child.poll.side_effect=poll
        with patch.object(module,"process_group_members",side_effect=[[original],[recycled]]), patch.object(module.os,"killpg") as kill:
            with self.assertRaisesRegex(module.CleanupFailed,"recycled"): module.cleanup_child(child)
            kill.assert_not_called()

    def test_permission_probe_after_owned_group_exits_is_confirmed_from_state(self):
        from unittest.mock import Mock
        member={"pid":123,"parent":1,"uid":os.getuid(),"state":"S","start":"original"}
        zombie={"pid":124,"parent":1,"uid":os.getuid(),"state":"Z","start":"descendant"}
        child=Mock(pid=123,returncode=None)
        calls=0
        def poll():
            nonlocal calls
            calls+=1
            if calls>1:child.returncode=0
        child.poll.side_effect=poll
        with patch.object(module,"process_group_members",side_effect=[[member],[member],[zombie]]), patch.object(module.os,"killpg",side_effect=PermissionError("zombie-only group")):
            module.cleanup_child(child)
        self.assertEqual(child.returncode,0)

    def test_sdk_is_captured_once_for_prepared_reuse(self):
        with tempfile.TemporaryDirectory() as temp:
            derived=Path(temp)/"derived";self.products(derived)
            module.record_preparation(derived,{"revision":"fixture"},self.context())
            original=module.prepared_manifest
            observed=[]
            def manifest(path,sdk):
                observed.append(sdk)
                return original(path,sdk)
            with patch.object(module,"prepared_manifest",side_effect=manifest):
                self.assertEqual(self.invoke(Path(temp)/"attempt",derived=derived),0)
            self.assertEqual(observed,["fixture"])
            source=(ROOT/'Scripts/run-selected-ui-verification.py').read_text()
            self.assertEqual(source.count('subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"]'),1)

    def test_finalization_seam_survives_extra_inventory_and_selection_size(self):
        original=module.verify_preparation
        def verify(*args,**kwargs):
            module.product_hashes(args[0])
            return original(*args,**kwargs)
        selection=module.load_selection(ROOT/"Tests/Verification/ui-smoke.json")
        for size in [1,len(selection)]:
            with self.subTest(size=size), patch.object(module,"load_selection",return_value=selection[:size]), patch.object(module,"verify_preparation",side_effect=verify):
                self.test_final_inventory_exception_still_saves_and_restores_process_state()

    def test_signal_during_timeout_cleanup_is_not_lost(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)/"attempt"
            code = """
import importlib.util,pathlib,signal,sys
spec=importlib.util.spec_from_file_location('runner',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def stop(n,f):raise m.RunInterrupted(n)
signal.signal(signal.SIGTERM,stop)
r=m.Runner(pathlib.Path(sys.argv[2]),{})
spawn=m.subprocess.Popen
def ready_spawn(*args,**kwargs):
 import time
 child=spawn(*args,**kwargs);deadline=time.monotonic()+5
 while not (r.output/'held.log').exists() or 'ready' not in (r.output/'held.log').read_text():
  if child.poll() is not None or time.monotonic()>deadline:raise RuntimeError('child-ready handshake failed')
  time.sleep(.005)
 return child
m.subprocess.Popen=ready_spawn
try:
 r.command('held',[sys.executable,'-u','-c','import signal,time,sys; signal.signal(signal.SIGTERM,lambda n,f:(print("cleanup",flush=True),time.sleep(.4),sys.exit(0))); print("ready",flush=True); time.sleep(30)'],.2)
 print('BAD_CONTINUATION',flush=True)
except m.RunInterrupted as e:
 r.receipt.update(status='interrupted',error=str(e));r.save();sys.exit(128+e.signum)
"""
            child=subprocess.Popen([sys.executable,'-c',code,str(ROOT/'Scripts/run-selected-ui-verification.py'),str(output)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                deadline=time.monotonic()+5
                log=output/'held.log'
                while not log.exists() or 'cleanup' not in log.read_text():
                    if child.poll() is not None or time.monotonic()>deadline: self.fail('cleanup did not rendezvous')
                    time.sleep(.005)
                child.send_signal(signal.SIGTERM)
                stdout,stderr=child.communicate(timeout=5)
                self.assertEqual(child.returncode,143,stdout+stderr)
                self.assertNotIn('BAD_CONTINUATION',stdout)
                receipt=json.loads((output/'verification.json').read_text())
                self.assertEqual(receipt['status'],'interrupted')
                self.assertEqual(receipt['phases'][0]['status'],'interrupted')
            finally:
                if child.poll() is None: child.kill();child.wait(timeout=2)

    def test_yaml_workflow_is_actually_inspected(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); workflows=root/'.github/workflows';workflows.mkdir(parents=True)
            (workflows/'ci.yml').write_text('run: xcodebuild test -only-testing:TraceCoreTests -only-testing:TraceAppTests\n# TraceExternalClientFixture\n')
            (workflows/'unsafe.yaml').write_text('run: xcodebuild test -scheme Trace\n')
            with patch.dict(globals(), ROOT=root), self.assertRaises(AssertionError):
                self.test_ci_has_no_ui_execution_entrypoints()

    def test_fixture_commit_ignores_global_signing_and_hooks(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); hooks=root/'hooks';hooks.mkdir()
            marker=root/'hook-ran'; hook=hooks/'pre-commit'
            hook.write_text('#!/bin/sh\ntouch "'+str(marker)+'"\nexit 13\n');hook.chmod(0o755)
            config=root/'gitconfig';config.write_text('[commit]\n gpgSign = true\n[core]\n hooksPath = '+str(hooks)+'\n[gpg]\n program = /usr/bin/false\n')
            with patch.dict(os.environ, GIT_CONFIG_GLOBAL=str(config)):
                self.test_actual_dirty_and_untracked_input_bytes_are_recorded()
            self.assertFalse(marker.exists())

    def test_timeout_cleans_term_resistant_descendant_after_leader_exits(self):
        with tempfile.TemporaryDirectory() as temp:
            output=Path(temp)/'attempt'
            worker="""
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('runner',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
r=m.Runner(pathlib.Path(sys.argv[2]),{})
spawn=m.subprocess.Popen
def ready_spawn(*args,**kwargs):
 import time
 child=spawn(*args,**kwargs);deadline=time.monotonic()+5
 while not (r.output/'held.log').exists() or not (r.output/'held.log').read_text().strip():
  if child.poll() is not None or time.monotonic()>deadline:raise RuntimeError('descendant-ready handshake failed')
  time.sleep(.005)
 return child
m.subprocess.Popen=ready_spawn
leader="import subprocess,sys,time; p=subprocess.Popen([sys.executable,'-u','-c','import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print(os.getpid(),flush=True); time.sleep(30)']); time.sleep(30)"
code=r.command('held',[sys.executable,'-u','-c',leader],.3)
sys.exit(code)
"""
            child=subprocess.Popen([sys.executable,'-c',worker,str(ROOT/'Scripts/run-selected-ui-verification.py'),str(output)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                stdout,stderr=child.communicate(timeout=20)
                self.assertEqual(child.returncode,124,stdout+stderr)
                descendant=int((output/'held.log').read_text().strip())
                phase = json.loads((output/'verification.json').read_text())['phases'][0]
                remaining = module.process_group_members(phase['processGroupID'])
                self.assertFalse(any(not m["state"].startswith("Z") for m in remaining))
                receipt=json.loads((output/'verification.json').read_text())
                self.assertEqual(receipt['phases'][0]['status'],'timeout')
            finally:
                if child.poll() is None:child.kill();child.wait(timeout=2)
                log=output/'held.log'
                if log.exists() and log.read_text().strip().isdigit():
                    try:os.kill(int(log.read_text().strip()),signal.SIGKILL)
                    except ProcessLookupError:pass

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
