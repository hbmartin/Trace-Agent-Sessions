#!/usr/bin/env python3
"""Validate and compare CPU, clock, app memory growth, timings, and footprints."""
import argparse
import json
import math
import statistics
from pathlib import Path

WORKLOADS = {
    'testTranscriptScrollPerformance()': ('scroll', 5),
    'testStreamingTranscriptFollowPerformance()': ('streaming', 3),
    'testExternalSidecarTrafficPerformance()': ('watcher', 5),
}
# IDs emitted by TracePerformanceTests: the unreported XCTest warm-up and
# the increment between measurement invocations (streaming appends ten messages).
WARMUP_ITERATIONS = {'scroll': (2, 1), 'streaming': (70, 10), 'watcher': (1, 1)}


def metrics_for(path, test_name):
    report = json.loads(path.read_text())
    for test in report:
        if test['testIdentifier'].endswith(test_name):
            return {metric['identifier']: (metric['displayName'], metric['measurements'], metric.get('unitOfMeasurement'))
                    for run in test['testRuns'] for metric in run['metrics']}
    raise SystemExit(f'{test_name} was not found in {path}')


def app_samples(path, workload, count):
    source = path.parent / 'app-samples.json'
    if not source.exists():
        raise SystemExit(f'Missing memory/timing records: {source}')
    records = json.loads(source.read_text())
    if not isinstance(records, list) or any(not isinstance(s, dict) or not isinstance(s.get('id'), str) for s in records):
        raise SystemExit(f'Missing/invalid memory/timing records: {source}')
    warmup, step = WARMUP_ITERATIONS[workload]
    expected_ids = [f'{workload}-{warmup + step * index}' for index in range(1, count + 1)]
    by_id = {}
    for sample in records:
        identifier = sample['id']
        if not identifier.startswith(workload + '-'):
            continue
        if identifier in by_id:
            raise SystemExit(f'Duplicate {workload} memory/timing record: {identifier}')
        by_id[identifier] = sample
    unexpected = sorted(by_id.keys() - set(expected_ids) - {f'{workload}-{warmup}'})
    if unexpected:
        raise SystemExit(f'Unexpected {workload} iteration IDs: {unexpected}')
    missing = [identifier for identifier in expected_ids if identifier not in by_id]
    if missing:
        raise SystemExit(f'Missing {workload} memory/timing records for iterations: {missing}')
    # XCTest performs an unreported warm-up iteration. Keep it in raw exports,
    # but compare only the iterations represented in its CPU/clock metric arrays.
    samples = [by_id[identifier] for identifier in expected_ids]
    fields = ['updateCount', 'totalUpdateNanoseconds', 'maximumUpdateNanoseconds',
              'startingFootprintBytes', 'sampledPeakFootprintBytes', 'endingFootprintBytes',
              'retainedFootprintBytes', 'footprintSampleCount']
    for sample in samples:
        for field in fields:
            if not isinstance(sample.get(field), (float, int)) or not math.isfinite(sample[field]) or sample[field] < 0:
                raise SystemExit(f'Missing/invalid {field} in {sample.get("id")}')
            if workload in ('streaming', 'watcher') and field in fields[:3] and sample[field] == 0:
                raise SystemExit(f'Missing recorded {field} in {sample["id"]}')
        if min(sample[f] for f in fields[3:7]) <= 0 or sample['footprintSampleCount'] <= 1:
            raise SystemExit(f'Missing footprint samples in {sample["id"]}')
        if sample['sampledPeakFootprintBytes'] < max(sample['startingFootprintBytes'], sample['endingFootprintBytes']):
            raise SystemExit(f'Invalid sampled peak in {sample["id"]}')
    return {field: [s[field] for s in samples] for field in fields}


def compare(name, baseline_values, candidate_values, scale=1, unit=''):
    before, after = map(statistics.median, (baseline_values, candidate_values))
    change = (after - before) / abs(before) * 100 if before else None
    delta = f'{change:+.1f}% change' if change is not None else 'zero baseline'
    print(f'{name}: {before / scale:.3f}{unit} -> {after / scale:.3f}{unit} ({delta})')
    print(f'  baseline={baseline_values}')
    print(f'  candidate={candidate_values}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--test', help='compare a single test; defaults to all three workloads')
    args = parser.parse_args()
    tests = [args.test] if args.test else WORKLOADS
    for test in tests:
        before, after = metrics_for(args.baseline, test), metrics_for(args.candidate, test)
        if before.keys() != after.keys():
            raise SystemExit('Metric identifiers differ: '
                f'baseline only={sorted(before.keys() - after.keys())}; '
                f'candidate only={sorted(after.keys() - before.keys())}')
        if not before:
            raise SystemExit('No matching metrics were found')
        required = {
            'CPU time': ('XCTMetric_CPU-', '.time', 's'),
            'clock time': ('XCTMetric_Clock.', '.time.monotonic', 's'),
            'memory growth': ('XCTMetric_Memory-', '.physical', 'kB'),
        }
        for name, (prefix, suffix, unit) in required.items():
            matches = [key for key in before if prefix in key and key.endswith(suffix)]
            if len(matches) != 1:
                raise SystemExit(f'Missing required {name} metric for {test}')
            key = matches[0]
            if before[key][2] != unit or after[key][2] != unit:
                raise SystemExit(f'Unexpected unit for {name} in {test}: expected {unit}')
        print(test)
        count = WORKLOADS[test][1]
        for identifier in sorted(before):
            name, old, old_unit = before[identifier]
            new = after[identifier][1]
            if old_unit != after[identifier][2]:
                raise SystemExit(f'Metric units differ for {test}: {name}')
            if len(old) != count or len(new) != count:
                raise SystemExit(f'Missing metric iterations for {test}: {name}')
            if any(not isinstance(value, (int, float)) or not math.isfinite(value) for value in old + new):
                raise SystemExit(f'Invalid metric value for {test}: {name}')
            compare(name, old, new)
        workload = WORKLOADS[test][0]
        old, new = app_samples(args.baseline, workload, count), app_samples(args.candidate, workload, count)
        for field in old:
            scale, unit = (1_048_576, ' MiB') if field.endswith('Bytes') else ((1_000_000, ' ms') if field.endswith('Nanoseconds') else (1, ''))
            compare(field, old[field], new[field], scale, unit)
        compare('retained growth (distinct from sampled peak)',
                [end - start for end, start in zip(old['retainedFootprintBytes'], old['startingFootprintBytes'])],
                [end - start for end, start in zip(new['retainedFootprintBytes'], new['startingFootprintBytes'])],
                1_048_576, ' MiB')


if __name__ == '__main__':
    main()
