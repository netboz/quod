"""Explicitly rebuild restored diagnostic modules and compare one final regression."""
from pathlib import Path
import os, json, shutil, subprocess, time, hashlib
root = Path('/home/yan/src/quod')
evidence = Path(__file__).resolve().parent
tree = root/'_build/quo-58-webxr-20261026/view-correction-01/diagnostic-tree-15'
assert (evidence/'focused.exit.json').exists()
restored = ['src/quod_runtime.erl','src/quod_prolog.erl','test/quod_personal_agent_tests.erl']
for name in restored + ['test/quod_ct.erl']:
    shutil.copyfile(root/name, tree/name)
    (tree/name).touch()
env = dict(os.environ, ERL_FLAGS='+S 4:4 +SDio 2 +SDcpu 2', CARGO_NET_OFFLINE='true')
for key in ['LD_LIBRARY_PATH','LD_PRELOAD','DEBUG']: env.pop(key,None)
def run(label, selection):
    command = ['rebar3','as','test','eunit',selection,'--verbose']
    (evidence/(label+'.intent.json')).write_text(json.dumps({'command':command,'restored_modules_explicitly_touched':True},indent=2)+'\n')
    started=time.monotonic()
    with (evidence/(label+'.log')).open('xb') as log:
        child=subprocess.run(command,cwd=tree,env=env,stdout=log,stderr=subprocess.STDOUT)
    record={'exit':child.returncode,'seconds':round(time.monotonic()-started,2)}
    (evidence/(label+'.exit.json')).write_text(json.dumps(record,indent=2)+'\n')
    print(label,record,flush=True)
    return child.returncode
before=run('before-v3','--generator=quod_space_creation_tests:atomic_completion_wait_includes_complete_record_test_')
beam=tree/'_build/test/lib/quod'
assert b'diagnostic_unavailable' not in (beam/'ebin/quod_runtime.beam').read_bytes()
assert b'group_completion' not in (beam/'test/quod_ct.beam').read_bytes()
assert before != 0 and 'completed_before_group_complete' in (evidence/'before-v3.log').read_text()
shutil.copyfile(evidence/'corrected-helper.erl',tree/'test/quod_ct.erl')
(tree/'test/quod_ct.erl').touch()
after=run('focused-v2','--module=quod_ct,quod_space_creation_tests,quod_readiness_probe_tests')
assert after == 0
assert b'group_completion' in (beam/'test/quod_ct.beam').read_bytes()
assert b'diagnostic_unavailable' not in (beam/'ebin/quod_runtime.beam').read_bytes()
assert all((tree/n).read_bytes()==(root/n).read_bytes() for n in restored)
(evidence/'verified-rebuilt.json').write_text(json.dumps({'before_failed_correctly':True,'focused_passed':True,'runtime_probe_absent_from_beam':True,'production_sources_unchanged':True,'files':{n:hashlib.sha256((tree/n).read_bytes()).hexdigest() for n in restored+['test/quod_ct.erl','test/quod_space_creation_tests.erl']}},indent=2)+'\n')
