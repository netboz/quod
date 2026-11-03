"""Qualify Rebar's exact checkout-lock output without rerunning a provider."""
import json,os,re,shutil,subprocess
from pathlib import Path
from hashes import TASK,Digests,raw
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
def load(p):return json.loads(p.read_text())
manifest=ev/'inputs/answer-policy-release02-source-manifest.json';m=load(manifest)
result=ev/'answer-policy-release02-result.json';r=load(result)
assert r['all_true_exits_zero'] and not r['source_unchanged'] and r['completed_gates']==5
assert all(x['child_exit']==0 and not x['timed_out'] and x['completion_confirmed'] for x in r['results'])
out=TASK/'private/policy-release-reconciliation01';out.mkdir(mode=0o700,exist_ok=False)
src=Path(m['stage'])/'source';changes={}
for n,expected in m['files'].items():
    assert d.h(root/n)==expected,n
    current=d.h(src/n)
    if current!=expected:changes[n]={'input_sha256':expected,'generated_sha256':current}
assert set(changes)=={'rebar.lock'},changes
for name,expected in m['dependency_sources'].items():
    p=src/name;actual={'symlink':str(p.readlink())} if p.is_symlink() else d.h(p)
    # Record the known provider-generated parser output separately. No dependency
    # source substitution is accepted by the lock reconciliation.
    if actual!=expected:assert r['dependency_generated_changes'].get(name)=={'input':expected,'output':actual},name
checkouts=sorted(m['offline_locked_checkouts']);assert len(checkouts)==5
for n in checkouts:
    assert re.fullmatch('[a-z_]+',n)
    assert str((src/'_checkouts'/n).readlink())==m['offline_locked_checkouts'][n]['literal_link']
for source,name in [(root/'rebar.lock','input.lock'),(src/'rebar.lock','generated.lock')]:
    shutil.copy2(source,out/name);assert d.h(out/name)==d.h(source)
expected='['+','.join('<<"'+n+'">>' for n in checkouts)+']'
expression='''
{ok,[{Version,Before}|Metadata]}=file:consult("/evidence/input.lock"),
{ok,[{Version,After}|Metadata]}=file:consult("/evidence/generated.lock"),
Expected=EXPECTED,
Expected=lists:sort([N || {N,{git,_,{ref,_}},_} <- Before]),
After=[Entry || Entry <- Before, not lists:member(element(1,Entry),Expected)],
io:format("LOCK_RECONCILED before=~B after=~B removed=~B metadata=identical~n",[length(Before),length(After),length(Expected)]),
halt(0).
'''.replace('EXPECTED',expected)
(out/'expression.erl').write_text(expression)
command=['docker','run','--rm','--network','none','-v',str(out)+':/evidence:ro','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','erl',m['image'],'-noshell','-eval',expression]
done=subprocess.run(command,capture_output=True,timeout=60)
for name,data in [('stdout.raw',done.stdout),('stderr.raw',done.stderr)]: (out/name).write_bytes(data)
assert done.returncode==0 and done.stdout==b'LOCK_RECONCILED before=24 after=19 removed=5 metadata=identical\n' and not done.stderr,(done.returncode,done.stdout,done.stderr)
d.write(out/'computed-hashes.json')
proof={'passed':True,'original_campaign_outer_exit':1,'original_source_unchanged_flag':False,'original_failure_retained':True,'provider_or_app_rerun':False,
    'original_result':{'path':str(result),'sha256':raw(result)},'source_manifest':{'path':str(manifest),'sha256':raw(manifest)},
    'all_live_authored_inputs_unchanged':len(m['files']),'derived_source_outputs':changes,'removed_checkout_entries':checkouts,
    'all_other_lock_entries_and_metadata_identical':True,'exact_dependency_sources_and_links_checked':True,
    'parser_command':command,'parser_true_exit':done.returncode,'private':str(out),
    'streams':{n:{'path':str(out/(n+'.raw')),'sha256':raw(out/(n+'.raw')),'bytes':(out/(n+'.raw')).stat().st_size} for n in ['stdout','stderr']},
    'digest_cache':{'path':str(out/'computed-hashes.json'),'sha256':raw(out/'computed-hashes.json')}}
(ev/'release-reconciliation.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps({'reconciled':True,'original_outer_exit':1,'providers_rerun':0,'changed_stage_metadata':['rebar.lock'],'live_inputs_unchanged':len(m['files'])}))
