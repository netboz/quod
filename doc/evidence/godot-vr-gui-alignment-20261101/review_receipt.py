#!/usr/bin/env python3
"""Small source/status receipt for the requested conformance review; no runs."""
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
DATA = pathlib.Path('/data/quod-m4-vr-ca84d4f8-20261029')

def identity(path):
    s = path.lstat()
    return {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'stat_key': [s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns],
            'mode': s.st_mode}

before = json.loads((HERE / 'inputs/before.json').read_text())
sources = {}
added = removed = 0
for relative, original in before.items():
    if not relative.endswith('.cs'):
        continue
    old, current = pathlib.Path(original['copy']), ROOT / relative
    old_id, new_id = identity(old), identity(current)
    assert old_id['sha256'] == original['sha256']
    assert old_id['stat_key'][:2] != new_id['stat_key'][:2]
    diff = subprocess.run(['git', 'diff', '--no-index', '--numstat', '--', str(old), str(current)],
                          cwd=ROOT, capture_output=True, text=True)
    assert diff.returncode in (0, 1), diff.stderr
    counts = diff.stdout.split('\t', 2)[:2] if diff.stdout else ['0', '0']
    plus, minus = map(int, counts)
    added += plus
    removed += minus
    sources[relative] = {'before': original, 'preserved_copy': old_id, 'candidate': new_id,
                         'added_lines': plus, 'removed_lines': minus,
                         'candidate_runtime_qualified': False}

cases = {}
for label in ['alignment-material-baseline02', 'alignment-attention-baseline02', 'alignment-material-baseline03']:
    result = DATA / 'private' / label / 'result.raw.json'
    d = json.loads(result.read_text())
    wrapper = HERE / 'logs' / (label + '-run.json')
    w = json.loads(wrapper.read_text())
    cases[label] = {'result': str(result), 'result_identity': identity(result),
                    'passed': d['passed'], 'failure': d.get('failure'),
                    'children': {k: v['true_exit'] for k, v in d['children'].items()},
                    'wrapper_child_exit': w['child_exit'], 'outer_timed_out': w['timed_out'],
                    'elapsed_seconds': w['elapsed_seconds'], 'eof': d['eof'],
                    'reader_errors': d['reader_errors'],
                    'unretired_failure': d.get('unretired_failure', False)}

builds = {}
for label in ['alignment-baseline01', 'alignment-baseline02', 'alignment-baseline03', 'alignment-candidate04', 'alignment-candidate05']:
    p = HERE / 'inputs' / ('client-' + label + '-manifest.json')
    m = json.loads(p.read_text())
    w = json.loads((HERE / 'logs' / (label + '-build.json')).read_text())
    builds[label] = {'manifest': str(p), 'manifest_identity': identity(p),
                     'passed': m['passed'], 'live_inputs': len(m['live_source_inputs']),
                     'supplied_inputs': len(m['supplied_inputs']),
                     'declared_exports': len(m.get('export_outputs', {})),
                     'trace_free': m['trace_free'], 'distributable': m['distributable'],
                     'wrapper_child_exit': w['child_exit'], 'timed_out': w['timed_out'],
                     'runtime_launched': label in ['alignment-baseline02', 'alignment-baseline03']}

observations = {}
for case, name in [('alignment-material-baseline03', 'material.json'),
                   ('alignment-attention-baseline02', 'attention-arrival.json')]:
    p = DATA / 'private' / case / 'sandbox/work' / name
    observations[name] = {'path': str(p), 'identity': identity(p), 'value': json.loads(p.read_text())}

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()

result = {'purpose': '274 conformance review; no acceptance or immutable freeze',
          'head': git('rev-parse', 'HEAD'), 'branch': git('branch', '--show-current'),
          'index_empty': not git('diff', '--cached', '--name-only'),
          'production_candidate': {'added_lines': added, 'removed_lines': removed,
                                   'net_lines': added - removed, 'files': sources},
          'builds': builds, 'cases': cases, 'observations': observations,
          'new_production_runtime_qualification': False,
          'new_trace_free_product': False, 'new_package': False, 'freeze_performed': False,
          'production_work_after_274': 'No further production edits or runtime launches; the already-owned candidate05 build completed.'}
(HERE / 'review-receipt274.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'production_added': added, 'production_removed': removed,
                  'production_net': added - removed, 'cases': list(cases),
                  'unrun_candidates': ['alignment-candidate04', 'alignment-candidate05']}))
