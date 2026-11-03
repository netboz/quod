"""Add the actual completed connector observation to the retained retest report."""
import hashlib,json,shutil,sys
from pathlib import Path
sys.dont_write_bytecode=True
ev=Path(__file__).resolve().parent;root=Path.cwd()
def load(p):return json.loads(Path(p).read_text())
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
old=ev/'inputs/pre-offer-qualification.json';assert not old.exists();shutil.copy2(ev/'qualification.json',old)
q=load(old);r=load(ev/'display-reconnect-retest01/result.json')
wpath=ev.parent/'godot-m4-vive-physical-20261029/logs/display-reconnect-retest01-run.json';w=load(wpath)
response=load(ev/'inputs/hdmi-reconnect-response-77.json')['answer']
assert response['respondedBy']=='desktop' and response['respondedAt']==1793357681007
assert response['answers']['vive_hdmi_reconnect']['selectedId']=='reconnected'
assert r['passed'] and r['observer_exit']==0 and r['lease_offer'] and r['participant_response']=='finish'
assert not r['reader_errors'] and all(r['eof'].values())
assert w['child_exit']==0 and not w['reader_errors'] and all(w['eof'].values()) and not w.get('timed_out')
lines=(ev/'display-reconnect-retest01/stdout.log').read_text().splitlines()
assert 'LEASE_SNAPSHOT devices=1 connectors=0 done_events=1' in lines
assert any(line.endswith('name=HDMI-A-1') for line in lines)
assert any(line.endswith('drm_connector=828') for line in lines)
assert 'LEASE_NOTIFICATION connectors=1' in lines and 'DISPLAY_INVENTORY_COMPLETE status=0' in lines
d=r['display_rule'];assert d['desktop_unchanged'] and d['config_unchanged']
assert d['enable']['child_exit']==d['restore']['child_exit']==0
assert next(m for m in d['after']['monitors'] if m['name']=='HDMI-A-1')['disabled']
q['human_assisted_readonly_offer_observation']={'label':'display-reconnect-retest01',
 'participant_answer':response,'connector_name':'HDMI-A-1','connector_id':828,'lease_offer_notification':True,
 'observer_exit':0,'driver_exit':0,'wrapper_exit':0,'observer_eof':r['eof'],'wrapper_eof':w['eof'],
 'reader_errors':[],'timed_out':False,'elapsed_seconds':r['elapsed_seconds'],
 'hdmi_restored_disabled':True,'other_displays_unchanged':True,'config_files_unchanged':76,
 'lease_acquisition':False,'runtime_or_app_started':False,
 'case_receipt_sha256':sha(ev/'display-reconnect-retest01/result.json'),'wrapper_receipt_sha256':sha(wpath),
 'timing_limit':'Protocol completion line was read before finish; actual child exit was waited/recorded after finish. No pre-finish poll/absence receipt.'}
q['remaining'][0]='Current HDMI-A-1/id828 offer was observed after the actual one-HDMI reconnect. No subsequent runtime/app case has run; acquisition, current tracking and corrected-payload physical qualification remain unestablished. A distinct next native case requires coordinator scope and actual refreshed ownership/admission readiness.'
(ev/'qualification.json').write_text(json.dumps(q,indent=2)+'\n')
print(json.dumps({'explicit_completion':True,'read_only_offer_observer_passed':True,'godot_application_launched':False,'historical_cases_still_failed':True}))
