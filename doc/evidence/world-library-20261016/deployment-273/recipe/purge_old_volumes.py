from pathlib import Path
import json,re,subprocess,sys,time,urllib.request
out=Path(__file__).resolve().parent/'refound'
scope=json.loads((out/'scope.json').read_text());address='http://192.168.1.10:4646'
assert json.loads((out/'fleet-probe-after-desktop.json').read_text())['passed']
label=sys.argv[1]
assert re.fullmatch(r'desktop-deployed-[0-9]+',label)
assert json.loads((out.parent.parent/label/'PASSED.json').read_text())['passed']
def get(path):
 with urllib.request.urlopen(address+path,timeout=40) as response:return json.load(response)
def run(label,command):
 (out/(label+'.intent.json')).write_text(json.dumps({'command':command},indent=2))
 start=time.monotonic();r=subprocess.run(command,capture_output=True,text=True)
 (out/(label+'.stdout')).write_text(r.stdout);(out/(label+'.stderr')).write_text(r.stderr)
 (out/(label+'.exit.json')).write_text(json.dumps({'exit':r.returncode,'seconds':time.monotonic()-start},indent=2))
 assert r.returncode==0,(label,r.returncode)
 return r
candidate=get('/v1/job/'+scope['job']);main=get('/v1/job/quod')
assert candidate['Version']==scope['candidate_version']+2
assert main['Version']==scope['main_version'] and main['JobModifyIndex']==scope['main_modify_index']
for group in candidate['TaskGroups']:
 assert group['Volumes']['quod-data']['Source'] in [scope['new_family'],scope['new_family']+'-cloud']
previous=out.parent.parent/'deployment-01/refound'
prior_scope=json.loads((previous/'scope.json').read_text())
assert prior_scope['job']==scope['job'] and prior_scope['new_family']==scope['old_family']
assert prior_scope['main_version']==scope['main_version'] and prior_scope['main_modify_index']==scope['main_modify_index']
retired=prior_scope['volumes']+scope['volumes']
assert len(retired)==16 and len({r['id'] for r in retired})==16
assert all(re.fullmatch(re.escape(family)+r'\[[0-7]\]',r['name']) for family,rows in [(prior_scope['old_family'],prior_scope['volumes']),(scope['old_family'],scope['volumes'])] for r in rows)
old_allocations={a['ID'] for a in json.loads((out/'allocations-before.json').read_text())}
assert not [a for a in get('/v1/job/'+scope['job']+'/allocations?all=true') if a['ID'] in old_allocations and a['ClientStatus']=='running']
old_allocations.update(a['ID'] for a in json.loads((previous/'allocations-before.json').read_text()))
assert not [a for a in get('/v1/job/'+scope['job']+'/allocations?all=true') if a['ID'] in old_allocations and a['ClientStatus']=='running']
old_ids={row['id'] for row in retired}
deleted = []
for row in retired:
    current = json.loads(subprocess.check_output(
        ['nomad', 'volume', 'status', '-address=' + address,
         '-type=host', '-json'], text=True))
    exact = [v for v in current if v['ID'] == row['id']]
    assert len(exact) == 1 and exact[0]['Name'] == row['name']
    command = ['nomad', 'volume', 'delete', '-address=' + address,
               '-type=host', row['id']]
    result = run(f'delete-old-volume-{row["id"]}', command)
    deleted.append({'index': row['index'], 'id': row['id'], 'name': row['name'],
                    'stdout': result.stdout})
    (out/'old-volumes-deleted-progress.json').write_text(json.dumps(deleted,indent=2)+'\n')
(out / 'old-volumes-deleted.json').write_text(json.dumps(deleted, indent=2) + '\n')
remaining = json.loads(subprocess.check_output(
    ['nomad', 'volume', 'status', '-address=' + address, '-type=host', '-json'],
    text=True))
assert not [v for v in remaining if v['ID'] in old_ids]
print(json.dumps({'old_candidate_volumes_deleted':len(deleted),'main_unchanged':True}))
