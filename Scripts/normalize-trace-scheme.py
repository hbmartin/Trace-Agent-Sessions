#!/usr/bin/env python3
"""Keep XcodeGen's Trace scheme in the form saved by Xcode 27."""

from pathlib import Path

scheme = Path(__file__).resolve().parents[1] / "Trace.xcodeproj/xcshareddata/xcschemes/Trace.xcscheme"
text = scheme.read_text()
replacements = [
    ('      buildImplicitDependencies = "YES"\n      runPostActionsOnFailure = "NO">',
     '      buildImplicitDependencies = "YES">', 1),
    ('      codeCoverageEnabled = "YES"\n      onlyGenerateCoverageForSpecifiedTargets = "NO">',
     '      codeCoverageEnabled = "YES">', 1),
    ('            skipped = "NO"\n            parallelizable = "NO">',
     '            skipped = "NO">', 1),
    ('      <CommandLineArguments>\n      </CommandLineArguments>\n', '', 3),
]
for before, after, expected in replacements:
    actual = text.count(before)
    if actual != expected:
        raise SystemExit(f"Unexpected generated Trace scheme: expected {expected} copies of {before!r}, found {actual}")
    text = text.replace(before, after)
scheme.write_text(text)
