"""Finite supervisor/dispatch checks using real stdin pipes; no application/window."""
import json,select,subprocess,sys
from owned_commands import OwnedCommands
from pipe_ownership import identity,engine_pipes
from supervision import Supervision

checks=[]
def check(value,name):
    assert value,name
    checks.append(name);print('PASS '+name,flush=True)

def rejected(call,name):
    try:call()
    except AssertionError:check(True,name)
    else:raise AssertionError(name)

class Case:
    def __init__(self,expires=4000000):
        self.child=subprocess.Popen([sys.executable,'-B','-c',
            "import sys;print('OWNED_CHILD',flush=True)\nfor line in sys.stdin:\n print(line.strip(),flush=True)\n if line.strip()=='finish':break"],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        assert select.select([self.child.stdout],[],[],5)[0] and self.child.stdout.readline()==b'OWNED_CHILD\n'
        self.incarnation=identity(self.child.pid);self.pipes=engine_pipes(self.child,self.incarnation)
        self.owned={'pid':self.child.pid,'incarnation':self.incarnation[:],'address':'test-only-address'}
        self.windows=[{'pid':self.child.pid,'address':self.owned['address'],'mapped':True}]
        self.now=100;self.writes=[];self.query=lambda:self.windows
        self.commands=OwnedCommands(self.child,self.incarnation,lambda:self.owned,lambda:self.query(),lambda:self.now,lambda name,reason:self.writes.append((name,reason)))
        self.supervisor=Supervision(100,self.commands.finish,lambda:self.commands.begin(self.supervisor))
        self.expires=expires
    def prepared(self):
        self.now=110;self.supervisor.marker('VR263_PREPARED',{'expires_ms':self.expires},self.now,1000)
    def begin(self,authorized=True):self.commands.delegated_begin(self.supervisor,authorized)
    def close(self):
        self.supervisor.stop('participant_stop',self.now)
        self.child.stdin.close();assert self.child.wait(timeout=5)==0
        lines=self.child.stdout.read().decode().splitlines();assert self.child.stderr.read()==b''
        check(lines==[name for name,_ in self.writes],'actual delivered lines match fenced dispatches with true child0 and both EOF')
        return lines

c=Case()
try:
    c.begin();check(c.writes==[],'delegated authority does not queue an early begin before PREPARED')
    c.prepared();deadlines=(c.supervisor.deadline,c.supervisor.auth_deadline,c.supervisor.auth_expires_ms)
    c.begin(False);check(c.writes==[],'artifact-only preparation provides no launch/begin authorization')
    original=c.owned;c.owned=None;c.begin();check(c.writes==[],'PREPARED without an exact mapped binding does not begin');c.owned=original
    c.now=111;c.begin();c.begin();check(c.writes==[('begin',None)] and c.supervisor.begin_at==111,'local delegated mapped PREPARED dispatches one begin without parent round trip')
    check(deadlines==(c.supervisor.deadline,c.supervisor.auth_deadline,c.supervisor.auth_expires_ms),'local delegation preserves original preparation and authentic expiry')
    c.supervisor.marker('VR263_VISUAL_READY',{'expires_ms':c.expires},112,1002)
    deadlines=(c.supervisor.deadline,c.supervisor.auth_deadline,c.supervisor.participant_deadline)
    c.supervisor.marker('VR263_STATE',{'expired':False,'signed_world':False,'operation_available':False,'status':'Updating authorized view…'},113,1003)
    c.supervisor.marker('VR263_STATE',{'expired':False,'signed_world':True,'operation_available':True},114,1004)
    c.supervisor.marker('VR263_VISUAL_READY',{'expires_ms':c.expires+999999},115,1005);c.begin()
    check(c.writes==[('begin',None)] and deadlines==(c.supervisor.deadline,c.supervisor.auth_deadline,c.supervisor.participant_deadline),'refresh withdrawal/reacceptance and repeated READY neither finish nor restart any bound')
finally:c.close()

c=Case()
try:
    c.prepared();original=c.owned
    for field,value in [('pid',c.child.pid+1),('incarnation',[*c.incarnation[:2],c.incarnation[2]+1]),('address','another-address')]:
        c.owned={**original,field:value};rejected(c.commands.mapped,'wrong '+field+' refuses the exact owned mapping')
    c.owned=original
    for index in [0,1,2]:
        old=c.commands.expected;c.commands.expected=old[:];c.commands.expected[index]+=1
        rejected(c.commands.mapped,'wrong executable dev/inode/start component '+str(index)+' refuses dispatch');c.commands.expected=old
    c.windows[0]['mapped']=False;rejected(c.commands.mapped,'unmapped window refuses begin');c.windows[0]['mapped']=True
    c.windows.append(c.windows[0].copy());rejected(c.commands.mapped,'ambiguous mapped address refuses begin');c.windows.pop()
    check(c.writes==[],'all mapping refusals delivered no begin or domain command')
finally:c.close()

for expires,when,reason in [(4000000,280,'preparation_failure'),(1001000,111,'auth_expired')]:
    c=Case(expires)
    try:
        c.prepared();c.now=when;c.begin();c.begin()
        check(c.writes==[('finish',reason)] and c.supervisor.begin_at is None,'late begin at '+reason+' only dispatches one normal finish')
    finally:c.close()

c=Case()
try:
    c.prepared();c.supervisor.command('finish',111,mapped=True);c.begin()
    check(c.writes==[('finish','participant_stop')],'stop before begin cannot revive or replay setup')
finally:c.close()

c=Case()
try:
    c.prepared();c.now=279
    def delayed_query():c.now=280;return c.windows
    c.query=delayed_query;c.begin();c.begin()
    check(c.writes==[('finish','preparation_failure')],'mapped snapshot that reaches the original cutoff cannot send a late begin')
finally:c.close()

c=Case()
try:
    c.prepared();c.now=111;c.begin()
    c.supervisor.marker('VR263_VISUAL_READY',{'expires_ms':c.expires},112,1002)
    c.now=1912;c.supervisor.cutoff(c.now);c.begin();c.supervisor.command('stop',c.now)
    check(c.writes==[('begin',None),('finish','participant_cutoff')],'original participant1800 cutoff keeps exactly one owned finish')
finally:c.close()

print('OWNED_COMMANDS_PASS '+json.dumps({'checks':len(checks),'real_owner':'owned_commands.OwnedCommands + supervision.Supervision','real_pipe_children':7,'runtime_or_application_or_window':False,'host_input':False,'signals':0,'eof':True}))
