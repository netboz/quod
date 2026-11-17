"""Retain existing tracker/integration receipts; no tracker call or new test."""
import hashlib,json,os,sys,time
from pathlib import Path
sys.dont_write_bytecode=True
os.umask(0o077)
task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
ev=Path(__file__).resolve().parent
private=task/'private/completion124-integration01'
private.mkdir(mode=0o700,exist_ok=False)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
batch=json.loads(sys.argv[1])
write(private/'actual-batch-and-control-receipts.json',batch)
rows=batch['inbox']['prompts']
assert all(isinstance(r['prompt'],str) and len(r['prompt'])>0 for r in rows)
write(ev/'instruction-integration.json',{
 'read_kind':'Entire actual full-text batch read; list-only, NOT consumption. consume unavailable.',
 'private_receipt':str(private/'actual-batch-and-control-receipts.json'),
 'private_receipt_sha256':digest(private/'actual-batch-and-control-receipts.json'),
 'rows':[{'id':r['id'],'status':r['status'],'body_sha256':hashlib.sha256(r['prompt'].encode()).hexdigest(),'body_bytes':len(r['prompt'].encode())} for r in rows],
 'executing_instruction':'meta-1793393931668-s8l2ari',
 'new_case19_authority':'meta-1793394257072-mc7ce2d',
 'no_new_case20_authority':True,'physical_control_true_exit':batch['close_result']['exit_code'],
 'scope':'Only this completion reconciliation and separately authorized case19. No second writer/model/review or new production change.'})
reads=task/'private/completion124-tracker01'
def nested(p):
    outer=json.loads(p.read_text());assert not outer.get('isError',False)
    texts=[json.loads(c['text']) for c in outer['content'] if c['type']=='text']
    assert len(texts)==1
    assert not texts[0].get('isError',False)
    return texts[0]
items={};references={}
for name in ['QUO-65','QUO-60','QUO-59','QUO-27','tsk_01M5PY8TEXKG858WBZJ1RHC6EW','QUO-62','QUO-64']:
    d=json.loads((reads/(name+'.txt')).read_text())['structured']['item']
    radar=nested(reads/(name+'-radar.stdout'))
    items[name]={'id':d['id'],'issueKey':d.get('issueKey'),'title':d['title'],'status':d['status'],'progress':(d.get('customFields') or {}).get('progress'),'radar_and_get_nested_errors':False}
for p in sorted(reads.iterdir()):
    assert p.is_file() and p.stat().st_mode&0o7777==0o600
    references[p.name]={'path':str(p),'sha256':digest(p),'bytes':p.stat().st_size,'mode':'0600'}
link=nested(reads/'QUO-65-link.stdout')['structured']
assert link['action']=='linked' and link['linkedCount']==0
write(ev/'tracker-read-disposition.json',{
 'route':{'tool':'/home/yan/src/quod/nimbalyst-local/tools/tracker-call.mjs','explicit_project':'/home/yan/src/quod','own_session':'ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f'},
 'operations':'Seven fresh radar/get pairs, then one session-link call. All actual original tool children0; no calls repeated by this script.',
 'items':items,'radar_shared_signals_reported':0,'radar_recent_threads_reported':0,
 'link_result':{'action':link['action'],'linkedCount':0,'shared_attribution_proven':False},
 'publication_block':'Body/checklist/description automatic approval block preserved; no publication retry or bypass; no metadata correction.',
 'stale_body_disposition':'Source and accepted evidence take precedence over historical checklist/unstarted wording; no full Stage2 credit.',
 'private_original_receipts':references})
write(ev/'work-disposition.json',{
 'new_production_test_spec_changes':0,'new_builds':0,'unchanged_gate_reruns':0,'old_API_bytes_read':0,
 'independent_software_gap_demonstrated':False,'remaining_M4_prerequisite':'Actual physical mapped interactions and scoped hardware lifecycle/pose/travel/exit/comfort qualification.',
 'case19':'Actual authorized fresh signed opportunity; sign-in expired before zero-to-one target activation, zero native edges, no human result supplied; normal close all0.',
 'inspection_failures':[{'kind':'search','result':'No specs directory; rg exit2 retained in original tool transcript, relevant existing docs read.'},{'kind':'attempted private derived tracker-summary write','result':'Child1 read-only-filesystem before first output; subsequent missing-file read2. Existing original tracker receipts remained intact; no tracker operation replay.'},{'kind':'receipt binder01','result':'Child1 schema assumption: edge lists compared to numeric zero. New labelled binder02 checks exact list type/empty length and reuses completed display/stream checks; child0.'}],
 'scope_limits':['No startup campaign or motion tuning.','No broad D5/D6/D7/terrain credit or ontology redesign.','No case20/automatic reconnect, unknown-write replay, commit, M5 or full M4 acceptance.'],
 'tracker_block':'Publication remains blocked and was not retried.','feature_inventory_impact':'None: no new product feature or behavior in this reconciliation.'})
print(json.dumps({'recorded_existing_tracker_receipts':len(references),'full_instruction_rows':len(rows),'production_delta':0,'new_tests_or_builds':0,'physical_closed':batch['close_result']['exit_code']==0}),flush=True)
