#!/usr/bin/env python3
"""Keep XcodeGen's Trace scheme in the form saved by Xcode 27."""

import re
from pathlib import Path
from xml.etree import ElementTree


def normalize(text: str) -> str:
    root = ElementTree.fromstring(text)
    if root.tag != "Scheme":
        raise ValueError("Expected an Xcode scheme")

    # Match the containing XML element, not its formatting or action count.
    for element, attribute, value in (
        ("BuildAction", "runPostActionsOnFailure", "NO"),
        ("TestAction", "onlyGenerateCoverageForSpecifiedTargets", "NO"),
        ("TestableReference", "parallelizable", "NO"),
    ):
        tag = re.compile(rf"<{element}\b[^>]*>", re.DOTALL)
        default = re.compile(rf'\s+{attribute}\s*=\s*"{value}"')
        text = tag.sub(lambda match: default.sub("", match.group(0)), text)

    text = re.sub(
        r"(?m)^[ \t]*<CommandLineArguments>[ \t]*\n"
        r"[ \t]*</CommandLineArguments>[ \t]*\n",
        "",
        text,
    )
    ElementTree.fromstring(text)
    return text


if __name__ == "__main__":
    scheme = Path(__file__).resolve().parents[1] / "Trace.xcodeproj/xcshareddata/xcschemes/Trace.xcscheme"
    scheme.write_text(normalize(scheme.read_text()))
