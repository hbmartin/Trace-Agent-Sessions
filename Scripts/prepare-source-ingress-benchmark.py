#!/usr/bin/env python3
"""Extract the exact revision's mailbox for an isolated optimized workload."""
import argparse
from pathlib import Path


def extract(source):
    marker = 'final class SourceIngressMailbox: Sendable {'
    end_marker = '\n@MainActor\nenum ModelPublicationBatch'
    if source.count(marker) != 1 or source.count(end_marker) != 1:
        raise ValueError('Missing unique source-ingress boundaries')
    start = source.index(marker)
    end = source.index(end_marker, start)
    mailbox = source[start:end]
    parameters = 'changes, _, _' if 'struct ReplayPosition:' in mailbox else 'changes, _'
    return ('import Foundation\nimport os\nimport TraceCore\n\n' + mailbox + '\n'
        'func makeBenchmarkMailbox(_ receive: @escaping @MainActor @Sendable (SourceChanges) async -> Void) -> SourceIngressMailbox {\n'
        '    SourceIngressMailbox { ' + parameters + ' in await receive(changes) }\n}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = (args.root / 'Sources/TraceApp/TraceModel.swift').read_text()
    args.output.write_text(extract(source))


if __name__ == '__main__':
    main()
