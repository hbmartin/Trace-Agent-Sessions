#!/usr/bin/env python3
"""Reject an exported app that is not ready for Developer ID notarization."""

import argparse
import os
import plistlib
import subprocess
import sys
from pathlib import Path


def codesign_output(*arguments: str) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        ["codesign", *arguments], capture_output=True, check=False
    )
    if result.returncode:
        detail = result.stderr.decode(errors="replace").strip()
        raise RuntimeError(detail or f"codesign exited {result.returncode}")
    return result


def signed_items(app: Path) -> list[Path]:
    items = {app}
    bundle_suffixes = {".app", ".appex", ".bundle", ".framework", ".xpc"}
    for root, directories, files in os.walk(app):
        parent = Path(root)
        for name in directories:
            item = parent / name
            if not item.is_symlink() and item.suffix in bundle_suffixes:
                items.add(item)
        for name in files:
            item = parent / name
            if item.is_symlink():
                continue
            if item.suffix in {".dylib", ".so"} or (
                parent.name in {"MacOS", "Helpers"} and os.access(item, os.X_OK)
            ):
                items.add(item)
    return sorted(items)


def signing_fields(item: Path) -> dict[str, list[str]]:
    output = codesign_output("-dv", "--verbose=4", str(item))
    fields: dict[str, list[str]] = {}
    for line in output.stderr.decode(errors="replace").splitlines():
        if line.startswith("CodeDirectory "):
            fields["CodeDirectory"] = [line]
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            fields.setdefault(key, []).append(value)
    return fields


def entitlements(item: Path) -> dict:
    output = codesign_output("-d", "--entitlements", ":-", str(item))
    data = output.stdout.strip()
    return plistlib.loads(data) if data else {}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="exported Trace.app")
    parser.add_argument("--team", required=True, help="expected Apple Developer team ID")
    parser.add_argument(
        "--identity", required=True, help="expected Developer ID Application identity"
    )
    arguments = parser.parse_args()

    if not (arguments.app / "Contents/MacOS/Trace").is_file():
        parser.error(f"Trace executable not found in {arguments.app}")

    try:
        codesign_output("--verify", "--deep", "--strict", str(arguments.app))
    except RuntimeError as error:
        print(f"error: exported app has an invalid signature: {error}", file=sys.stderr)
        return 1

    problems = []
    for item in signed_items(arguments.app):
        label = "." if item == arguments.app else str(item.relative_to(arguments.app))
        try:
            fields = signing_fields(item)
            rights = entitlements(item)
        except (RuntimeError, ValueError, plistlib.InvalidFileException) as error:
            problems.append(f"{label}: cannot inspect signature: {error}")
            continue

        if fields.get("TeamIdentifier", [None])[0] != arguments.team:
            problems.append(f"{label}: signed by the wrong team")
        if fields.get("Authority", [None])[0] != arguments.identity:
            problems.append(f"{label}: not signed by {arguments.identity}")
        if not fields.get("Timestamp"):
            problems.append(f"{label}: secure signing timestamp is missing")
        if not any("(runtime)" in value for value in fields.get("CodeDirectory", [])):
            problems.append(f"{label}: hardened runtime is missing")
        if "com.apple.security.get-task-allow" in rights:
            problems.append(f"{label}: get-task-allow must be absent from release code")

    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1

    print(f"Developer ID signing audit passed: {arguments.app}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
