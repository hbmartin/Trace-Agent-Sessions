#!/usr/bin/env python3
"""Compare identical TracePerformance xcresult metric exports."""

import argparse
import json
import statistics
from pathlib import Path


def metrics_for(path: Path, test_name: str) -> dict[str, tuple[str, list[float]]]:
    report = json.loads(path.read_text())
    for test in report:
        if test["testIdentifier"].endswith(test_name):
            return {
                metric["identifier"]: (metric["displayName"], metric["measurements"])
                for run in test["testRuns"]
                for metric in run["metrics"]
            }
    raise SystemExit(f"{test_name} was not found in {path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path, help="baseline metrics.json")
    parser.add_argument("candidate", type=Path, help="candidate metrics.json")
    parser.add_argument(
        "--test", default="testTranscriptScrollPerformance()",
        help="performance test method to compare",
    )
    args = parser.parse_args()
    before = metrics_for(args.baseline, args.test)
    after = metrics_for(args.candidate, args.test)
    if before.keys() != after.keys():
        raise SystemExit(
            "Metric identifiers differ: "
            f"baseline only={sorted(before.keys() - after.keys())}; "
            f"candidate only={sorted(after.keys() - before.keys())}"
        )
    shared = before.keys()
    if not shared:
        raise SystemExit("No matching metrics were found")
    for identifier in sorted(shared):
        name, baseline_values = before[identifier]
        _, candidate_values = after[identifier]
        baseline = statistics.median(baseline_values)
        candidate = statistics.median(candidate_values)
        lift = (baseline - candidate) / baseline * 100 if baseline else 0
        print(f"{name}: {baseline:.3f} -> {candidate:.3f} ({lift:+.1f}% improvement)")
        print(f"  baseline={baseline_values}")
        print(f"  candidate={candidate_values}")


if __name__ == "__main__":
    main()
