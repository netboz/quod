from pathlib import Path
import hashlib,json,re,subprocess
R=Path(__file__).resolve().parents[3]; E=Path(__file__).resolve().parent
sha=lambda p: hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None
history=[]
def stage(name,rows):
 records=[]
 for f,h in rows:
  actual=sha(R/f);records.append({'path':f,'recorded_sha256':h,'current_sha256':actual,'exact_match':h==actual})
 history.append({'campaign':name,'files':records})
p=R/'doc/evidence/stage2-presentation-limits-20261103/inputs/account.json'
stage('presentation',[(x['path'],x['current_sha256']) for x in json.loads(p.read_text())['production_delta']['paths']])
p=R/'doc/evidence/stage2-presentation-boundaries-20261103/inputs/account-current02.json'
stage('boundaries',[(x['path'],x['current_sha256']) for x in json.loads(p.read_text())['production_delta']['paths']])
p=R/'doc/evidence/stage2-remaining-admission-20261103/application01/current-delta.json'
stage('remaining-admission',[(f,x['after'] if not (x['after']==hashlib.sha256(b'').hexdigest() and not (R/f).exists()) else None) for f,x in json.loads(p.read_text())['files'].items()])
p=R/'doc/evidence/stage2-renewal-delivery-20261103/application01.json'
stage('renewal',[(f,x['after']) for f,x in json.loads(p.read_text())['files'].items()])
latest={}
for c in history:
 for row in c['files']:latest[row['path']]={**row,'campaign':c['campaign']}
# Bind later predicate-removal and finalization changes without relabelling the
# earlier test campaigns as runs of those later files.
removal=json.loads((R/'doc/evidence/stage2-predicate-removal-20261103/inputs/final-source.json').read_text())
later={}
comment=json.loads((R/'doc/evidence/stage2-renewal-delivery-20261103/comment-correction01.json').read_text())
later[comment['path']]={'sha256':comment['after'],'evidence':'renewal-delivery/comment-correction01'}
for key in ['production_files','test_files','documentation']:
 for f,h in removal[key].items():later[f]={'sha256':h,'evidence':'predicate-removal/final-source/'+key}
for row in latest.values():
 if not row['exact_match']:
  known=later.get(row['path'])
  row['later_delivery']=known
  row['later_delivery_matches']=bool(known and known['sha256']==row['current_sha256'])
receipts={}
for p in sorted((R/'doc/evidence/stage2-remaining-admission-20261103/inputs').glob('applied-*.json')):
 m=json.loads(p.read_text())
 receipts[str(p.relative_to(R))]={'sha256':sha(p),**{k:v for k,v in m.items() if k in ['true_exit','stdout_eof','stderr_eof','steps']}}

production=[]
for root in ['src','include','priv/ontologies','client/src','client/godot/Core','_build/default/lib/erlog/src']:
 production += [p for p in (R/root).rglob('*') if p.is_file() and p.suffix in ['.erl','.hrl','.pl','.js','.cs']]
texts={str(p.relative_to(R)):p.read_text(errors='replace') for p in production}
oldfiles=[]
for base in ['doc/evidence/stage2-presentation-boundaries-20261103/before/include','doc/evidence/stage2-presentation-boundaries-20261103/before-admission/include','doc/evidence/stage2-remaining-admission-20261103/proposal-before/include']:
 oldfiles+=list((R/base).glob('*.hrl'))
old=set()
for p in oldfiles:old.update(re.findall(r'-define\((\w+)',p.read_text()))
current=set()
for text in texts.values():current.update(re.findall(r'-define\((\w+)',text))
retired=sorted(old-current)
hits=[]
for f,text in texts.items():
 for i,line in enumerate(text.splitlines(),1):
  for symbol in re.findall(r'\?([A-Za-z_][A-Za-z_0-9]*)',line):
   if symbol in retired:hits.append({'path':f,'line':i,'symbol':symbol,'text':line.strip()})
legacy_imports=[{'path':f,'line':i,'text':line.strip()} for f,text in texts.items() for i,line in enumerate(text.splitlines(),1) if 'retired_remaining_sizes' in line or 'retired_boundary_sizes' in line]
callerfile=R/'doc/evidence/stage2-presentation-boundaries-20261103/inputs/remaining-limit-callers.txt'
callerfiles=sorted(set(line.split(':')[0] for line in callerfile.read_text().splitlines()))
result={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),
 'erlog_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=R/'_build/default/lib/erlog',text=True).strip(),
 'original_caller_inventory_entries':len(callerfile.read_text().splitlines()),'original_caller_files':callerfiles,
 'campaign_hash_comparison':history,'latest_campaign_comparison':list(latest.values()),
 'retired_header_symbols':retired,'retired_symbol_references_in_production':hits,'test_threshold_imports_in_production':legacy_imports,
 'production_source_hashes':{f:sha(R/f) for f in texts},'recorded_test_receipts':receipts,
 'scope':'Original presentation/boundary/consolidated inventories; source and recorded-evidence audit, not all repository policies or a new full runtime acceptance.',
 'production_delta':{'added':0,'removed':0},'runtime_tests_repeated':False}
(E/'audit.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'head':result['head'],'inventory_entries':result['original_caller_inventory_entries'],'scanned_source_files':len(texts),'retired_symbols':len(retired),'live_retired_references':hits,'test_threshold_imports':legacy_imports,'campaigns':[{'name':x['campaign'],'same':sum(r['exact_match'] for r in x['files']),'count':len(x['files'])} for x in history],'later_changes':[{'path':x['path'],'evidence_matches':x.get('later_delivery_matches')} for x in latest.values() if not x['exact_match']]},indent=2))
