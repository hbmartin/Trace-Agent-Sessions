#!/usr/bin/env python3
"""Extract acknowledged app timing/footprint records from xcresult attachments."""
import json
import sys
from pathlib import Path

samples = {}
for path in Path(sys.argv[1]).rglob('*'):
    if not path.is_file():
        continue
    try:
        sample = json.loads(path.read_text())
    except (ValueError, UnicodeError, OSError):
        continue
    if isinstance(sample, dict) and isinstance(sample.get('id'), str) and 'Footprint' in str(sample):
        samples[sample['id']] = sample
Path(sys.argv[2]).write_text(json.dumps(sorted(samples.values(), key=lambda s: s['id']), indent=2) + '\n')
