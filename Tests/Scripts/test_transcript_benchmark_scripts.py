import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"


class TranscriptBenchmarkScriptTests(unittest.TestCase):
    def test_incomplete_metric_export_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, identifiers in [("baseline", ["cpu", "clock"]), ("candidate", ["cpu"])]:
                report = [{"testIdentifier": "testTranscriptScrollPerformance()", "testRuns": [{
                    "metrics": [{"identifier": identifier, "displayName": identifier,
                                 "measurements": [1, 2, 3]} for identifier in identifiers]
                }]}]
                (root / f"{name}.json").write_text(json.dumps(report))
            result = subprocess.run([
                sys.executable, str(SCRIPTS / "compare-transcript-scroll-metrics.py"),
                str(root / "baseline.json"), str(root / "candidate.json"),
            ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("baseline only=['clock']", result.stderr)
            self.assertNotIn("improvement", result.stdout)

    def test_relative_paths_and_xcodebuild_failure_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            caller = root / "caller"
            caller.mkdir()
            binary = root / "bin"
            binary.mkdir()
            arguments = root / "arguments.json"
            fake_build = binary / "xcodebuild"
            fake_build.write_text(f"#!{sys.executable}\n" + """
import json, os, sys
from pathlib import Path
Path(os.environ['TRACE_FAKE_ARGUMENTS']).write_text(json.dumps(sys.argv[1:]))
Path(sys.argv[sys.argv.index('-resultBundlePath') + 1]).mkdir(parents=True)
sys.exit(23)
""")
            fake_build.chmod(0o755)
            fake_export = binary / "xcrun"
            fake_export.write_text("#!/bin/sh\nprintf '{}\\n'\n")
            fake_export.chmod(0o755)
            environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                               TRACE_FAKE_ARGUMENTS=str(arguments),
                               TRACE_SCROLL_BENCHMARK_OUTPUT_DIR="results",
                               TRACE_SCROLL_DERIVED_DATA_PATH="../derived")
            result = subprocess.run([str(SCRIPTS / "measure-transcript-scroll.sh")],
                                    cwd=caller, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 23)
            args = json.loads(arguments.read_text())
            self.assertEqual(Path(args[args.index("-resultBundlePath") + 1]).resolve(),
                             (caller / "results/TranscriptScroll.xcresult").resolve())
            self.assertEqual(Path(args[args.index("-derivedDataPath") + 1]).resolve(),
                             (root / "derived").resolve())
            self.assertTrue((caller / "results/xcodebuild.log").exists())
            self.assertTrue((caller / "results/metrics.json").exists())


if __name__ == "__main__":
    unittest.main()
