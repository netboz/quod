"""Current refactor accounting; never rewrites prior campaigns or raw evidence."""
from pathlib import Path
import hashlib,json,subprocess
root=Path('/home/yan/src/quod_worktrees/pearl-stone');ev=root/'doc/evidence/stage2-predicate-composition-20261103'
h=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
rows={}
for before in sorted((ev/'before').rglob('*')):
 if not before.is_file():continue
 n=str(before.relative_to(ev/'before'));current=root/n
 result=subprocess.run(['git','diff','--no-index','--numstat',str(before),str(current)],cwd=root,capture_output=True,text=True)
 assert result.returncode in [0,1],result.stderr
 if not result.stdout:continue
 added,removed=result.stdout.split('\t')[:2]
 rows[n]={'added':int(added),'removed':int(removed),'before_sha256':h(before),'current_sha256':h(current)}
delta={'basis':'saved current-turn inputs including the inherited +41/-7 slice; not git HEAD','paths':rows,'added':sum(x['added'] for x in rows.values()),'removed':sum(x['removed'] for x in rows.values())};delta['net']=delta['added']-delta['removed']
(ev/'inputs/production-delta.json').write_text(json.dumps(delta,indent=2)+'\n')
runs={}
for receipt in sorted((ev/'inputs').glob('*-signed*.json')):
 if receipt.name.startswith('server-'):continue
 value=json.loads(receipt.read_text())
 if 'children' not in value:continue
 for stream in value['streams'].values():
  assert h(stream['path'])==stream['sha256'] and Path(stream['path']).stat().st_size==stream['bytes']
 private=root/'_build/stage2-predicate-composition'/receipt.stem
 failures=[]
 for name in ['client-stderr.raw','server-stderr.raw']:
  if (private/name).is_file():
   for line in (private/name).read_text().splitlines():
    if line.startswith(('System.FormatException:','System.Threading.Tasks.TaskCanceledException:','System.TimeoutException:','System.NullReferenceException:','System.ArgumentNullException:','System.Exception:','Quod.Client.ApiError:','AssertionError:','StopIteration')):failures.append(line)
 runs[receipt.stem]={'receipt_sha256':h(receipt),'passed':value['passed'],'wrapper_exit':0 if value['passed'] else 1,'child_exits':{n:c['true_exit'] for n,c in value['children'].items()},'eof':value['eof'],'checks':len(value.get('checks',[])),'first_failure_lines':failures[:3],'forced_termination':value.get('unretired_failure',False),'reader_errors':value['reader_errors']}
old={}
for label in ['01','02','03','04']:
 packet=root/'nimbalyst-local/review-packets'/('stage2-predicate-subjects'+label)
 result=json.loads((packet/'result.json').read_text());assert h(packet/'snapshot.tar')==result['archive_sha256'];assert h(packet/'manifest.json')==result['manifest_sha256']
 old[label]={'archive_sha256':result['archive_sha256'],'manifest_sha256':result['manifest_sha256']}
record={'production_delta':delta,'runs':runs,'prior_freezes_intact':old,'raw_stream_hashes_verified':True,'whole_tree_acceptance':False,'hardware':False}
(ev/'inputs/accounting.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'production_delta':{k:v for k,v in delta.items() if k!='paths'},'runs':runs},indent=2))
