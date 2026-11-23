#!/usr/bin/env python3
"""Run an explicit UI selection on the local desktop; retain every attempt."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
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
    return f"{type(error).__name__}: {str(error) or 'Interrupted by SIGINT'}"


def capture_inputs(repo: Path) -> dict:
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
            submodules[name] = {
                "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path, text=True).strip(),
                "status": subprocess.check_output(["git", "status", "--short"], cwd=path, text=True),
                "diffSHA256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=path)).hexdigest(),
            }
        else:
            data = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes() if path.is_file() else b""
            files[name] = {"mode": mode, "present": path.exists() or path.is_symlink(), "sha256": hashlib.sha256(data).hexdigest()}
    untracked = {}
    for raw in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
        if not raw:
            continue
        name = os.fsdecode(raw)
        path = repo / name
        if name.split("/")[0] in ("Sources", "Tests", "Scripts") and "__pycache__" not in path.parts:
            if path.is_file() and not path.is_symlink():
                untracked[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return {"revision": git("rev-parse", "HEAD").decode().strip(), "files": files,
            "untrackedInputs": untracked, "submodules": submodules,
            "trackedDiffSHA256": hashlib.sha256(git("diff", "HEAD", "--binary")).hexdigest()}


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
        phase = {"label": label, "command": args, "log": label + ".log", "status": "running"}
        self.receipt["phases"].append(phase)
        self.save()
        print(f"Starting {label}", flush=True)
        start = time.monotonic()
        interrupted = False
        with (self.output / phase["log"]).open("w") as log:
            try:
                child = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            except OSError as error:
                phase.update(status="launch-failed", error=str(error), elapsedSeconds=time.monotonic() - start)
                self.save()
                raise
            try:
                code = child.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt, RunInterrupted) as error:
                interrupted = not isinstance(error, subprocess.TimeoutExpired)
                # A second signal cannot interrupt bounded child cleanup.
                handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
                try:
                    try:
                        os.killpg(child.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        child.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        try:
                            os.killpg(child.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        child.wait()
                finally:
                    for sig, handler in handlers.items():
                        signal.signal(sig, handler)
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
            raise ValueError("Could not export XCTest result summary; inspect " + export + ".log")
        summary = json.loads((runner.output / (export + ".log")).read_text())
        validate_summary(summary)
        summary_path = runner.output / (label + "-summary.json")
        summary_path.write_text(json.dumps(summary, indent=2) + "\n")
        test["summary"] = summary_path.name
        require_executed(summary)
        test["passed"] = code == 0
        test["status"] = "passed" if test["passed"] else "failed"
    except (RunInterrupted, KeyboardInterrupt) as error:
        test.update(status="interrupted", error=error_description(error))
        raise
    except Exception as error:
        test.update(status="failed", error=error_description(error))
    finally:
        runner.save()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selection", type=Path, required=True, help="Repository-relative selection, or an absolute path within it")
    parser.add_argument("--output", type=Path, required=True, help="New attempt directory; relative to the invocation directory")
    parser.add_argument("--test-timeout", type=int, default=360, help="Outer per-case watchdog, at least 360 seconds")
    parser.add_argument("--derived-data", type=Path, help="Prepared products; relative to the invocation directory")
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
        if runner.command("build", base + ["build-for-testing", "-only-testing:TraceUITests"], 1800):
            raise ValueError("UI build failed; inspect build.log")
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
        runner.save()
        for index, selector in enumerate(tests, 1):
            run_case(runner, base, selector, index, args.test_timeout)
        runner.receipt["status"] = "passed" if len(runner.receipt["tests"]) == len(tests) and all(t["passed"] for t in runner.receipt["tests"]) else "failed"
        exit_code = 0 if runner.receipt["status"] == "passed" else 1
    except (RunInterrupted, KeyboardInterrupt) as error:
        runner.receipt.update(status="interrupted", error=error_description(error))
        exit_code = 128 + error.signum if isinstance(error, RunInterrupted) else 130
    except Exception as error:
        runner.receipt.update(status="failed", error=error_description(error))
        print(error_description(error), file=sys.stderr)
    finally:
        if initial_inputs is not None:
            try:
                final_inputs = capture_inputs(repo)
                runner.receipt["inputsUnchanged"] = initial_inputs == final_inputs
                if initial_inputs != final_inputs:
                    runner.receipt["finalInputs"] = final_inputs
                    runner.receipt.update(status="failed", inputError="Tested inputs changed during verification")
                    exit_code = exit_code or 1
            except Exception as error:
                runner.receipt.update(status="failed", inputError=error_description(error))
                exit_code = exit_code or 1
        runner.save()
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
        os.chdir(original_cwd)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
