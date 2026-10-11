"""Retain current personal identities and committed prefixes without ledger writes."""
from pathlib import Path
import datetime,hashlib,json,ssl,urllib.parse,urllib.request
b=Path(__file__).resolve().parent
prior=b.parents[1]/'quod27-release-260/deployment'
base=json.loads((b.parents[1]/'quod27-personal-259-01/baseline.json').read_text())
origin='https://192.168.1.10:30519';ctx=ssl._create_unverified_context()
def get(path):
 with urllib.request.urlopen(origin+path,context=ctx,timeout=40) as r:return json.load(r)
def save(name,value):
 with (b/name).open('x') as f:json.dump(value,f,indent=2);f.write('\n')
summary=get('/explorer/api/summary');save('history-summary-before.json',summary)
checks=[]
for i,label,old_height in [(0,'human',350),(1,'world',176)]:
 expected=base['dependencies'][i];ns=expected['ns'];anchor=expected['anchor_hex'].lower()
 row=next(x for x in summary['namespaces'] if x['ns']==ns)
 assert row['genesis']==anchor and not row['syncing']
 height=row['applied'];assert height>=old_height
 for name,slot in [(label+'-tip-before.json',height),(label+'-retained-prefix-before.json',old_height)]:
  block=get('/explorer/api/block/'+urllib.parse.quote(ns,safe='')+'/'+str(slot));save(name,block)
  if slot==old_height:assert block==json.loads((prior/(label+'-tip-before.json')).read_text())
  checks.append({'file':name,'namespace':ns,'height':slot,'anchor':anchor,'sha256':hashlib.sha256((b/name).read_bytes()).hexdigest()})
save('history-before.json',{'captured':datetime.datetime.now(datetime.timezone.utc).isoformat(),'origin':origin,'blocks':checks,'read_only':True,'prior_260_prefixes_unchanged':True})
print(json.dumps({'prefixes':[{k:x[k] for k in ['namespace','height','anchor']} for x in checks],'read_only':True}))
