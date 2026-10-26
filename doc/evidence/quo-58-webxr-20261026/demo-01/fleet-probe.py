"""Read-only fleet verification against this campaign's accepted deployment."""
from pathlib import Path
import base64, hashlib, json, re, subprocess, sys, time, urllib.request

ROOT=Path('/home/yan/src/quod')
OUT=ROOT/'_build/quo-58-webxr-20261026/demo-01/deployment'
EVIDENCE=Path(__file__).resolve().parent
ADDR='http://192.168.1.10:4646'
label=sys.argv[1]
assert re.fullmatch('[a-z][a-z0-9-]+',label)
record=OUT/(label+'.json'); assert not record.exists()
scope=json.loads((OUT/'live-scope.json').read_text());job_id=scope['job']
accepted=json.loads((OUT/'scale-submission.json').read_text())
image=json.loads((OUT/'verified-image.json').read_text())['pinned_image']
anchors={'quod:'+n:a for n,a in json.loads((OUT/'anchors.json').read_text()).items()}
anchors['quod:root']=json.loads((OUT/'root-info.json').read_text())['root_anchor']
assert len(anchors)==19 and all(re.fullmatch('[0-9A-F]{64}',a) for a in anchors.values())

def get(path):
    with urllib.request.urlopen(ADDR+path,timeout=40) as response:return json.load(response)

def verify_jobs():
    current=get('/v1/job/'+job_id)
    assert current['JobModifyIndex']==accepted['JobModifyIndex']
    original=json.loads((OUT/'live-before.json').read_text())
    for name in ['quod','quod27-client-30519','quod-candidate-browser-ingress']:
        assert get('/v1/job/'+name)==original[name],name
    groups={g['Name']:g for g in current['TaskGroups']}
    assert groups['quod-node']['Count']==8 and groups['quod-cloud']['Count']==0
    assert groups['quod-node']['Volumes']['quod-data']['Source']==scope['new_family']
    images={t['Config']['image'] for g in groups.values() for t in g['Tasks'] if '/quod:' in t['Config'].get('image','')}
    assert images=={image}
    return current

job=verify_jobs()
live=[a for a in get('/v1/job/'+job_id+'/allocations?all=true') if a['ClientStatus']=='running' and a['DesiredStatus']=='run']
assert len(live)==8 and all(a['JobVersion']==job['Version'] and a['TaskStates']['quod']['Restarts']==0 for a in live)
beam=(OUT/'quod_fleet_probe.beam').read_bytes()
beam64=base64.b64encode(beam).decode();digest=hashlib.sha256(beam).hexdigest()
terms=','.join('<<"'+n+'">>=>binary:decode_hex(<<"'+a+'">>)' for n,a in sorted(anchors.items()))
expression='{module,quod_fleet_probe}=code:load_binary(quod_fleet_probe,"'+digest+'",base64:decode(<<"'+beam64+'">>)), quod_fleet_probe:run(#{'+terms+'})'
encoded='binary_to_list(base64:encode(iolist_to_binary(json:encode(begin '+expression+' end)))).'
rows=[];started=time.monotonic()
for a in sorted(live,key=lambda x:x['Name']):
    command=['nomad','alloc','exec','-i=false','-t=false','-address='+ADDR,'-task','quod',a['ID'],'/opt/quod/bin/quod','eval',encoded]
    result=subprocess.run(command,capture_output=True,text=True)
    row={'allocation':a['ID'],'name':a['Name'],'node':a['NodeName'],'exit':result.returncode,'restarts':a['TaskStates']['quod']['Restarts']}
    if result.returncode:row['stdout']=result.stdout;row['stderr']=result.stderr
    else:
        wire=json.loads(result.stdout)
        if isinstance(wire,list):wire=bytes(wire).decode('ascii')
        row['probe']=json.loads(base64.b64decode(wire,validate=True))
    rows.append(row)
    with (OUT/(label+'-'+a['ID']+'.json')).open('x') as f:json.dump(row,f,indent=2)
    print(json.dumps({'allocation':a['ID'],'exit':row['exit'],'ready':row.get('probe',{}).get('all_ready',False)}),flush=True)
    assert result.returncode==0
verify_jobs()
assert all(r['probe']['anchors']==anchors and r['probe']['version']=='0.7.275' and
           r['probe']['root_committed']==r['probe']['root_applied'] and
           r['probe']['catalogue_count']==18 for r in rows)
receipt={'passed':True,'image':image,'job':job_id,'job_version':job['Version'],
         'anchors':anchors,'allocations':rows,'protected_jobs_unchanged':True,'seconds':time.monotonic()-started}
with record.open('x') as f:json.dump(receipt,f,indent=2)
with (EVIDENCE/(label+'.json')).open('x') as f:json.dump(receipt,f,indent=2)
print(json.dumps({'passed':True,'allocations':8,'system_ontologies_per_node':18}),flush=True)
