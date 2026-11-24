#!/usr/bin/env python3
"""Run an explicit UI selection on the local desktop; retain every attempt."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import plistlib
import signal
import subprocess
import sys
import time

SELECTOR = re.compile(r"TraceUITests/[A-Za-z_][A-Za-z_0-9]*/test[A-Za-z_0-9]+")


def load_selection(path: Path) -> list[str]:
    values = json.loads(path.read_text())
    if not isinstance(values, list) or not values:
        raise ValueError("Selection must be a nonempty JSON array of exact UI test identifiers")
    if any(not isinstance(v, str) or not SELECTOR.fullmatch(v) for v in values):
        raise ValueError("Use exact TraceUITests/Class/testMethod identifiers, without wildcards")
    if len(values) != len(set(values)):
        raise ValueError("Selection contains duplicate identifiers")
    return values


def discovered_identifiers(value: object) -> set[str]:
    if not isinstance(value, dict):
        raise ValueError("Compiled discovery must be a JSON object")
    result: set[str] = set()

    def visit(node: object, target: str = "", cls: str = "") -> None:
        if isinstance(node, list):
            for child in node:
                visit(child, target, cls)
        elif isinstance(node, dict):
            kind, name = node.get("kind"), node.get("name", "")
            if not isinstance(name, str):
                raise ValueError("Discovery names must be strings")
            if kind == "target":
                target = name
            elif kind == "class":
                cls = name
            elif kind == "test" and target and cls:
                result.add(f"{target}/{cls}/{name.removesuffix('()')}")
            for key in ("values", "children"):
                children = node.get(key, [])
                if not isinstance(children, list):
                    raise ValueError("Discovery children must be arrays")
                visit(children, target, cls)
        else:
            raise ValueError("Discovery entries must be objects")

    visit(value)
    return result


def validate_summary(summary: object) -> None:
    if not isinstance(summary, dict):
        raise ValueError("XCTest summary must be a JSON object")
    for key in ("passedTests", "failedTests", "skippedTests"):
        count = summary.get(key, 0)
        if type(count) is not int or count < 0:
            raise ValueError(f"XCTest {key} must be a nonnegative integer")


def require_executed(summary: object) -> None:
    validate_summary(summary)
    if summary.get("passedTests", 0) < 1 or summary.get("failedTests", 0) or summary.get("skippedTests", 0):
        raise ValueError("Selected test did not execute and pass without skips: " + json.dumps(summary))


class RunInterrupted(Exception):
    def __init__(self, signum: int):
        self.signum = signum
        super().__init__(f"Interrupted by {signal.Signals(signum).name}")


def error_description(error: BaseException) -> str:
    return f"{type(error).__name__}: {str(error) or ('Interrupted by SIGINT' if isinstance(error, KeyboardInterrupt) else 'No further details')}"


def capture_inputs(repo: Path, *, vendor: bool = False) -> dict:
    def git(*args: str) -> bytes:
        return subprocess.check_output(["git", *args], cwd=repo)
    files, submodules = {}, {}
    for entry in git("ls-files", "--stage", "-z").split(b"\0"):
        if not entry:
            continue
        metadata, name = entry.split(b"\t", 1)
        mode, blob, stage = metadata.decode().split()
        name = os.fsdecode(name)
        path = repo / name
        if stage != "0":
            raise ValueError("Unmerged input: " + name)
        if mode == "160000":
            initialized = path.is_dir() and (path / ".git").exists()
            if initialized:
                boundary = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=path, text=True).strip())
                initialized = boundary.resolve() == path.resolve()
            submodules[name] = {"initialized": initialized, "gitlink": blob}
            if initialized:
                submodules[name]["inputs"] = capture_inputs(path, vendor=True)
        else:
            data = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes() if path.is_file() else b""
            files[name] = {"mode": mode, "present": path.exists() or path.is_symlink(), "sha256": hashlib.sha256(data).hexdigest()}
    untracked = {}
    for raw in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
        if not raw:
            continue
        name = os.fsdecode(raw)
        path = repo / name
        if (vendor or name.split("/")[0] in ("Sources", "Tests", "Scripts")) and "__pycache__" not in path.parts:
            if path.is_file() and not path.is_symlink():
                untracked[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return {"revision": git("rev-parse", "HEAD").decode().strip(), "files": files,
            "untrackedInputs": untracked, "submodules": submodules,
            "trackedDiffSHA256": hashlib.sha256(git("diff", "HEAD", "--binary")).hexdigest()}


class CleanupFailed(Exception):
    """Cleanup could not be confirmed; do not start another desktop command."""


def process_group_exists(pid: int) -> bool:
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False


def cleanup_child(child: subprocess.Popen) -> None:
    try:
        _cleanup_child(child)
    except Exception as error:
        raise CleanupFailed(f"Could not confirm cleanup of process group {child.pid}: {error}") from error


def _cleanup_child(child: subprocess.Popen) -> None:
    for signum, allowance in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + allowance
        while time.monotonic() < deadline:
            child.poll()  # Reap the leader without blocking, including after SIGKILL.
            if child.returncode is not None and not process_group_exists(child.pid):
                return
            time.sleep(.02)
    raise CleanupFailed("Command or process group remains after bounded SIGKILL cleanup")


def prepared_manifest(derived: Path, sdk: str) -> Path:
    expected = derived / "Build/Products" / f"Trace_macosx{sdk}-arm64.xctestrun"
    if not expected.is_file():
        raise ValueError("Compatible prepared UI manifest not found: " + str(expected) + "; prepare the full build first")
    value = plistlib.loads(expected.read_bytes())
    configurations = value.get("TestConfigurations", [])
    targets = [value["TraceUITests"]] if "TraceUITests" in value else [
        target for config in configurations for target in config.get("TestTargets", [])
        if target.get("BlueprintName") == "TraceUITests"]
    if len(targets) != 1:
        raise ValueError("Prepared manifest must identify one TraceUITests target: " + str(expected))
    target = targets[0]
    for key in ("TestHostPath", "UITargetAppPath"):
        path = target.get(key, "")
        if not isinstance(path, str) or not path.startswith("__TESTROOT__/Debug/"):
            raise ValueError("Prepared UI products must use Debug configuration: " + key)
        product = expected.parent / path.removeprefix("__TESTROOT__/")
        product.resolve().relative_to((expected.parent / "Debug").resolve())
        if not product.exists():
            raise ValueError("Prepared UI product is missing: " + path)
    host = expected.parent / target["TestHostPath"].removeprefix("__TESTROOT__/")
    referenced = [target.get("TestBundlePath", "")] + target.get("DependentProductPaths", [])
    for path in referenced:
        if not isinstance(path, str):
            raise ValueError("Invalid prepared dependency path")
        if path.startswith("__TESTHOST__/"):
            product = host / path.removeprefix("__TESTHOST__/")
        elif path.startswith("__TESTROOT__/Debug/"):
            product = expected.parent / path.removeprefix("__TESTROOT__/")
        else:
            raise ValueError("Prepared dependency must belong to the Debug products: " + path)
        product.resolve().relative_to((expected.parent / "Debug").resolve())
        if not product.exists():
            raise ValueError("Prepared UI dependency is missing: " + path)
    return expected


def manifest_hashes(derived: Path) -> dict[str, str]:
    return {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((derived / "Build/Products").glob("*.xctestrun"))}


PREPARATION_RECEIPT = "prepared-ui-build.json"


def native_inputs(inputs: dict) -> dict:
    # Revision and documentation can differ while every native/build input is identical.
    files = {name: value for name, value in inputs.get("files", {}).items()
             if not name.startswith(("docs/", "reviews_triage/", ".github/")) and not name.endswith(".md")}
    return {"files": files, "untrackedInputs": inputs.get("untrackedInputs", {}),
            "submodules": inputs.get("submodules", {})}


def product_hashes(derived: Path) -> dict:
    products = derived / "Build/Products"
    debug = products / "Debug"
    if not debug.is_dir():
        raise ValueError("Prepared Debug products are missing")
    result = {}
    for path in sorted(debug.rglob("*")):
        name = path.relative_to(products).as_posix()
        if path.is_symlink():
            path.resolve(strict=True).relative_to(products.resolve())
            result[name] = {"symlink": os.readlink(path)}
        elif path.is_file():
            result[name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                            "mode": path.stat().st_mode & 0o777}
    if not result:
        raise ValueError("Prepared Debug product inventory is empty")
    return {"products": result, "manifests": manifest_hashes(derived)}


def build_context(runner, sdk: str) -> dict:
    return {"configuration": "Debug", "architecture": "arm64", "sdk": sdk,
            "toolchain": runner.receipt["toolchain"], "developerDirectory": os.environ.get("DEVELOPER_DIR", "default")}


def record_preparation(derived: Path, inputs: dict, context: dict) -> dict:
    receipt = {"format": 1, "revision": inputs["revision"], "nativeInputs": native_inputs(inputs),
               "context": context, "artifacts": product_hashes(derived)}
    path = derived / PREPARATION_RECEIPT
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(receipt, indent=2) + "\n")
    temporary.replace(path)
    return receipt


def verify_preparation(derived: Path, inputs: dict, context: dict) -> dict:
    path = derived / PREPARATION_RECEIPT
    if not path.is_file():
        raise ValueError("Prepared build provenance is missing; run --prepare-only into a new DerivedData directory")
    receipt = json.loads(path.read_text())
    if not isinstance(receipt, dict) or receipt.get("format") != 1:
        raise ValueError("Unsupported prepared build provenance")
    if receipt.get("context") != context or receipt.get("nativeInputs") != native_inputs(inputs):
        raise ValueError("Prepared build does not match current native inputs/toolchain/Debug configuration")
    if receipt.get("artifacts") != product_hashes(derived):
        raise ValueError("Prepared product or manifest hashes changed since preparation")
    return receipt


class Runner:
    def __init__(self, output: Path, metadata: dict):
        output.mkdir(parents=True, exist_ok=False)
        self.output, self.receipt = output, dict(metadata, phases=[], tests=[], status="running")
        self.save()

    def save(self) -> None:
        temporary = self.output / "verification.json.tmp"
        temporary.write_text(json.dumps(self.receipt, indent=2) + "\n")
        temporary.replace(self.output / "verification.json")

    def command(self, label: str, args: list[str], timeout: int) -> int:
        phase = {"label": label, "command": args, "log": label + ".log", "stderrLog": label + ".stderr.log", "status": "running"}
        self.receipt["phases"].append(phase)
        self.save()
        print(f"Starting {label}", flush=True)
        start = time.monotonic()
        interrupted = False
        # Structured exports keep stdout pure; diagnostics always have their own log.
        with (self.output / phase["log"]).open("w") as log, (self.output / (label + ".stderr.log")).open("w") as diagnostics:
            try:
                child = subprocess.Popen(args, stdout=log, stderr=diagnostics, start_new_session=True)
            except OSError as error:
                phase.update(status="launch-failed", error=str(error), elapsedSeconds=time.monotonic() - start)
                self.save()
                raise
            try:
                phase["processGroupID"] = child.pid
                code = child.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt, RunInterrupted) as error:
                interrupted = not isinstance(error, subprocess.TimeoutExpired)
                pending_signals = []
                handlers = {sig: signal.signal(sig, lambda signum, frame: pending_signals.append(signum))
                            for sig in (signal.SIGINT, signal.SIGTERM)}
                cleanup_error = None
                try:
                    cleanup_child(child)
                except CleanupFailed as failure:
                    cleanup_error = failure
                finally:
                    for sig, handler in handlers.items():
                        signal.signal(sig, handler)
                if pending_signals:
                    error = RunInterrupted(pending_signals[0])
                    interrupted = True
                if cleanup_error:
                    phase.update(status="cleanup-failed", error=error_description(error), cleanupError=str(cleanup_error),
                                 elapsedSeconds=time.monotonic() - start)
                    self.save()
                    if interrupted:
                        interruption = error if isinstance(error, RunInterrupted) else RunInterrupted(signal.SIGINT)
                        interruption.cleanup_error = str(cleanup_error)
                        raise interruption
                    raise cleanup_error
                phase["status"] = "interrupted" if interrupted else "timeout"
                phase["error"] = error_description(error)
                code = (128 + error.signum if isinstance(error, RunInterrupted) else 130) if interrupted else 124
                interruption = error if isinstance(error, RunInterrupted) else RunInterrupted(signal.SIGINT)
        phase.update(exitCode=code, elapsedSeconds=time.monotonic() - start)
        if phase["status"] == "running":
            phase["status"] = "passed" if code == 0 else "failed"
        self.save()
        print(f"Finished {label}: {phase['status']} ({phase['elapsedSeconds']:.1f}s)", flush=True)
        if interrupted:
            raise interruption
        return code


def require_local_execution(environment: dict[str, str]) -> None:
    if environment.get("GITHUB_ACTIONS", "").lower() in ("true", "1") or environment.get("CI", "").lower() in ("true", "1"):
        raise ValueError("UI verification is local-only; CI execution is prohibited")


def run_case(runner: Runner, base: list[str], selector: str, index: int, timeout: int) -> None:
    label = f"ui-{index:03d}"
    bundle = runner.output / (label + ".xcresult")
    test = {"selector": selector, "result": bundle.name, "passed": False, "status": "running"}
    runner.receipt["tests"].append(test)
    runner.save()
    try:
        code = runner.command(label, base + ["test-without-building", "-only-testing:" + selector,
            "-resultBundlePath", str(bundle), "-test-timeouts-enabled", "YES",
            "-default-test-execution-time-allowance", "180", "-maximum-test-execution-time-allowance", "300"], timeout)
        test["exitCode"] = code
        if not bundle.exists():
            raise ValueError("XCTest result bundle was not created")
        export = label + "-export"
        if runner.command(export, ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)], 60):
            raise ValueError("Could not export XCTest result summary; inspect " + export + ".log and " + export + ".stderr.log")
        summary = json.loads((runner.output / (export + ".log")).read_text())
        validate_summary(summary)
        summary_path = runner.output / (label + "-summary.json")
        summary_path.write_text(json.dumps(summary, indent=2) + "\n")
        test["summary"] = summary_path.name
        require_executed(summary)
        test["passed"] = code == 0
        test["status"] = "passed" if test["passed"] else "failed"
    except (RunInterrupted, KeyboardInterrupt, CleanupFailed) as error:
        test.update(status="interrupted" if not isinstance(error, CleanupFailed) else "cleanup-failed", error=error_description(error))
        raise
    except Exception as error:
        test.update(status="failed", error=error_description(error))
    finally:
        runner.save()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selection", type=Path, required=True, help="Repository-relative selection, or an absolute path within it")
    parser.add_argument("--output", type=Path, required=True, help="New attempt directory; relative to the invocation directory")
    parser.add_argument("--prepare-only", action="store_true", help="Build/discover and record provenance; run no UI cases; requires a new DerivedData directory")
    parser.add_argument("--test-timeout", type=int, default=360, help="Outer per-case watchdog, at least 360 seconds")
    parser.add_argument("--derived-data", type=Path, help="Reuse-only prepared products; relative to the invocation directory; never rebuilds")
    args = parser.parse_args()
    try:
        require_local_execution(dict(os.environ))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    repo = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    derived_data = args.derived_data.resolve() if args.derived_data else output / "DerivedData"
    try:
        runner = Runner(output, {"uiExecution": "local-current-desktop", "performanceAcceptance": False,
            "requestedSelection": str(args.selection), "derivedData": str(derived_data)})
    except OSError as error:
        print(error_description(error), file=sys.stderr)
        return 2
    handlers = {}
    def interrupt(signum, frame):
        raise RunInterrupted(signum)
    original_cwd = Path.cwd()
    initial_inputs = None
    original_artifacts = None
    exit_code = 1
    try:
        handlers = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM)}
        os.chdir(repo)
        selection = (repo / args.selection).resolve()
        selection.relative_to(repo)
        tests = load_selection(selection)
        if args.test_timeout < 360:
            raise ValueError("Test timeout must be at least 360 seconds (300 seconds XCTest plus overhead)")
        runner.receipt.update(selection=str(selection.relative_to(repo)),
            selectionSHA256=hashlib.sha256(selection.read_bytes()).hexdigest(), selectedTests=tests)
        initial_inputs = capture_inputs(repo)
        runner.receipt.update(revision=initial_inputs["revision"], testedInputs=initial_inputs)
        runner.save()
        for label, command in [("toolchain", ["xcodebuild", "-version"]), ("macOS", ["sw_vers"])]:
            if runner.command(label, command, 30):
                raise ValueError("Could not capture " + label + "; inspect its phase log")
            runner.receipt[label] = (runner.output / (label + ".log")).read_text().strip()
            runner.save()
        base = ["xcodebuild", "-project", "Trace.xcodeproj", "-scheme", "Trace", "-configuration", "Debug",
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived_data), "-parallel-testing-enabled", "NO"]
        if runner.command("gui-session", ["launchctl", "print", f"gui/{os.getuid()}"], 15):
            raise ValueError("Runner has no GUI login session; log in locally before testing")
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
        context = build_context(runner, sdk)
        if args.prepare_only and (not args.derived_data or derived_data.exists()):
            raise ValueError("--prepare-only requires a new, nonexistent --derived-data directory")
        if args.derived_data and not args.prepare_only:
            sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
            manifest = prepared_manifest(derived_data, sdk)
            preparation = verify_preparation(derived_data, initial_inputs, context)
            original_artifacts = preparation["artifacts"]
            runner.receipt.update(preparedManifest=str(manifest), preparedArtifacts=original_artifacts,
                preparationRevision=preparation["revision"], preparationContext=context, buildMode="reuse-only")
            base = ["xcodebuild", "-xctestrun", str(manifest), "-destination", "platform=macOS,arch=arm64",
                    "-parallel-testing-enabled", "NO"]
        else:
            runner.receipt["buildMode"] = "private-build"
            if runner.command("build", base + ["build-for-testing"], 1800):
                raise ValueError("UI build failed; inspect build.log and build.stderr.log")
            if native_inputs(capture_inputs(repo)) != native_inputs(initial_inputs):
                raise ValueError("Native inputs changed during preparation")
            prepared_manifest(derived_data, sdk)
            original_artifacts = product_hashes(derived_data)
        discovery = runner.output / "discovery.json"
        if runner.command("discovery", base + ["test-without-building", "-enumerate-tests", "-only-testing:TraceUITests",
                "-test-enumeration-format", "json", "-test-enumeration-output-path", str(discovery)], 180):
            raise ValueError("Compiled UI discovery failed")
        catalog = json.loads(discovery.read_text())
        catalog_ids = discovered_identifiers(catalog)
        if catalog.get("errors"):
            raise ValueError("Compiled discovery reported errors: " + str(catalog["errors"]))
        missing = set(tests) - catalog_ids
        if missing:
            raise ValueError("Selectors absent from compiled XCTest discovery: " + ", ".join(sorted(missing)))
        runner.receipt["identifiersVerified"] = True
        if runner.receipt["buildMode"] == "private-build":
            if original_artifacts != product_hashes(derived_data):
                raise ValueError("Prepared artifacts changed during discovery")
            preparation = record_preparation(derived_data, initial_inputs, context)
            runner.receipt.update(preparationRevision=preparation["revision"], preparationContext=context, preparedArtifacts=original_artifacts)
        runner.save()
        for index, selector in enumerate([] if args.prepare_only else tests, 1):
            verify_preparation(derived_data, initial_inputs, context)
            run_case(runner, base, selector, index, args.test_timeout)
            verify_preparation(derived_data, initial_inputs, context)
        runner.receipt["status"] = "prepared" if args.prepare_only else "passed" if len(runner.receipt["tests"]) == len(tests) and all(t["passed"] for t in runner.receipt["tests"]) else "failed"
        exit_code = 0 if runner.receipt["status"] in ("passed", "prepared") else 1
    except (RunInterrupted, KeyboardInterrupt) as error:
        runner.receipt.update(status="interrupted", error=error_description(error))
        exit_code = 128 + error.signum if isinstance(error, RunInterrupted) else 130
    except Exception as error:
        runner.receipt.update(status="failed", error=error_description(error))
        print(error_description(error), file=sys.stderr)
    finally:
        pending_signals = []
        try:
            for sig in handlers:
                signal.signal(sig, lambda signum, frame: pending_signals.append(signum))
            failures = []
            if initial_inputs is not None:
                try:
                    final_inputs = capture_inputs(repo)
                    runner.receipt["inputsUnchanged"] = initial_inputs == final_inputs
                    if initial_inputs != final_inputs:
                        runner.receipt["finalInputs"] = final_inputs
                        failures.append("Tested inputs changed during verification")
                except Exception as error:
                    failures.append(error_description(error))
            if original_artifacts is not None:
                try:
                    unchanged = original_artifacts == product_hashes(derived_data)
                    runner.receipt["preparedArtifactsUnchanged"] = unchanged
                    runner.receipt["preparedManifestsUnchanged"] = original_artifacts["manifests"] == manifest_hashes(derived_data)
                    if not unchanged:
                        failures.append("Prepared binaries/resources/manifests changed during verification")
                except Exception as error:
                    failures.append(error_description(error))
            if failures:
                runner.receipt["finalizationErrors"] = failures
                if runner.receipt["status"] != "interrupted":
                    runner.receipt["status"] = "failed"
                exit_code = exit_code or 1
            if pending_signals:
                error = RunInterrupted(pending_signals[0])
                runner.receipt.update(status="interrupted", error=error_description(error))
                exit_code = 128 + error.signum
            try:
                runner.save()
            except Exception as error:
                runner.receipt["receiptWriteError"] = error_description(error)
                if runner.receipt["status"] != "interrupted": runner.receipt["status"] = "failed"
                print("Could not finalize verification receipt: " + error_description(error), file=sys.stderr)
                exit_code = exit_code or 1
                try: runner.save()
                except Exception as final_error:
                    print("Terminal receipt remains unwritable: " + error_description(final_error), file=sys.stderr)
            if pending_signals and exit_code != 128 + pending_signals[0]:
                error = RunInterrupted(pending_signals[0])
                runner.receipt.update(status="interrupted", error=error_description(error))
                exit_code = 128 + error.signum
                try: runner.save()
                except Exception as error:
                    print("Could not record final interruption: " + error_description(error), file=sys.stderr)
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
            os.chdir(original_cwd)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
