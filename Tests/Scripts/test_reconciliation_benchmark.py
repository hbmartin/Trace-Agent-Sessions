import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('reconciliation_probe', ROOT/'Scripts/prepare-reconciliation-benchmark.py')
MODULE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MODULE)


class ReconciliationInstrumentationTests(unittest.TestCase):
    def test_exported_instrumentation_is_idempotent_and_flag_gated(self):
        source = (ROOT/'Sources/TraceCore/Database/IndexDatabase.swift').read_text()
        result = MODULE.instrument(source)
        self.assertEqual(MODULE.instrument(result), result)
        self.assertEqual(result.count(MODULE.PROBE), 1)
        self.assertIn('#if TRACE_CHECKPOINT_BENCHMARK', result)
        self.assertIn('measureReconciliationRow('+MODULE.EXPRESSION+')', result)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); path = root/'Sources/TraceCore/Database/IndexDatabase.swift'
            path.parent.mkdir(parents=True); path.write_text(source)
            receipt = MODULE.prepare(root)
            self.assertNotEqual(receipt['sourceSHA256'], receipt['instrumentedSHA256'])
            (root/'.git').mkdir()
            with self.assertRaisesRegex(ValueError, 'exported'):
                MODULE.prepare(root)

    def test_missing_duplicate_and_conflicting_boundaries_do_not_write(self):
        source = (ROOT/'Sources/TraceCore/Database/IndexDatabase.swift').read_text()
        for value in [source.replace(MODULE.EXPRESSION, 'unknown'),
                      source.replace(MODULE.EXPRESSION, MODULE.EXPRESSION+'; '+MODULE.EXPRESSION),
                      source+'\nreconciliationBenchmarkDecodedRows',
                      MODULE.instrument(source).replace('+= 1', '+= 2')]:
            with self.subTest(value=value[-60:]), self.assertRaises(ValueError): MODULE.instrument(value)

    def test_benchmark_exit_occurs_after_cleanup_and_read_context_is_forwarded(self):
        for name in ['benchmark-incremental-reconciliation.swift', 'benchmark-navigation-admission.swift']:
            source=(ROOT/'Scripts'/name).read_text()
            self.assertIn('exit(await run())',source)
            self.assertIn('return correct ? 0 : 2',source)
            self.assertNotIn('exit(2)',source)
            self.assertIn('defer { try? FileManager.default.removeItem',source)
        source=(ROOT/'Scripts/benchmark-navigation-admission.swift').read_text()
        self.assertIn('base.records(in: file, from: offset, through: boundary, initialSessionID: initialSessionID)',source)
        self.assertIn('base.records(in: file, from: offset, through: boundary, initialContext: initialContext)',source)
        self.assertNotIn('sessions[0]',source)
        self.assertEqual(source.count('let phaseCPU = cpu()'),1)
        self.assertNotIn('let callCPU = cpu()',source)
        self.assertIn('retirementProcessCPUSeconds',source)

    def test_fixture_readiness_is_atomic_and_cleanup_covers_setup_failures(self):
        source=(ROOT/'Scripts/benchmark-process-cleanup.py').read_text()
        self.assertIn("pending.replace(sys.argv[1])",source)
        self.assertIn('if descendant is None and child.returncode is None:',source)


if __name__ == '__main__': unittest.main()
