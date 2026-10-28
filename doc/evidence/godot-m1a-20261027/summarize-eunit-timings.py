#!/usr/bin/env python3
"""Extract printed case timings from an already completed required EUnit run."""
import collections
import json
from pathlib import Path
import re
import sys

evidence = Path(__file__).resolve().parent
label = sys.argv[1]
receipt = json.loads((evidence / 'logs' / (label + '-eunit.json')).read_text())
assert receipt['child_exit'] == 0 and not receipt['timed_out']
source = evidence / 'logs' / (label + '-eunit.log')
text = re.sub(r'\x1b\[[0-9;]*m', '', source.read_text(errors='replace'))
rows = []
pending = None
unlabeled_timings = 0
for line in text.splitlines():
    label_match = re.match(r'\s*(quod_\w+(?::.*?)?)\.\.\.', line)
    if label_match:
        pending = re.sub(r'<<.*?>>', '<<binary>>', label_match[1])
    match = re.search(r'\[([0-9.]+) s\] ok\s*$', line)
    if match:
        if pending is None:
            unlabeled_timings += 1
        else:
            rows.append(dict(case=pending, seconds=float(match[1])))
        pending = None
    elif re.search(r'(?:\.\.\.|^\s*)ok\s*$', line):
        pending = None
totals = collections.defaultdict(float)
for row in rows:
    totals[row['case'].split(':')[0]] += row['seconds']
output = evidence / (label + '-eunit-timings.json')
assert not output.exists(), 'Preserve earlier observations'
result = dict(label=label, source=str(source.relative_to(evidence)),
    command_seconds=receipt['elapsed_seconds'], parsed_timed_cases=len(rows),
    unlabeled_timing_rows=unlabeled_timings,
    scope='Printed elapsed times of successful named Quod cases, retaining a label across intervening test output. Sub-millisecond/unprinted timings and unlabeled rows are not assigned zero. This is one campaign, not a distribution or CPU/wait diagnosis.',
    by_module_timed_seconds=dict(sorted(totals.items(), key=lambda x: -x[1])),
    slowest_cases=sorted(rows, key=lambda x: -x['seconds'])[:30], all_parsed_cases=rows)
output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k: result[k] for k in ['label', 'command_seconds', 'parsed_timed_cases']}))
