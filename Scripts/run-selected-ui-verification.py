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
    result: set[str] = set()

    def visit(node: object, target: str = "", cls: str = "") -> None:
        if isinstance(node, list):
            for child in node:
                visit(child, target, cls)
        elif isinstance(node, dict):
            kind, name = node.get("kind"), node.get("name", "")
            if kind == "target":
                target = name
            elif kind == "class":
                cls = name
            elif kind == "test" and target and cls:
                result.add(f"{target}/{cls}/{name.removesuffix('()')}")
            visit(node.get("values", []), target, cls)
            visit(node.get("children", []), target, cls)

    visit(value)
    return result


def require_executed(summary: dict) -> None:
    if summary.get("passedTests", 0) < 1 or summary.get("failedTests", 0) or summary.get("skippedTests", 0):
        raise ValueError("Selected test did not execute and pass without skips: " + json.dumps(summary))


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
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                interrupted = isinstance(error, KeyboardInterrupt)
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                phase["status"] = "interrupted" if interrupted else "timeout"
                code = 130 if interrupted else 124
        phase.update(exitCode=code, elapsedSeconds=time.monotonic() - start)
        if phase["status"] == "running":
            phase["status"] = "passed" if code == 0 else "failed"
        self.save()
        print(f"Finished {label}: {phase['status']} ({phase['elapsedSeconds']:.1f}s)", flush=True)
        if interrupted:
            raise KeyboardInterrupt
        return code


def require_local_execution(environment: dict[str, str]) -> None:
    if environment.get("GITHUB_ACTIONS", "").lower() in ("true", "1") or environment.get("CI", "").lower() in ("true", "1"):
        raise ValueError("UI verification is local-only; CI execution is prohibited")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selection", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--test-timeout", type=int, default=360)
    parser.add_argument("--derived-data", type=Path, help="Reuse test products prepared before the exclusive desktop window")
    args = parser.parse_args()
    try:
        require_local_execution(dict(os.environ))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    repo = Path(__file__).resolve().parent.parent
    os.chdir(repo)
    try:
        selection = args.selection.resolve()
        selection.relative_to(repo)
        tests = load_selection(selection)
        if args.test_timeout < 30:
            raise ValueError("Test timeout must be at least 30 seconds")
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        runner = Runner(args.output.resolve(), {
            "revision": revision, "selection": str(selection.relative_to(repo)),
            "selectionSHA256": hashlib.sha256(selection.read_bytes()).hexdigest(),
            "selectedTests": tests, "uiExecution": "local-current-desktop", "performanceAcceptance": False,
            "githubRunID": os.environ.get("GITHUB_RUN_ID"),
            "toolchain": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
            "macOS": subprocess.check_output(["sw_vers"], text=True).strip(),
            "submodules": subprocess.check_output(["git", "submodule", "status", "--recursive"], text=True).splitlines(),
        })
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 2
    derived_data = args.derived_data.resolve() if args.derived_data else runner.output / "DerivedData"
    runner.receipt["derivedData"] = str(derived_data)
    runner.save()
    base = ["xcodebuild", "-project", "Trace.xcodeproj", "-scheme", "Trace", "-configuration", "Debug",
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived_data),
            "-parallel-testing-enabled", "NO"]
    try:
        # A logged-in local desktop is required; this runner performs real input.
        if runner.command("gui-session", ["launchctl", "print", f"gui/{os.getuid()}"], 15):
            raise ValueError("Runner has no GUI login session; log in locally before testing")
        if runner.command("build", base + ["build-for-testing", "-only-testing:TraceUITests"], 1800):
            raise ValueError("UI build failed; inspect build.log")
        discovery = runner.output / "discovery.json"
        if runner.command("discovery", base + ["test-without-building", "-enumerate-tests", "-only-testing:TraceUITests",
                          "-test-enumeration-format", "json", "-test-enumeration-output-path", str(discovery)], 180):
            raise ValueError("Compiled UI discovery failed")
        catalog = json.loads(discovery.read_text())
        if catalog.get("errors"):
            raise ValueError("Compiled discovery reported errors: " + str(catalog["errors"]))
        missing = set(tests) - discovered_identifiers(catalog)
        if missing:
            raise ValueError("Selectors absent from compiled XCTest discovery: " + ", ".join(sorted(missing)))
        runner.receipt["identifiersVerified"] = True
        runner.save()
        for index, selector in enumerate(tests, 1):
            label = f"ui-{index:03d}"
            bundle = runner.output / (label + ".xcresult")
            code = runner.command(label, base + ["test-without-building", "-only-testing:" + selector,
                "-resultBundlePath", str(bundle), "-test-timeouts-enabled", "YES",
                "-default-test-execution-time-allowance", "180", "-maximum-test-execution-time-allowance", "300"], args.test_timeout)
            test = {"selector": selector, "exitCode": code, "result": bundle.name, "passed": False}
            if bundle.exists():
                summary_path = runner.output / (label + "-summary.json")
                result = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
                                        capture_output=True, text=True, timeout=60)
                summary_path.write_text(result.stdout if result.returncode == 0 else result.stderr)
                try:
                    if result.returncode:
                        raise ValueError("Could not export XCTest result summary")
                    require_executed(json.loads(result.stdout))
                    test["passed"] = code == 0
                except ValueError as error:
                    test["error"] = str(error)
            runner.receipt["tests"].append(test)
            runner.save()
        runner.receipt["status"] = "passed" if all(t["passed"] for t in runner.receipt["tests"]) else "failed"
    except (ValueError, OSError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        runner.receipt.update(status="failed", error=str(error))
        print(str(error), file=sys.stderr)
    finally:
        runner.save()
    return 0 if runner.receipt["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
