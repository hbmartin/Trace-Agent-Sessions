import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/normalize-trace-scheme.py"
spec = importlib.util.spec_from_file_location("normalize_trace_scheme", SCRIPT)
normalizer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(normalizer)


class NormalizeTraceSchemeTests(unittest.TestCase):
    def test_optional_defaults_and_idempotence(self):
        scheme = """<?xml version="1.0"?>
<Scheme>
  <BuildAction runPostActionsOnFailure="NO" buildImplicitDependencies="YES" />
  <BuildAction buildImplicitDependencies="YES" />
  <TestAction onlyGenerateCoverageForSpecifiedTargets="NO" codeCoverageEnabled="YES">
    <TestableReference parallelizable="NO" skipped="NO" />
    <TestableReference skipped="NO" parallelizable="NO" />
    <TestableReference parallelizable="YES" skipped="NO" />
  </TestAction>
  <LaunchAction>
    <CommandLineArguments>
    </CommandLineArguments>
    <CommandLineArguments><CommandLineArgument argument="keep" /></CommandLineArguments>
  </LaunchAction>
</Scheme>
"""
        result = normalizer.normalize(scheme)
        self.assertNotIn('runPostActionsOnFailure="NO"', result)
        self.assertNotIn('onlyGenerateCoverageForSpecifiedTargets="NO"', result)
        self.assertNotIn('parallelizable="NO"', result)
        self.assertIn('parallelizable="YES"', result)
        self.assertIn('argument="keep"', result)
        self.assertEqual(result.count("<CommandLineArguments>"), 1)
        self.assertEqual(normalizer.normalize(result), result)


if __name__ == "__main__":
    unittest.main()
