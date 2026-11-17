"""Pure fake-clock/I/O checks for the actual bootstrap remaining-budget owner."""
import ast,hashlib,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
from focus_events import RemainingBudget
ev=Path(__file__).resolve().parent;checks=[]
class Clock:
    def __init__(self,now):self.now=now
    def __call__(self):return self.now
class IO:
    def __init__(self,clock,cost=0):self.clock=clock;self.cost=cost;self.timeouts=[]
    def __call__(self,*,timeout):self.timeouts.append(timeout);self.clock.now+=self.cost;return 'recorded'
class Connection:
    def __init__(self,clock):self.clock=clock;self.timeouts=[];self.connects=0
    def settimeout(self,value):self.timeouts.append(value)
    def connect(self,path):self.connects+=1;self.clock.now+=0.5
def check(ok,name):
    if not ok:raise AssertionError(name)
    checks.append(name);print('PASS '+name)
clock=Clock(10);budget=RemainingBudget(100,clock);io=IO(clock);budget.call(io)
check(io.timeouts==[5],'bootstrap keeps its existing5s cap when budget is ample')
clock.now=99.875;budget.call(io)
check(io.timeouts[-1]==0.125,'near-expiry I/O receives only the actual remaining budget')
clock=Clock(99.75);budget=RemainingBudget(100,clock);io=IO(clock,0.25);budget.call(io)
try:budget.call(io);raise AssertionError('expired next operation executed')
except TimeoutError:pass
check(io.timeouts==[0.25],'expiry after one I/O prevents the next operation entirely')
clock=Clock(100);budget=RemainingBudget(100,clock);io=IO(clock)
try:budget.call(io);raise AssertionError('initial expired operation executed')
except TimeoutError:pass
check(io.timeouts==[],'already-expired bootstrap refuses before calling I/O')
clock=Clock(99.9375);budget=RemainingBudget(100,clock);connection=Connection(clock);budget.connect(connection,'/non-sensitive-example')
try:budget.connect(connection,'/non-sensitive-example');raise AssertionError('expired connect executed')
except TimeoutError:pass
check(connection.timeouts==[0.0625] and connection.connects==1,'connect shares the same remaining budget and cannot restart it')
clock=Clock(96);budget=RemainingBudget(100,clock);values=[]
for now in [96,98,99.5]:clock.now=now;values.append(budget.timeout())
check(values==[4,2,0.5] and budget.deadline==100,'successive bootstrap operations keep one absolute deadline')
# The14 prior parser/privacy/ordering/EOF obligations remain on the exact same
# FocusEvents class. Compare source directly; do not recount those tests.
prior=Path('/data/quod-m4-vr-ca84d4f8-20261029/private/metadata-inputs/case10-focus-checks02/focus_events.py')
def segment(p):
    text=p.read_text();node=next(n for n in ast.parse(text).body if isinstance(n,ast.ClassDef) and n.name=='FocusEvents');return ast.get_source_segment(text,node)
assert segment(prior)==segment(ev/'focus_events.py')
result={'passed':True,'checks':checks,'count':len(checks),'scope':'PURE fake clocks and I/O only; no actual commands/connections/windows/devices.',
 'prior14_parser_checks_repeated':False,'exact_parser_class_unchanged':True,
 'parser_class_sha256':hashlib.sha256(segment(prior).encode()).hexdigest(),'actual_listener_armed':False}
(ev/'deadline-checks-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
