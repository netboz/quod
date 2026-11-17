"""Finite fake-protocol/query/incarnation cases. Never invokes the live runner."""
import json,sys
from pathlib import Path
sys.dont_write_bytecode=True
ev=Path(__file__).resolve().parent
sys.path.insert(0,str(ev.parent/'godot-m4-vive-retest10-20261030'))
from focus_events import FocusEvents,RemainingBudget,SuccessorRecipient,RecipientLookupError

checks=[]
def check(ok,name):
    if not ok:raise AssertionError(name)
    checks.append(name);print('PASS '+name,flush=True)

class Clock:
    def __init__(self,now=10):self.now=now
    def __call__(self):return self.now

def binding(role='coordinator',address='0xdef'):
    return dict(role=role,address=address,pid=4242,starttime='12345',
                executable='/non-sensitive/example-program',device=7,inode=88)

class Case:
    def __init__(self,role='coordinator',deadline=100,now=10):
        self.clock=Clock(now);self.rows=[];self.calls=[];self.identity_calls=[]
        self.binding=binding(role);self.bindings=[self.binding]
        self.clients=[dict(address='0xdef',pid=4242,mapped=True,title='PRIVATE_TITLE',**{'class':'PRIVATE_CLASS'})]
        self.identity=('12345',7,88);self.query_error=None;self.identity_error=None
        self.query_cost=0;self.identity_cost=0
        self.parser=FocusEvents('0xabc',deadline,self.rows.append)
        self.budget=RemainingBudget(deadline,self.clock)
        self.recipient=SuccessorRecipient(self.bindings,self.budget,self.query,self.incarnation,self.rows.append,self.clock,self.utc)
        self.parser.on_loss=self.recipient
    def utc(self):return 'example-utc-'+str(self.clock.now)
    def query(self,*,timeout):
        self.calls.append(timeout);self.clock.now+=self.query_cost
        if self.query_error is not None:raise self.query_error
        return self.clients
    def incarnation(self,value):
        self.identity_calls.append(value['pid']);self.clock.now+=self.identity_cost
        if self.identity_error is not None:raise self.identity_error
        return self.identity
    def feed(self,data):self.parser.feed(data,self.clock(),self.utc())
    def lose(self,payload=b'def'):
        self.feed(b'activewindowv2>>abc\n');self.feed(b'activewindowv2>>'+payload+b'\n')
    def result(self):return next(r for r in self.rows if r['kind']=='successor_recipient')

for role in ['task','coordinator','runtime']:
    c=Case(role);c.lose()
    check(c.result()['role']==role and c.result()['validity']=='confirmed_at_lookup' and c.calls==[5] and c.identity_calls==[4242],
          role+' requires exact caller address, current mapped PID and process incarnation')
c=Case();c.lose(b'123')
check(c.result()['role']=='unknown' and c.result()['validity']=='unbound' and c.calls==[],'unmatched recipient is unknown without querying unrelated owners')
c=Case();c.lose(b'')
check(c.result()['role']=='none' and c.result()['validity']=='empty_notification' and c.calls==[],'empty successor notification is none with no lookup')
for change in ['pid','mapped','missing','duplicate']:
    c=Case()
    if change=='pid':c.clients[0]['pid']=4343
    elif change=='mapped':c.clients[0]['mapped']=False
    elif change=='missing':c.clients=[]
    else:c.clients*=2
    c.lose()
    check(c.result()['role']=='unknown' and c.result()['validity']=='window_owner_mismatch' and not c.identity_calls,
          change+' window binding refuses role confirmation')
for value in [('99999',7,88),('12345',8,88),('12345',7,99)]:
    c=Case();c.identity=value;c.lose()
    check(c.result()['role']=='unknown' and c.result()['validity']=='incarnation_mismatch',
          'recycled PID or changed executable identity is unknown: '+str(['starttime','device','inode'][[('99999',7,88),('12345',8,88),('12345',7,99)].index(value)]))
c=Case();c.identity_error=ProcessLookupError('PRIVATE_IDENTITY');c.lose()
check(c.result()['role']=='unknown' and c.result()['validity']=='incarnation_unavailable','vanished process stays unknown without another lookup')
c=Case();c.lose();c.feed(b'activewindowv2>>def\nactivewindowv2>>123\nactivewindowv2>>abc\nactivewindowv2>>def\n')
check(c.calls==[5] and sum(r['kind']=='successor_recipient' for r in c.rows)==1,'duplicate notices and later losses never restart the one-shot classification')
c=Case();c.feed(b'activewindowv2>>def\n');c.parser.snapshot(True,11,'snapshot');c.feed(b'activewindowv2>>123\n')
check(not c.recipient.done and not c.calls,'initial not-owned and an unordered owned snapshot cannot invent a loss anchor')
c.feed(b'activewindowv2>>abc\nactivewindowv2>>def\n')
check(c.result()['role']=='coordinator','a later real owned event supplies the required loss anchor')
c=Case();c.feed(b'activewin');c.feed(b'dowv2>>ab');c.feed(b'c\nactivewindowv2>>de')
check(not c.calls and c.parser.events==1,'fragmented successor cannot trigger before its complete line')
c.feed(b'f\n')
check(c.result()['role']=='coordinator' and len(c.calls)==1,'completed fragmented successor is classified once')
c=Case();c.feed(b'activewindow>>PRIVATE_CLASS,PRIVATE_TITLE\nactivewindowv2>>abc\nactivewindowv2>>def\n')
text=json.dumps(c.rows)
check(all(x not in text for x in ['PRIVATE_TITLE','PRIVATE_CLASS','0xdef','4242','12345','example-program','"address"','"pid"','"clients"']),
      'retained rows exclude titles, addresses, process details and client replies')
c=Case();c.query_error=ValueError('PRIVATE_QUERY address0xdef titlePRIVATE_TITLE')
try:c.lose();raise AssertionError('query failure swallowed')
except RecipientLookupError as error:message=str(error)
check(c.result()['validity']=='lookup_error' and c.result()['role']=='unknown' and 'PRIVATE' not in message+json.dumps(c.rows),
      'query errors propagate through a fixed sanitized failure without input disclosure')
c=Case();c.identity_error=PermissionError('PRIVATE_IDENTITY')
try:c.lose();raise AssertionError('identity error swallowed')
except RecipientLookupError:pass
check(c.result()['validity']=='lookup_error' and 'PRIVATE' not in json.dumps(c.rows),'identity I/O errors remain explicit and private')
c=Case();c.clients={'PRIVATE_REPLY':'PRIVATE_TITLE'}
try:c.lose();raise AssertionError('malformed reply accepted')
except RecipientLookupError:pass
check(c.result()['role']=='unknown' and 'PRIVATE' not in json.dumps(c.rows),'malformed query reply cannot confirm or disclose a role')
c=Case(deadline=100,now=100);c.lose()
check(c.calls==[] and not c.recipient.done and c.rows[0]['kind']=='absolute_deadline','expired parser refuses the event before any successor lookup')
c=Case(deadline=100,now=100)
try:c.recipient(b'def',99,'old-event');raise AssertionError('expired callback queried')
except TimeoutError:pass
check(c.calls==[] and c.result()['validity']=='expired','expired callback also refuses I/O and reports expiry explicitly')
c=Case(deadline=100,now=99.75);c.query_cost=0.25
try:c.lose();raise AssertionError('late query result confirmed')
except TimeoutError:pass
check(c.calls==[0.25] and c.identity_calls==[] and c.result()['validity']=='expired','successor query uses remaining absolute budget and expiry prevents the next operation')
c=Case(deadline=100,now=99.5);c.identity_cost=0.5
try:c.lose();raise AssertionError('late incarnation confirmed')
except TimeoutError:pass
check(c.result()['role']=='unknown' and c.result()['validity']=='expired','incarnation completing after the deadline cannot confirm a role')
c=Case();c.clock.now=11;c.query_cost=0.25;c.identity_cost=0.125;c.lose();r=c.result()
check(r['event_receive_monotonic']==11 and r['lookup_start_monotonic']==11 and r['lookup_end_monotonic']==11.25 and
      r['incarnation_checked_monotonic']==11.375 and r['monotonic']==11.375,'event receive, query interval and incarnation confirmation have separate timestamps')
c=Case();c.feed(b'activewindowv2>>abc\nactivewindowv2>>PRIVATE_BAD\n')
check(c.parser.closed and c.calls==[] and 'PRIVATE_BAD' not in json.dumps(c.rows),'malformed successor closes the existing parser without a lookup or payload disclosure')
c=Case();c.feed(b'activewindowv2>>abc\nactivewindowv2>>de');c.parser.eof(12,'eof')
check(c.calls==[] and c.rows[-1]['kind']=='remote_eof' and c.rows[-1]['incomplete_line'],'remote EOF on a fragmented successor cannot invent a recipient')
c=Case();c.lose();c.parser.finish(12,'finish')
check(c.rows[-1]['kind']=='local_subscription_close' and not any(r['kind']=='remote_eof' for r in c.rows),'local finish after classification remains distinct from remote EOF')
for bad in ['duplicate','role']:
    c=Case();values=[binding(),binding()] if bad=='duplicate' else [binding('PRIVATE_ROLE')]
    try:SuccessorRecipient(values,c.budget,c.query,c.incarnation,c.rows.append,c.clock,c.utc);raise RuntimeError('ambiguous binding accepted')
    except AssertionError:pass
    check(c.calls==[] and c.rows==[],bad+' role configuration refuses before any lookup or retained input')
c=Case();c.bindings[0]['role']='runtime';c.lose()
check(c.result()['role']=='coordinator','immutable configured bindings cannot change through a caller dictionary mutation')
result={'passed':True,'count':len(checks),'checks':checks,
 'scope':'PURE non-sensitive protocol fragments, fake clocks/query replies/incarnations only. No IPC/commands/process/window/device/runtime activity.',
 'live_listener_or_lookup_armed':False,'recipient_is_not_initiator':True,'case13_authorized_or_run':False,
 'original6_budget_stdin_build_server_native_suites_repeated':False}
(ev/'recipient-checks-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
