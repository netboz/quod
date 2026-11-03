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
def owner(prepared=True):
    sent=[];s=Supervision(100,lambda reason:sent.append(('finish\n',reason)),lambda:None)
    if prepared:
        s.marker('VR263_PREPARED',{},101,0)
        s.command('begin',102,mapped=True)
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

def waiting(expires=1100000):
    dispatched=[]
    s=Supervision(100,lambda reason:dispatched.append(('finish',reason)),lambda:dispatched.append(('begin',None)))
    s.marker('VR263_PREPARED',{'expires_ms':expires},120,1000)
    return s,dispatched
s,sent=waiting();original=(s.deadline,s.auth_deadline,s.auth_expires_ms)
check(s.participant_deadline is None and sent==[],'PREPARED does not start XR or participant time')
s.command('begin',121,mapped=False)
check(sent==[] and s.begin_at is None,'unmapped begin neither dispatches nor queues work')
s.command('begin',122,mapped=True);s.command('begin',123,mapped=True)
check(sent==[('begin',None)] and s.begin_at==122,'mapped prepared begin dispatches exactly once')
s.marker('VR263_PREPARED',{'expires_ms':999999999},124,1004);s.command('status',125,mapped=True)
check(original==(s.deadline,s.auth_deadline,s.auth_expires_ms),'begin repeated preparation and status retain original bounds and expiry')
s.marker('VR263_STATE',refresh,126,1006)
check(sent==[('begin',None)],'signed Updating after begin neither closes nor repeats setup')
s.command('stop',127,mapped=True);s.command('begin',128,mapped=True)
check(sent==[('begin',None),('finish','participant_stop')],'stop after begin closes once and no later begin revives it')
s,sent=waiting();s.command('finish',121,mapped=True);s.command('begin',122,mapped=True);s.command('stop',123)
check(sent==[('finish','participant_stop')] and s.begin_at is None,'stop before begin closes once without any XR start')
s,sent=waiting(expires=2000000);s.command('begin',280,mapped=True);s.command('begin',281,mapped=True)
check(sent==[('finish','preparation_failure')] and s.begin_at is None,'late begin cannot rescue original preparation cutoff')
s,sent=waiting(expires=1001000);s.command('begin',121,mapped=True)
check(sent==[('finish','auth_expired')] and s.begin_at is None,'authentic earlier expiry refuses begin')
s,sent=waiting();s.marker('VR263_READY',ready,121,1001)
check(s.participant_deadline is None and sent==[],'unexpected READY before explicit begin cannot admit participant')
s,sent=waiting(expires=4000000);s.command('begin',125,mapped=True)
s.marker('VR263_READY',{'expires_ms':4000000},130,1010);d=(s.deadline,s.participant_deadline,s.auth_deadline)
s.marker('VR263_READY',{'expires_ms':5000000},140,1020);s.command('begin',141,mapped=True)
check(d==(s.deadline,s.participant_deadline,s.auth_deadline) and sent==[('begin',None)],'repeated READY and begin never restart any deadline')
s=Supervision(100,lambda reason:None,lambda:(_ for _ in ()).throw(BrokenPipeError('bounded test')))
s.marker('VR263_PREPARED',{},110,1000)
try:s.command('begin',111,mapped=True)
except BrokenPipeError:pass
else:raise AssertionError('expected dispatch failure')
check(s.begin_at==111 and not s.command('begin',112,mapped=True),'uncertain begin write is fenced before I/O and never retried')
s,sent=owner(prepared=False);s.command('begin',101,mapped=True);s.marker('VR263_PREPARED',{},102,1000)
check(s.begin_at is None and sent==[],'early begin is ignored rather than saved for later setup')
print('SUPERVISION_PASS '+json.dumps({'checks':len(checks),'saved263_event':True,'real_decision_owner':'supervision.Supervision','no_runtime_or_domain_work':True}))
