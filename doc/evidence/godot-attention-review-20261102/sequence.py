"""Finite sequential invocation of existing bounded software gate owners."""
import json,os,shutil,subprocess,sys
from pathlib import Path
from hashes import TASK,raw
os.umask(0o077)
ev=Path(__file__).resolve().parent;plan=Path(sys.argv[1]);private=TASK/'private'/plan.stem
private.mkdir(mode=0o700,exist_ok=False);shutil.copy2(plan,private/'plan.json');shutil.copy2(__file__,private/'sequence.py')
rows=[]
for case in json.loads(plan.read_text()):
    cmd=[sys.executable,'-B',str(ev/'run.py'),'--timeout','360',case['label']+'-run','--',sys.executable,'-B',str(ev/'signed.py'),case['label'],str(ev/'inputs'/('client-'+case['build']+'-manifest.json')),str(TASK/'builds/answer-policy-clean-focused06/source'),case['phase']]
    row={'command':cmd,'true_exit':None};rows.append(row);(private/'result.json').write_text(json.dumps(rows,indent=2)+'\n')
    with (private/(case['label']+'.stdout')).open('xb') as out,(private/(case['label']+'.stderr')).open('xb') as err:row['true_exit']=subprocess.run(cmd,stdout=out,stderr=err).returncode
    (private/'result.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps({'label':case['label'],'exit':row['true_exit']}),flush=True)
raise SystemExit(0 if all(r['true_exit']==0 for r in rows) else 1)
