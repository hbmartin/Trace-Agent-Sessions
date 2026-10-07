#!/usr/bin/env python3
"""Validate and compare CPU, clock, app memory growth, timings, and footprints."""
import argparse
import json
import statistics
from pathlib import Path

WORKLOADS = {
    'testTranscriptScrollPerformance()': ('scroll', 5),
    'testStreamingTranscriptFollowPerformance()': ('streaming', 3),
    'testExternalSidecarTrafficPerformance()': ('watcher', 5),
}


def metrics_for(path, test_name):
    report = json.loads(path.read_text())
    for test in report:
        if test['testIdentifier'].endswith(test_name):
            return {metric['identifier']: (metric['displayName'], metric['measurements'])
                    for run in test['testRuns'] for metric in run['metrics']}
    raise SystemExit(f'{test_name} was not found in {path}')


def app_samples(path, workload, count):
    source = path.parent / 'app-samples.json'
    if not source.exists():
        raise SystemExit(f'Missing memory/timing records: {source}')
    samples = sorted([s for s in json.loads(source.read_text()) if s.get('id', '').startswith(workload + '-')],
                     key=lambda s: int(s['id'].rsplit('-', 1)[1]))
    if len(samples) < count:
        raise SystemExit(f'Missing {workload} memory/timing records: expected {count}, got {len(samples)}')
    # XCTest performs an unreported warm-up iteration. Keep it in raw exports,
    # but compare only the iterations represented in its CPU/clock metric arrays.
    samples = samples[-count:]
    fields = ['updateCount', 'totalUpdateNanoseconds', 'maximumUpdateNanoseconds',
              'startingFootprintBytes', 'sampledPeakFootprintBytes', 'endingFootprintBytes',
              'retainedFootprintBytes', 'footprintSampleCount']
    for sample in samples:
        for field in fields:
            if not isinstance(sample.get(field), (float, int)) or sample[field] < 0:
                raise SystemExit(f'Missing/invalid {field} in {sample.get("id")}')
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
        names = ' '.join(k + ' ' + v[0] for k, v in before.items()).lower()
        for required in ['cpu', 'clock', 'memory']:
            if required not in names:
                raise SystemExit(f'Missing required {required} metric for {test}')
        print(test)
        count = WORKLOADS[test][1]
        for identifier in sorted(before):
            name, old = before[identifier]
            new = after[identifier][1]
            if len(old) != count or len(new) != count:
                raise SystemExit(f'Missing metric iterations for {test}: {name}')
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
