#!/usr/bin/env python3
"""Read-only Nomad inventory; output only selected public routing/storage identities."""
import json
from pathlib import Path
import re
import urllib.request

base='http://192.168.1.10:4646'
def get(path):
    with urllib.request.urlopen(base+path,timeout=15) as r:return json.load(r)
jobs=get('/v1/jobs')
result={'nomad_addr':base,'jobs_summary':[{'id':x['ID'],'namespace':x['Namespace'],'status':x['Status']} for x in jobs], 'quod_jobs':[]}
for brief in jobs:
    name=brief['ID']
    if not (name.startswith('quod') or name=='traefik'):continue
    job=get('/v1/job/'+name)
    row={'id':name,'namespace':job['Namespace'],'version':job['Version'],'modify_index':job['ModifyIndex'],'groups':[],'allocations':[]}
    for group in job.get('TaskGroups',[]):
        g={'name':group['Name'],'count':group['Count'],'volumes':group.get('Volumes'), 'services':[], 'images':[], 'root_configuration':[]}
        for task in group.get('Tasks') or []:
            g['images'].append(task.get('Config',{}).get('image'))
            for service in task.get('Services') or []:
                g['services'].append({k:service.get(k) for k in ['Name','PortLabel','Tags','AddressMode']})
            for template in task.get('Templates') or []:
                text=template.get('EmbeddedTmpl','')
                # Extract only explicit root namespace/hash and persistent path lines.
                for line in text.splitlines():
                    if re.search(r'^\s*(genesis_hash|data_dir|namespace)\s*=',line):g['root_configuration'].append(line.strip())
            config=task.get('Config') or {}
            if task['Name']=='traefik':
                g['ingress_args']=config.get('args')
                g['backend_selectors']=[re.findall(r'\$backends := service "([^"]+)"', t.get('EmbeddedTmpl','')) for t in task.get('Templates') or []]
        row['groups'].append(g)
    for a in get('/v1/job/'+name+'/allocations'):
        d=get('/v1/allocation/'+a['ID'])
        row['allocations'].append({k:d.get(k) for k in ['ID','Name','Namespace','JobID','TaskGroup','NodeID','NodeName','ClientStatus','DesiredStatus','CreateIndex','ModifyIndex','AllocatedResources']})
    result['quod_jobs'].append(row)
try:
    volumes=get('/v1/volumes?type=host')
    result['host_volumes']=[]
    for v in volumes or []:
        if not v.get('Name','').startswith('quod'):continue
        d=get('/v1/volume/host/'+v['ID'])
        result['host_volumes'].append({k:d.get(k) for k in ['ID','Name','Namespace','NodeID','HostPath','State','RequestedCapabilities','Allocations','Constraints']})
except Exception as error:result['host_volume_error']=str(error)
path=Path(__file__).with_name('network-inventory.json');path.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
