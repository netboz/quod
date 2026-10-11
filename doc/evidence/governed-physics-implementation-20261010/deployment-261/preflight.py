from pathlib import Path
import datetime,hashlib,json,socket,ssl,urllib.parse,urllib.request
b=Path(__file__).resolve().parent
address='http://192.168.1.10:4646';job='quod-finality-candidate-v6-20260926'
def get(path):
 with urllib.request.urlopen(address+path,timeout=30) as response:return json.load(response)
def save(name,value):
 with (b/name).open('x') as f:json.dump(value,f,indent=2);f.write('\n')
candidate=get('/v1/job/'+job);main=get('/v1/job/quod');ingress=get('/v1/job/quod27-client-30519')
assert candidate['Version']==65 and main['Version']==246 and main['JobModifyIndex']==826727
assert ingress['Version']==1
allocs=get('/v1/job/'+job+'/allocations')
active=[a for a in allocs if a['DesiredStatus']=='run' and a['ClientStatus']=='running']
old=json.loads((b.parents[1]/'quod27-release-260/deployment/fleet-probe.json').read_text())
assert {a['ID'] for a in active}=={a['allocation'] for a in old['allocations']}
assert len(active)==8 and all(a['TaskStates']['quod']['Restarts']==0 for a in active)
volumes=get('/v1/volumes?type=host');family=job+'-refound-20261011-v6'
selected=[v for v in volumes if v['Name'].startswith(family+'[')]
assert len(selected)==8
previous=json.loads((b.parents[1]/'quod27-release-260/deployment/volume-placement-before.json').read_text())
assert {(v['ID'],v['Name'],v['NodeID']) for v in selected}=={(v['ID'],v['Name'],v['NodeID']) for v in previous}
for name,value in [('candidate-before.json',candidate),('main-before.json',main),('ingress-before.json',ingress),('allocations-before.json',allocs),('volume-placement-before.json',selected)]:save(name,value)
ctx=ssl._create_unverified_context()
with socket.create_connection(('192.168.1.10',30519),timeout=20) as sock:
 with ctx.wrap_socket(sock,server_hostname='192.168.1.10') as tls:cert=tls.getpeercert(binary_form=True)
fp=hashlib.sha256(cert).hexdigest();assert fp=='b06f4c167933cf35b135e9b8d8c26b47084bad77a08bd6f42e85f7a0803cf1c4'
save('client-certificate-before.json',{'sha256':fp,'origin':'https://192.168.1.10:30519'})
save('preflight-live.json',{'captured':datetime.datetime.now(datetime.timezone.utc).isoformat(),'candidate_version':candidate['Version'],'candidate_modify_index':candidate['JobModifyIndex'],'main_version':main['Version'],'main_modify_index':main['JobModifyIndex'],'ingress_version':ingress['Version'],'same_eight_allocations':True,'zero_restarts':True,'same_eight_volume_ids_and_placements':True})
print(json.dumps({'version':candidate['Version'],'index':candidate['JobModifyIndex'],'nodes':len(active),'read_only':True}))
