"""Run one distinct affected CT obligation in an already clean built input tree."""
import json,subprocess,sys,os,re
from pathlib import Path
from hashes import Digests,raw
os.umask(0o077)
ev=Path(__file__).resolve().parent
label,prior=sys.argv[1:3]
base=json.loads((ev/(prior+'-result.json')).read_text())
assert base['all_true_exits_zero'] and base['source_unchanged']
m=json.loads((ev/'inputs'/(prior+'-source-manifest.json')).read_text())
stage=Path(m['stage']);work=stage/'source';d=Digests()
assert all(d.h(work/n)==v==d.h(Path.cwd()/n) for n,v in m['files'].items())
original=json.loads((ev/'logs'/(prior+'-eunit.json')).read_text())['command']
command=original[:original.index('rebar3')]+['rebar3','as','test','ct',
    '--suite=test/quod_ask_SUITE','--case=answer_policy_producer_consumer_and_signed_change']
command[command.index('--name')+1]='quod-'+label
record={'command':command,'clean_source_manifest':str(ev/'inputs'/(prior+'-source-manifest.json')),
    'clean_source_manifest_sha256':raw(ev/'inputs'/(prior+'-source-manifest.json')),
    'distinct_affected_obligation':True,'not_new_clean_build':True}
(ev/'inputs'/(label+'-command.json')).write_text(json.dumps(record,indent=2)+'\n')
r=subprocess.run([sys.executable,'-B',str(ev/'run.py'),'--timeout','2400',label+'-ct','--',*command])
receipt=json.loads((ev/'logs'/(label+'-ct.json')).read_text())
text=(ev/'logs'/(label+'-ct-stdout.log')).read_text()
record.update(true_wrapper_exit=r.returncode,child_exit=receipt['child_exit'],
    completion=bool(re.search(r'All [1-9][0-9]* tests passed',text)),
    source_unchanged=all(d.h(work/n)==v==d.h(Path.cwd()/n) for n,v in m['files'].items()))
record['passed']=r.returncode==0 and record['completion'] and record['source_unchanged']
d.write(stage/(label+'-hashes.json'))
(ev/(label+'-result.json')).write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record))
raise SystemExit(0 if record['passed'] else 1)
