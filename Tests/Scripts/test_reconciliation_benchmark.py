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
        result = MODULE.instrument(source, layout='connection-matcher')
        self.assertEqual(MODULE.instrument(result, layout='connection-matcher'), result)
        self.assertEqual(result.count(MODULE.probe('connection-matcher')), 1)
        self.assertIn('#if TRACE_CHECKPOINT_BENCHMARK', result)
        self.assertIn(MODULE.WRAPPED, result)
        self.assertIn('public func reconciliationBenchmarkQuery(', result)
        self.assertIn('public func reconciliationBenchmarkRoot(', result)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); path = root/'Sources/TraceCore/Database/IndexDatabase.swift'
            path.parent.mkdir(parents=True); path.write_text(source)
            receipt = MODULE.prepare(root, layout='connection-matcher')
            self.assertNotEqual(receipt['sourceSHA256'], receipt['instrumentedSHA256'])
            repeated = MODULE.prepare(root, layout='connection-matcher')
            self.assertEqual(receipt['sourceSHA256'], repeated['sourceSHA256'])
            self.assertEqual(receipt['instrumentedSHA256'], repeated['inputSHA256'])
            self.assertEqual(MODULE.original_source(path.read_text(), layout='connection-matcher'), source)
            (root/'.git').mkdir()
            with self.assertRaisesRegex(ValueError, 'exported'):
                MODULE.prepare(root, layout='connection-matcher')

    def test_missing_duplicate_and_conflicting_boundaries_do_not_write(self):
        source = (ROOT/'Sources/TraceCore/Database/IndexDatabase.swift').read_text()
        for value in [source.replace(MODULE.EXPRESSION, 'unknown'),
                      source.replace(MODULE.EXPRESSION, MODULE.EXPRESSION+'; '+MODULE.EXPRESSION),
                      source+'\nreconciliationBenchmarkDecodedRows',
                      MODULE.instrument(source, layout='connection-matcher').replace('+= 1', '+= 2')]:
            with self.subTest(value=value[-60:]), self.assertRaises(ValueError): MODULE.instrument(value, layout='connection-matcher')

    def test_explicit_layout_and_query_policy_metrics(self):
        source=(ROOT/'Sources/TraceCore/Database/IndexDatabase.swift').read_text()
        with self.assertRaisesRegex(ValueError,'explicit layout'):MODULE.instrument(source,layout='pr106')
        with self.assertRaisesRegex(ValueError,'Unsupported'):MODULE.instrument(source,layout='missing')
        baseline=source.replace(MODULE.CACHE_ANCHOR,'').replace(MODULE.CONNECTION_ANCHOR,MODULE.FALLBACK_ANCHOR)
        result=MODULE.instrument(baseline,layout='pr106')
        self.assertEqual(result.count(MODULE.FALLBACK_CALL),1)
        self.assertNotIn(MODULE.CLASSIFICATION_CALL,result)
        workload=(ROOT/'Scripts/benchmark-incremental-reconciliation.swift').read_text()
        for field in ['capturedRootPolicies','forcedQueryCaseSensitive','coldQueryElapsedSeconds','coldQueryProcessCPUSeconds','warmQueryCount','queryState']:
            self.assertIn(field,workload)
        self.assertIn('query-sensitive-ascii',workload)
        self.assertIn('query-sensitive-mixed',workload)
        query=workload[workload.index('            if queryMode {'):workload.index('            for index in queryMode ?')]
        self.assertEqual(query.count('let cpuStart = cpu(), start = ContinuousClock.now'),1)

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

    def test_atomic_preparation_failure_preserves_original_and_mode(self):
        source = (ROOT/'Sources/TraceCore/Database/IndexDatabase.swift').read_text()
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);path=root/'Sources/TraceCore/Database/IndexDatabase.swift'
            path.parent.mkdir(parents=True);path.write_text(source);path.chmod(0o640)
            with patch.object(Path,'replace',side_effect=PermissionError('injected replacement failure')):
                with self.assertRaises(PermissionError):MODULE.prepare(root,layout='connection-matcher')
            self.assertEqual(path.read_text(),source)
            self.assertEqual(list(path.parent.glob('*.tmp')),[])
            MODULE.prepare(root,layout='connection-matcher')
            self.assertEqual(path.stat().st_mode & 0o777,0o640)

    def test_interruption_after_descriptor_release_does_not_double_close(self):
        import json, subprocess, sys
        program="""import importlib.util,json,os,signal,sys
spec=importlib.util.spec_from_file_location('benchmark',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
close=m.os.close
class Child:
 pid=987654321
 returncode=0
 def wait(self,timeout):return 0
state={'descriptor':None,'injected':False}
def launching(args,**kwargs):
 state['descriptor']=int(args[-1]);return Child()
def releasing(fd):
 close(fd)
 if fd==state['descriptor'] and not state['injected']:
  state['injected']=True;signal.raise_signal(signal.SIGTERM)
m.subprocess.Popen=launching;m.os.close=releasing
sys.argv=['benchmark','--runner',sys.argv[2],'--mode','live']
sys.exit(m.main())
"""
        with tempfile.TemporaryDirectory() as temp:
            runner=Path(temp)/'runner.py'
            runner.write_text('def cleanup_child(child): pass\ndef process_group_members(group): return []\n')
            value=subprocess.run([sys.executable,'-c',program,str(ROOT/'Scripts/benchmark-process-cleanup.py'),str(runner)],capture_output=True,text=True,timeout=20)
        self.assertEqual(value.returncode,143,value.stdout+value.stderr)
        result=json.loads(value.stdout.splitlines()[-1])
        self.assertEqual(result['interruptedSignal'],15)
        self.assertNotIn('fixtureCleanupErrors',result,value.stderr)

    def test_fixture_readiness_is_atomic_and_cleanup_covers_setup_failures(self):
        source=(ROOT/'Scripts/benchmark-process-cleanup.py').read_text()
        self.assertIn("pending.replace(sys.argv[1])",source)
        self.assertIn('shutdown_read, shutdown_write = os.pipe()',source)
        self.assertNotIn('os.kill(descendant',source)
        self.assertNotIn('os.killpg(child.pid',source)


if __name__ == '__main__': unittest.main()
