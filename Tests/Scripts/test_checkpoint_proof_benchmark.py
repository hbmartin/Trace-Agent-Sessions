import importlib.util
from pathlib import Path
import unittest
import shutil
import subprocess
import tempfile

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

    def test_reversed_existing_probe_boundaries_are_rejected(self):
        source = (ROOT / 'Sources/TraceCore/Indexing/IndexScheduler.swift').read_text()
        reversed_source = source.replace(MODULE.BEGIN, '__END__').replace(MODULE.END, MODULE.BEGIN).replace('__END__', MODULE.END)
        with self.assertRaisesRegex(ValueError, 'Invalid instrumentation boundary order'):
            MODULE.instrument(reversed_source, source, synchronize_existing=True)

    def test_stamps_layout_counts_actual_prefix_storage(self):
        candidate = (ROOT / 'Sources/TraceCore/Indexing/IndexScheduler.swift').read_text()
        probe = candidate[candidate.index(MODULE.BEGIN):candidate.index(MODULE.END) + len(MODULE.END)]
        original = probe.replace('Control handshakes', 'Historical handshakes') + """
var stamps: [Stamp] = []
    public var checkpointBenchmarkCounts: [String: Int] {
        state.withLock { ["records": $0.streams.values.reduce(0) { $0 + $1.records.count }, "proofs": $0.proofs.count] }
    }
let measurement = CheckpointAcceptanceBenchmark.begin()
defer { CheckpointAcceptanceBenchmark.end(measurement) }
    public func waitUntilIdle() async {}
"""
        result = MODULE.instrument(original, candidate, synchronize_existing=True)
        self.assertIn('$1.unpaid.values.count + $1.paid.values.count', result)
        self.assertIn('"prefixIndexEntries"', result)
        self.assertIn('"heap-mark"', result)
        self.assertNotIn('"checkpointBoundaries"', result)
        self.assertEqual(MODULE.instrument(result, candidate, synchronize_existing=True), result)
        anchor = MODULE.COUNTS
        for replacement in ['', anchor + anchor]:
            with self.subTest(replacement=replacement):
                with self.assertRaisesRegex(ValueError, 'Missing unique existing'):
                    MODULE.instrument(original.replace(anchor, replacement), candidate, synchronize_existing=True)

    def test_kind_marker_cannot_authorize_count_or_kind_replacement(self):
        source = (ROOT / 'Sources/TraceCore/Indexing/IndexScheduler.swift').read_text()
        probe = source[source.index(MODULE.BEGIN):source.index(MODULE.END) + len(MODULE.END)]
        historical = probe + """
private struct Frontier {}
    public var checkpointBenchmarkCounts: [String: Int] {
        state.withLock { ["records": 999, "proofs": 0] }
    }
    public var checkpointBenchmarkPrefixIndexEntryKind: String { "frontier-node" }
let measurement = CheckpointAcceptanceBenchmark.begin()
defer { CheckpointAcceptanceBenchmark.end(measurement) }
    public func waitUntilIdle() async {}
"""
        with self.assertRaisesRegex(ValueError, 'explicit synchronization'):
            MODULE.instrument(historical, source)
        synchronized = MODULE.instrument(historical, source, synchronize_existing=True)
        self.assertEqual(MODULE.instrument(synchronized, source), synchronized)
        wrong_kind = synchronized.replace('"frontier-node"', '"wrong-kind"')
        with self.assertRaisesRegex(ValueError, 'explicit synchronization'):
            MODULE.instrument(wrong_kind, source)

    def test_same_probe_still_synchronizes_historical_counts(self):
        source = (ROOT / 'Sources/TraceCore/Indexing/IndexScheduler.swift').read_text()
        probe = source[source.index(MODULE.BEGIN):source.index(MODULE.END) + len(MODULE.END)]
        original = probe + """
private struct Frontier {}
    public var checkpointBenchmarkCounts: [String: Int] {
        state.withLock { ["records": $0.streams.values.reduce(0) { $0 + $1.records.count }, "proofs": $0.proofs.count, "checkpointBoundaries": 0] }
    }
let measurement = CheckpointAcceptanceBenchmark.begin()
defer { CheckpointAcceptanceBenchmark.end(measurement) }
    public func waitUntilIdle() async {}
"""
        result = MODULE.instrument(original, source, synchronize_existing=True)
        self.assertNotIn('"checkpointBoundaries"', result)
        self.assertIn('$1.frontier.count', result)
        self.assertIn('"frontier-node"', result)

    def test_mailbox_measurement_uses_delivery_completion_without_polling(self):
        source = (ROOT / 'Scripts/benchmark-source-ingress.swift').read_text()
        self.assertNotIn('while paths.count', source)
        self.assertNotIn('Task.yield()', source)
        self.assertIn('let delivered = try await completion.wait()', source)
        self.assertLess(source.index('let delivered = try await completion.wait()'), source.index('let result = try await producer.value'))
        self.assertIn('defer { producer.cancel(); deliveryDeadline.cancel() }', source)
        self.assertIn('phase: "producerTimeout"', source)
        self.assertIn('after enqueueing', source)
        self.assertIn('completion.finish(.success(WorkloadStamp()))', source)
        self.assertEqual(source.count('after: .seconds(30)'), 2)
        self.assertIn('final enqueue/delivery completion', source)

    @unittest.skipUnless(shutil.which('xcrun'), 'Requires the macOS Swift toolchain')
    def test_mailbox_completion_success_timeout_and_cancellation(self):
        source = (ROOT / 'Scripts/benchmark-source-ingress.swift').read_text()
        helper = source[source.index('private struct WorkloadStamp:'):source.index('@main struct SourceIngressWorkload')]
        harness = """
import Foundation
private func cpuSeconds() -> Double { 0 }
""" + helper + """
@main struct CompletionChecks {
    @MainActor static func main() async throws {
        for phase in ["producerTimeout", "incompleteDelivery"] {
            let failed = DeliveryCompletion()
            let deadline = Task { await mailboxDeadline(failed, after: .milliseconds(10), phase: phase, message: phase) }
            do { _ = try await failed.wait(); fatalError("Deadline ignored") }
            catch { precondition((error as NSError).domain == "MailboxBenchmark." + phase) }
            await deadline.value
            failed.finish(.success(WorkloadStamp()))
            do { _ = try await failed.wait(); fatalError("Late completion replaced deadline") }
            catch { precondition((error as NSError).domain == "MailboxBenchmark." + phase) }
        }
        let producerAlreadyFinished = DeliveryCompletion()
        await mailboxDeadline(producerAlreadyFinished, after: .milliseconds(1), phase: "producerTimeout", message: "ignored", unless: { true })
        producerAlreadyFinished.finish(.success(WorkloadStamp()))
        _ = try await producerAlreadyFinished.wait()
        let early = DeliveryCompletion()
        early.finish(.success(WorkloadStamp()))
        _ = try await early.wait()
        early.finish(.failure(CancellationError()))
        _ = try await early.wait()
        let cancelled = DeliveryCompletion()
        let waiting = Task { try await cancelled.wait() }
        waiting.cancel()
        do { _ = try await waiting.value; fatalError("Cancellation ignored") }
        catch is CancellationError {} catch { fatalError("Wrong cancellation") }
        let timeout = DeliveryCompletion()
        let timer = Task {
            try await Task.sleep(for: .milliseconds(10))
            timeout.finish(.failure(NSError(domain: "ExpectedTimeout", code: 7)))
        }
        do { _ = try await timeout.wait(); fatalError("Timeout ignored") }
        catch { precondition((error as NSError).domain == "ExpectedTimeout") }
        _ = try await timer.value
        timeout.finish(.success(WorkloadStamp()))
        do { _ = try await timeout.wait(); fatalError("Late success replaced timeout") }
        catch { precondition((error as NSError).domain == "ExpectedTimeout") }
    }
}
"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / 'checks.swift').write_text(harness)
            subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', str(path / 'checks.swift'), '-o', str(path / 'checks')], check=True, capture_output=True, text=True, timeout=60)
            subprocess.run([str(path / 'checks')], check=True, capture_output=True, text=True, timeout=10)

    def test_backlog_exports_are_outside_measured_slices(self):
        source = (ROOT / 'Scripts/benchmark-checkpoint-enqueue.swift').read_text()
        workload = source[source.index('private static func measureBacklog'):source.index('private static func measureAcceptance')]
        initial = workload.index('let initial = await scheduler.checkpointBenchmarkCounts()')
        stopped = workload.index('elapsed += seconds(start.duration(to: .now)); processCPU += cpuSeconds() - cpu')
        restarted = workload.index('start = .now; cpu = cpuSeconds()')
        self.assertLess(stopped, initial)
        self.assertLess(initial, restarted)
        self.assertLess(workload.rindex('elapsed += seconds'), workload.index('let stuck = await'))

    def test_mailbox_extraction_includes_actual_normalization_and_enrollment(self):
        spec = importlib.util.spec_from_file_location('ingress_extraction', ROOT / 'Scripts/prepare-source-ingress-benchmark.py')
        extraction = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(extraction)
        source = (ROOT / 'Sources/TraceApp/TraceModel.swift').read_text()
        generated = extraction.extract(source)
        self.assertIn('SourceIngressMailbox.normalizeTranscript', generated)
        self.assertIn('delivery.enrolled(in:', generated)
        self.assertIn('mainActorPreparationElapsedSeconds', generated)
        with self.assertRaisesRegex(ValueError, 'Missing unique'):
            extraction.extract(source + 'final class SourceIngressMailbox: Sendable {')

    def test_both_mailbox_layouts_prepare_shared_setup_before_enqueue(self):
        spec = importlib.util.spec_from_file_location('ingress_setup', ROOT / 'Scripts/prepare-source-ingress-benchmark.py')
        extraction = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(extraction)
        current = (ROOT / 'Sources/TraceApp/TraceModel.swift').read_text()
        historical = """final class SourceIngressMailbox: Sendable {}
@MainActor
enum ModelPublicationBatch {}
    private func normalizeTranscriptChanges(_ changes: SourceChanges) -> (changes: SourceChanges, recoveryEligible: Bool) {
        return (changes, false)
    }
"""
        for source in [current, historical]:
            generated = extraction.extract(source)
            factory = generated[generated.index('@MainActor func makeBenchmarkMailbox'):]
            self.assertLess(factory.index('IngressMeasurement.roots'), factory.index('return SourceIngressMailbox'))
            self.assertLess(factory.index('IngressMeasurement.ledger'), factory.index('return SourceIngressMailbox'))

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
