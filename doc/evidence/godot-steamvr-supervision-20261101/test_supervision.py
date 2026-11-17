"""Finite regression through the decision/dispatch owner used by live.py."""
import copy,json
from pathlib import Path
from supervision import Supervision

saved=json.loads((Path(__file__).resolve().parent.parent/'godot-steamvr-opportunity-20261101/closure263.json').read_text())
ready=saved['ready'];refresh=saved['withdrawal']['native_state']
assert refresh['signed_world'] is False and refresh['expired'] is False
assert 'Updating authorized view' in saved['withdrawal']['preceding_main_state']['status']
checks=[]
def check(value,name):
    assert value,name
    checks.append(name);print('PASS '+name)
def owner():
    sent=[];s=Supervision(100,lambda reason:sent.append(('finish\n',reason)))
    return s,sent

s,sent=owner();wall=ready['expires_ms']/1000-866
check(s.marker('VR263_READY',ready,110,wall),'first real ready starts participant interval')
deadlines=(s.participant_deadline,s.auth_deadline,s.deadline)
s.marker('VR263_STATE',refresh,259,wall+149)
check(sent==[],'saved263 Updating sends no normal finish')
check(deadlines==(s.participant_deadline,s.auth_deadline,s.deadline),'Updating preserves all original deadlines')
s.marker('VR263_STATE',ready,260,wall+150)
check(sent==[],'accepted again sends no finish and requires no renewed session')
check(not s.marker('VR263_READY',ready,300,wall+190),'repeated READY is not a new interval')
extended=copy.deepcopy(ready);extended['expires_ms']+=1000000
s.marker('VR263_READY',extended,310,wall+200)
check(deadlines==(s.participant_deadline,s.auth_deadline,s.deadline),'repeated READY cannot extend participant or authentic expiry')
check(s.cutoff(s.auth_deadline),'authentic absolute expiry dispatches normal finish')
s.cutoff(s.auth_deadline+1);s.command('stop',s.auth_deadline+2)
check(sent==[('finish\n','auth_expired')],'expiry plus later stop dispatch exactly once')

s,sent=owner();s.marker('VR263_READY',ready,110,ready['expires_ms']/1000-3000)
s.command('finish',130);s.command('stop',131);s.cutoff(4000)
check(sent==[('finish\n','participant_stop')],'explicit stop dispatches exactly once')
s,sent=owner();s.marker('VR263_READY',ready,110,ready['expires_ms']/1000-3000)
s.cutoff(1910);s.cutoff(1911)
check(sent==[('finish\n','participant_cutoff')],'original1800 participant cutoff dispatches exactly once')
s,sent=owner();s.marker('VR263_READY',ready,110,wall)
expired=copy.deepcopy(refresh);expired['expired']=True
s.marker('VR263_STATE',expired,120,wall+10);s.marker('VR263_STATE',expired,121,wall+11)
check(sent==[('finish\n','auth_expired')],'typed authentic expiry notification dispatches exactly once')
s,sent=owner();s.cutoff(280);s.cutoff(281)
check(sent==[('finish\n','preparation_failure')],'original preparation cutoff remains bounded')
s,sent=owner();s.marker('VR263_BLOCKER',{},120,wall);s.marker('VR263_BLOCKER',{},121,wall+1)
check(sent==[('finish\n','native_admission_failure')],'native admission failure dispatches exactly once')
s,sent=owner()
check(not s.marker('VR263_READY',ready,281,wall),'late READY cannot rescue an expired preparation bound')
check(sent==[('finish\n','preparation_failure')] and s.participant_deadline is None,'late READY sends exactly one bounded finish without starting participant time')
print('SUPERVISION_PASS '+json.dumps({'checks':len(checks),'saved263_event':True,'real_decision_owner':'supervision.Supervision','no_runtime_or_domain_work':True}))
