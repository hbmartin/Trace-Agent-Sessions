#!/usr/bin/env python3
"""Validate three local Release pairs and enforce the local 10% acceptance policy."""
import argparse
import importlib.util
import json
import math
import statistics
import subprocess
import sys
from pathlib import Path

BASELINE = '61c00dec21762408980afe1a476cfcdb3f859437'
ORDERS = [['baseline', 'candidate'], ['candidate', 'baseline'], ['baseline', 'candidate']]
spec = importlib.util.spec_from_file_location('comparison', Path(__file__).with_name('compare-transcript-scroll-metrics.py'))
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


def percentage(before, after):
    return (after - before) / abs(before) * 100 if before else (0 if after <= 0 else math.inf)


def summarize_pair(directory):
    metadata = json.loads((directory / 'metadata.json').read_text())
    if metadata['locale'] != 'en_US' or metadata['baseline_commit'] != BASELINE:
        raise ValueError('Pair uses a different baseline or locale')
    if metadata.get('build_inputs_validated') is not True:
        raise ValueError('Pair is missing completed build-input validation')
    for revision in ['baseline', 'candidate']:
        before = metadata.get(revision + '_build_inputs')
        after = metadata.get(revision + '_build_inputs_after')
        if not before or before != after or before.get('.', {}).get('commit') != metadata[revision + '_commit']:
            raise ValueError('Pair build-input provenance differs: ' + revision)
        for phase in ['before-baseline', 'after-baseline', 'before-candidate', 'after-candidate', 'after']:
            recorded = json.loads((directory / (revision + '-build-inputs.' + phase + '.json')).read_text())
            if recorded != before:
                raise ValueError('Pair build inputs changed: ' + revision + ' ' + phase)
    host = json.loads((directory / 'host-session-check.json').read_text())
    if not host.get('valid') or host.get('competingSessionObservations') or host.get('processExitCode', 0) != 0:
        raise ValueError('Pair overlaps another UI/build/profiling session')
    baseline, candidate = [directory / revision / 'metrics.json' for revision in ('baseline', 'candidate')]
    subprocess.run([sys.executable, str(Path(__file__).with_name('compare-transcript-scroll-metrics.py')),
                    str(baseline), str(candidate)], check=True, capture_output=True, text=True)
    workloads = {}
    for method, (workload, count) in comparison.WORKLOADS.items():
        reports = [comparison.metrics_for(path, method) for path in (baseline, candidate)]
        app = [comparison.app_samples(path, workload, count) for path in (baseline, candidate)]
        values = {}
        for name, prefix, suffix, scale in [('cpuSeconds', 'XCTMetric_CPU-', '.time', 1),
                ('clockSeconds', 'XCTMetric_Clock.', '.time.monotonic', 1),
                ('xctestGrowthBytes', 'XCTMetric_Memory-', '.physical', 1000)]:
            key = next(key for key in reports[0] if prefix in key and key.endswith(suffix))
            values[name] = [[value * scale for value in report[key][1]] for report in reports]
        for field in app[0]: values[field] = [sample[field] for sample in app]
        values['retainedGrowthBytes'] = [[end - start for end, start in zip(sample['retainedFootprintBytes'], sample['startingFootprintBytes'])]
                                        for sample in app]
        values['retainedDriftBytes'] = [[sample['retainedFootprintBytes'][-1] - sample['retainedFootprintBytes'][0]] for sample in app]
        medians = {name: [statistics.median(side) for side in sides] for name, sides in values.items()}
        changes = {name: percentage(*medians[name]) for name in ['cpuSeconds', 'clockSeconds', 'sampledPeakFootprintBytes', 'retainedFootprintBytes']}
        denominator = medians['startingFootprintBytes'][0]
        for name in ['xctestGrowthBytes', 'retainedGrowthBytes', 'retainedDriftBytes']:
            changes[name] = (medians[name][1] - medians[name][0]) / denominator * 100
        counters = [name for name, (_, old, _) in reports[0].items()
                    if ('instructions' in name or 'cycles' in name) and all(value == 0 for value in old + reports[1][name][1])]
        counter_availability = {}
        for revision, report in zip(['baseline', 'candidate'], reports):
            counter_availability[revision] = {}
            for counter in ['cycles', 'instructions']:
                exported = [values for key, (_, values, _) in report.items() if counter in key]
                counter_availability[revision][counter] = ('not-exported' if not exported else
                    ('unavailable-zero-export' if all(value == 0 for values in exported for value in values) else 'available'))
        workloads[workload] = {'individualSamples': values, 'medians': medians,
                              'medianMiB': {name: [value / 1_048_576 for value in sides]
                                            for name, sides in medians.items() if name.endswith('Bytes')},
                              'pairedChangePercent': changes, 'unavailableHardwareCounters': counters,
                              'hardwareCounterAvailability': counter_availability}
    return {'metadata': metadata, 'workloads': workloads}


def evaluate(directories, tolerance=10, candidate_commit=None):
    if len(directories) != 3: raise ValueError('Exactly three pairs are required')
    pairs = [summarize_pair(directory) for directory in directories]
    first = pairs[0]['metadata']
    if candidate_commit is not None and first['candidate_commit'] != candidate_commit:
        raise ValueError('Pair uses a different candidate commit')
    for index, pair in enumerate(pairs):
        metadata = pair['metadata']
        if metadata['order'] != ORDERS[index]: raise ValueError('Unexpected pair revision order')
        for key in ['candidate_commit', 'identical_harness_files', 'toolchain', 'candidate_build_inputs', 'baseline_build_inputs']:
            if metadata[key] != first[key]: raise ValueError('Pair provenance differs: ' + key)
    aggregate, aggregate_medians, failures = {}, {}, []
    for workload in pairs[0]['workloads']:
        metrics = pairs[0]['workloads'][workload]['pairedChangePercent']
        aggregate[workload] = {}
        aggregate_medians[workload] = {
            name: [statistics.median(pair['workloads'][workload]['medians'][name][side] for pair in pairs)
                   for side in (0, 1)]
            for name in pairs[0]['workloads'][workload]['medians']
        }
        for metric in metrics:
            change = statistics.median(pair['workloads'][workload]['pairedChangePercent'][metric] for pair in pairs)
            aggregate[workload][metric] = change if math.isfinite(change) else None
            if change > tolerance and not math.isclose(change, tolerance, rel_tol=1e-12, abs_tol=1e-9):
                failures.append({'workload': workload, 'metric': metric, 'changePercent': change if math.isfinite(change) else None})
    # A zero CPU baseline followed by positive usage is an unbounded regression.
    for pair in pairs:
        for workload in pair['workloads'].values():
            workload['pairedChangePercent'] = {key: value if math.isfinite(value) else None
                                                for key, value in workload['pairedChangePercent'].items()}
    return {'status': 'failed' if failures else 'passed', 'tolerancePercent': tolerance,
            'units': {'cpuSeconds': 'seconds', 'clockSeconds': 'seconds', 'footprintAndGrowth': 'bytes',
                      'updateDurations': 'nanoseconds', 'pairedChanges': 'percent',
                      'growthChanges': 'percent of baseline median starting footprint'},
            'pairs': pairs, 'aggregateMedians': aggregate_medians,
            'aggregateMedianMiB': {workload: {name: [value / 1_048_576 for value in sides]
                for name, sides in medians.items() if name.endswith('Bytes')}
                for workload, medians in aggregate_medians.items()},
            'aggregatePairedChangePercent': aggregate, 'regressions': failures}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pairs', nargs=3, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--tolerance-percent', type=float, default=10)
    parser.add_argument('--candidate-commit')
    args = parser.parse_args()
    if not math.isfinite(args.tolerance_percent) or args.tolerance_percent < 0: parser.error('Invalid tolerance')
    try: report = evaluate(args.pairs, args.tolerance_percent, args.candidate_commit)
    except (ValueError, KeyError, FileNotFoundError, subprocess.CalledProcessError) as error:
        raise SystemExit('Local benchmark validation failed: ' + str(error))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    print('Local performance acceptance: ' + report['status'])
    for failure in report['regressions']: print(json.dumps(failure))
    raise SystemExit(1 if report['regressions'] else 0)
