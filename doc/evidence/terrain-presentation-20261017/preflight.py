"""Read and freeze the existing candidate and its retained identities; no writes."""
from pathlib import Path
import datetime,hashlib,json,socket,ssl,urllib.parse,urllib.request
out=Path('_build/terrain-presentation-20261017/deployment-274/preflight-02');out.mkdir()
address='http://192.168.1.10:4646';job='quod-finality-candidate-v6-20260926'
origin='https://192.168.1.10:30519';ctx=ssl._create_unverified_context()
def get(base,path):
    with urllib.request.urlopen(base+path,context=ctx,timeout=30) as response:return json.load(response)
def save(name,value):
    with (out/name).open('x') as f:json.dump(value,f,indent=2);f.write('\n')
candidate=get(address,'/v1/job/'+job);main=get(address,'/v1/job/quod');ingress=get(address,'/v1/job/quod27-client-30519')
assert candidate['Version']==95 and candidate['JobModifyIndex']==869134
assert main['Version']==246 and main['JobModifyIndex']==826727
assert ingress['Version']==1 and ingress['JobModifyIndex']==846370
allocs=get(address,'/v1/job/'+job+'/allocations')
active=[a for a in allocs if a['DesiredStatus']=='run' and a['ClientStatus']=='running']
assert len(active)==8 and all(a['TaskStates']['quod']['Restarts']==0 for a in active)
family=job+'-refound-20261017-v11'
volumes=[v for v in get(address,'/v1/volumes?type=host') if v['Name'].startswith(family+'[')]
assert len(volumes)==8
images={t['Config']['image'] for g in candidate['TaskGroups'] for t in g['Tasks'] if t.get('Config',{}).get('image','').startswith('192.168.1.11:5000/quod:')}
assert images=={'192.168.1.11:5000/quod:0.7.273@sha256:4fa80d816a4d7583b988d63b6ff4d530c74b3df2ef0379d5bb7b40ff763a33c5'}
for name,value in [('candidate-before.json',candidate),('main-before.json',main),('ingress-before.json',ingress),('allocations-before.json',allocs),('volume-placement-before.json',volumes)]:save(name,value)
with socket.create_connection(('192.168.1.10',30519),timeout=20) as sock:
    with ctx.wrap_socket(sock,server_hostname='192.168.1.10') as tls:cert=tls.getpeercert(binary_form=True)
save('client-certificate-before.json',{'sha256':hashlib.sha256(cert).hexdigest(),'origin':origin})
summary=get(origin,'/explorer/api/summary');save('history-summary-before.json',summary)
checks=[]
for i,row in enumerate(summary['namespaces']):
    assert not row['syncing'],row['ns']
    ns=row['ns'];height=row['applied'];name='prefix-'+str(i)+'.json'
    block=get(origin,'/explorer/api/block/'+urllib.parse.quote(ns,safe='')+'/'+str(height));save(name,block)
    checks.append({'namespace':ns,'anchor':row['genesis'],'height':height,'file':name,'sha256':hashlib.sha256((out/name).read_bytes()).hexdigest()})
save('history-before.json',{'origin':origin,'blocks':checks,'read_only':True})
save('preflight.json',{'captured':datetime.datetime.now(datetime.timezone.utc).isoformat(),'candidate_version':candidate['Version'],'candidate_modify_index':candidate['JobModifyIndex'],'family':family,'old_image':next(iter(images)),'active_nodes':len(active),'namespaces':len(checks),'read_only':True})
print(json.dumps({'candidate_version':candidate['Version'],'active_nodes':len(active),'retained_namespaces':len(checks),'read_only':True}))
