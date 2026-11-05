import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('checkpoint_instrumentation', ROOT / 'Scripts/instrument-checkpoint-benchmark.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CheckpointProofBenchmarkTests(unittest.TestCase):
    def test_current_instrumentation_is_idempotent(self):
        source = (ROOT / 'Sources/TraceCore/Indexing/IndexScheduler.swift').read_text()
        self.assertEqual(MODULE.instrument(source, source), source)

    def test_historical_acceptance_gets_the_same_probe(self):
        original = '''/// Durable checkpoint value
fileprivate func accept(_ coverage: Coverage, ignored: Bool) {
        guard !coverage.entries.isEmpty else { return .committed([:]) }
}
    #if DEBUG || TRACE_CHECKPOINT_BENCHMARK
    var retainedRecordCount: Int { 0 }
    public func waitUntilIdle() async {}
'''
        candidate = (ROOT / 'Sources/TraceCore/Indexing/IndexScheduler.swift').read_text()
        result = MODULE.instrument(original, candidate)
        self.assertIn('defer { CheckpointAcceptanceBenchmark.end(measurement) }', result)
        self.assertEqual(result.count('// BEGIN CHECKPOINT ACCEPTANCE MEASUREMENT'), 1)
        self.assertIn('counts["proofs"] = pendingCheckpointAcceptances.count', result)
        self.assertEqual(MODULE.instrument(result, candidate), result)

    def test_missing_and_duplicate_secondary_anchors_are_rejected(self):
        original = """/// Durable checkpoint value
fileprivate func accept(_ coverage: Coverage, ignored: Bool) {
        guard !coverage.entries.isEmpty else { return .committed([:]) }
}
    #if DEBUG || TRACE_CHECKPOINT_BENCHMARK
    var retainedRecordCount: Int { 0 }
    public func waitUntilIdle() async {}
"""
        candidate = (ROOT / 'Sources/TraceCore/Indexing/IndexScheduler.swift').read_text()
        for anchor in ['    #if DEBUG || TRACE_CHECKPOINT_BENCHMARK\n    var retainedRecordCount:', '    public func waitUntilIdle()']:
            for replacement in ['', anchor + anchor]:
                with self.subTest(anchor=anchor, replacement=replacement):
                    with self.assertRaisesRegex(ValueError, 'Missing unique historical'):
                        MODULE.instrument(original.replace(anchor, replacement), candidate)

    def test_acceptance_cpu_is_thread_scoped(self):
        source = (ROOT / 'Sources/TraceCore/Indexing/IndexScheduler.swift').read_text()
        probe = source[source.index('// BEGIN CHECKPOINT ACCEPTANCE'):source.index('// END CHECKPOINT ACCEPTANCE')]
        self.assertIn('thread_info(', probe)
        self.assertIn('stamp.thread ==', probe)
        thread_counter = probe[probe.index('private static func cpuSeconds'):probe.index('private static func processCPUSeconds')]
        self.assertNotIn('RUSAGE_SELF', thread_counter)
        self.assertIn('processCPUSecondsDuringAcceptance', probe)

    def test_unknown_baseline_is_rejected(self):
        source = (ROOT / 'Sources/TraceCore/Indexing/IndexScheduler.swift').read_text()
        with self.assertRaisesRegex(ValueError, 'Unsupported baseline'):
            MODULE.instrument('unrecognized source', source)

    def test_conflicting_probe_is_rejected(self):
        source = (ROOT / 'Sources/TraceCore/Indexing/IndexScheduler.swift').read_text()
        with self.assertRaisesRegex(ValueError, 'Different acceptance instrumentation'):
            MODULE.instrument(source.replace('Control handshakes', 'Different handshakes'), source)

    def test_existing_probe_requires_explicit_synchronization(self):
        source = (ROOT / 'Sources/TraceCore/Indexing/IndexScheduler.swift').read_text()
        old = source.replace('Control handshakes', 'Historical handshakes')
        self.assertEqual(MODULE.instrument(old, source, synchronize_existing=True), source)
        with self.assertRaisesRegex(ValueError, 'Missing unique existing'):
            MODULE.instrument(old.replace('defer { CheckpointAcceptanceBenchmark.end(measurement) }', ''), source, synchronize_existing=True)

    def test_backlog_exports_are_outside_measured_slices(self):
        source = (ROOT / 'Scripts/benchmark-checkpoint-enqueue.swift').read_text()
        workload = source[source.index('private static func measureBacklog'):source.index('private static func measureAcceptance')]
        initial = workload.index('let initial = await scheduler.checkpointBenchmarkCounts()')
        stopped = workload.index('elapsed += seconds(start.duration(to: .now)); processCPU += cpuSeconds() - cpu')
        restarted = workload.index('start = .now; cpu = cpuSeconds()')
        self.assertLess(stopped, initial)
        self.assertLess(initial, restarted)
        self.assertLess(workload.rindex('elapsed += seconds'), workload.index('let stuck = await'))

    def test_acceptance_cannot_be_rescued_by_a_cleanup_scan(self):
        source = (ROOT / 'Scripts/benchmark-checkpoint-enqueue.swift').read_text()
        acceptance = source[source.index('private static func measureAcceptance'):]
        after_ingress = acceptance[acceptance.index('let latencies ='):]
        self.assertNotIn('request(reconcile: true', after_ingress)
        self.assertIn('CheckpointAcceptanceBenchmark.snapshot()', after_ingress)
        self.assertNotIn('start.duration(to: .now)', after_ingress)
        ingress = source[source.index('private static func reserveIngress'):source.index('private static func measureAcceptance')]
        self.assertLess(ingress.index('latencies.append'), ingress.index('await gate.release'))


if __name__ == '__main__':
    unittest.main()
