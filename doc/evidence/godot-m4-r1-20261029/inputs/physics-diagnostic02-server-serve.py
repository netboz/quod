#!/usr/bin/env python3
"""Own one disposable production fixture; retain its private raw server log."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
import sys
import time

p = argparse.ArgumentParser()
p.add_argument('label')
p.add_argument('--stage', required=True)
p.add_argument('--profile', choices=['test', 'prod'], default='test')
p.add_argument('--qualified', action='store_true')
p.add_argument('--physics', action='store_true')
a = p.parse_args()
root = Path.cwd()
evidence = root / 'doc/evidence/godot-m4-r1-20261029'
private = Path('/home/yan/.cache/quod-m4-r1-artifacts/artifacts/private/quod-m4-live-' + a.label)
private.mkdir(mode=0o700, parents=True, exist_ok=False)
(private / 'ebin').mkdir()
(private / 'tmp').mkdir()
driver_sources={}
for name in ['serve.py','godot_m3b_fixture.erl','godot_m3b_physics_fixture.erl']:
    src=evidence/name
    retained=evidence/'inputs'/(a.label+'-'+name)
    assert not retained.exists()
    shutil.copy2(src,retained)
    if name.endswith('.erl'):shutil.copy2(retained,private/name)
    driver_sources[name]={'path':str(retained),'sha256':hashlib.sha256(retained.read_bytes()).hexdigest()}
original = Path(a.stage) / 'test/quod_lifecycle_single_path_tests.erl'
text = original.read_text()
cleanup_before = '_ = file:del_dir_r(Dir),\n    ok.'
cleanup_after = 'ok.'
assert text.count(cleanup_before) == 1
adapted = text.replace(cleanup_before, cleanup_after)
replacements = [{'before': cleanup_before, 'after': cleanup_after,
                 'reason': 'Preserve private disposable fixture storage after stopping all owners; never include its credentials in source snapshots.'}]
if a.profile == 'prod':
    before = '{ok, Journal} = quod_effect_journal:start_link(#{data_dir => Dir}),'
    after = 'ok = application:set_env(quod, effect_journal_data_dir, Dir),\n    {ok, Journal} = quod_effect_journal:start_link(),'
    assert adapted.count(before) == 1
    adapted = adapted.replace(before, after)
    replacements.append({'before': before, 'after': after,
                         'reason': 'Existing production journal configuration and start_link/0; start_link/1 is TEST-only.'})
(private / 'quod_lifecycle_single_path_tests.erl').write_text(adapted)
factory = '/m1b/quod_lifecycle_single_path_tests.erl'
factory_receipt = {'original_sha256': hashlib.sha256(text.encode()).hexdigest(),
                   'adapted_sha256': hashlib.sha256(adapted.encode()).hexdigest(),
                   'exact_replacements': replacements}
expression = '''
{ok,quod_lifecycle_single_path_tests}=compile:file("FACTORY",[export_all,{outdir,"/m1b/ebin"},{i,"/work/include"}]),
{ok,quod_physics_tests}=compile:file("/work/test/quod_physics_tests.erl",[export_all,{outdir,"/m1b/ebin"},{i,"/work/include"}]),
{ok,godot_m3b_fixture}=compile:file("/m1b/godot_m3b_fixture.erl",[{outdir,"/m1b/ebin"}]),
true=code:add_patha("/m1b/ebin"),godot_m3b_fixture:start(),halt().
'''
expression = expression.replace('FACTORY', factory)
if a.physics:
    host_original=Path(a.stage)/'test/quod_agent_hosting_tests.erl'
    host=host_original.read_text();before='ok = file:del_dir_r(Dir),\n            Value;';after='Value;'
    assert host.count(before)==1
    host=host.replace(before,after)
    host_replacements=[{'before':before,'after':after,'reason':'Retain private disposable fixture stores.'}]
    if a.profile=='prod':
        before='{ok, Auth} = quod_client_auth:start_link(#{network_id => <<42:256>>, node_key => Pub}),'
        after='{ok, Auth} = quod_client_auth:start_link(),'
        assert host.count(before)==1
        host=host.replace(before,after)
        host_replacements.append({'before':before,'after':after,'reason':'Use production start_link/0; the existing desired root identity and node_pubkey configuration supply these same identities.'})
    (private/'quod_agent_hosting_tests.erl').write_text(host)
    (private/'predicates-ebin').mkdir()
    runtime=Path(a.stage)/'_build'/a.profile/'lib/quod/ebin'
    copied_objects={}
    for obj in sorted(runtime.glob('*.beam')):
        shutil.copy2(obj,private/'predicates-ebin'/obj.name)
        copied_objects[obj.name]=hashlib.sha256(obj.read_bytes()).hexdigest()
    predicate=runtime/'quod_predicates.beam'
    factory_receipt['physics_host_adapter']={'original_sha256':hashlib.sha256(host_original.read_bytes()).hexdigest(),'adapted_sha256':hashlib.sha256(host.encode()).hexdigest(),'exact_replacements':host_replacements,'reason':'Preserve fixture stores and use production startup exports; redirect only the test helper copy through exact copied production outputs in private execution.'}
    factory_receipt['copied_predicate_object_sha256']=hashlib.sha256(predicate.read_bytes()).hexdigest()
    factory_receipt['copied_runtime_outputs']=copied_objects
    expression='''
{ok,quod_agent_hosting_tests}=compile:file("/m1b/quod_agent_hosting_tests.erl",[export_all,{outdir,"/m1b/ebin"},{i,"/work/include"}]),
{ok,quod_physics_tests}=compile:file("/work/test/quod_physics_tests.erl",[export_all,{outdir,"/m1b/ebin"},{i,"/work/include"}]),
{ok,godot_m3b_physics_fixture}=compile:file("/m1b/godot_m3b_physics_fixture.erl",[{outdir,"/m1b/ebin"}]),
true=code:add_patha("/m1b/ebin"),true=code:add_patha("/m1b/predicates-ebin"),godot_m3b_physics_fixture:start(),halt().
'''
if not a.qualified:
    expression = '{ok,quod_client_view}=compile:file("/code/src/quod_client_view.erl",[{outdir,"/m1b/ebin"},{i,"/code/include"}]),\n' + expression
command = ['docker', 'run', '--rm', '-i', '--init', '--network', 'host', '--name', 'quod-m4-live-' + a.label,
           '-v', a.stage + ':/work:ro', '-v', str(root) + ':/code:ro', '-v', str(evidence) + ':/evidence:ro',
           '-v', str(private) + ':/m1b', '-v', str(private / 'tmp') + ':/tmp', '-w', '/work', '-e', 'QUOD_M3B_PRIVATE=/m1b',
           '-e', 'ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2', '--entrypoint', '/bin/sh',
           'sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55',
           '-c', 'exec erl -noshell -pa /work/_build/' + a.profile + '/lib/*/ebin /work/_build/test/lib/quod/test -eval "$1"', 'sh', expression]
receipt = {'command': command, 'stage': a.stage, 'profile': a.profile, 'runtime_recompiled': not a.qualified, 'worker_session': 'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f', 'factory_adapter': factory_receipt, 'driver_sources':driver_sources, 'private_raw_log': str(private / 'server-raw.log')}
(evidence / 'inputs' / ('server-' + a.label + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
started = time.monotonic()
child = subprocess.Popen(command, stdin=sys.stdin, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
with (private / 'server-raw.log').open('wb') as log:
    for line in child.stdout:
        log.write(line); log.flush()
        if line.startswith(b'M1B_'):
            print(line.decode().rstrip(), flush=True)
child.wait()
receipt.update(child_exit=child.returncode, elapsed_seconds=time.monotonic()-started)
(evidence / 'inputs' / ('server-' + a.label + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
raise SystemExit(child.returncode)
