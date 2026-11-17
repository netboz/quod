"""Finite pure protocol/privacy/deadline cases; never opens a real connection."""
import json,sys
from pathlib import Path
sys.dont_write_bytecode=True
from focus_events import FocusEvents
ev=Path(__file__).resolve().parent
fixtures=json.loads((ev/'focus-fixtures.json').read_text());checks=[]
def check(ok,name):
    if not ok:raise AssertionError(name)
    checks.append(name);print('PASS '+name)
def fresh(deadline=100):
    rows=[];return FocusEvents('0xabc',deadline,rows.append),rows
parser,rows=fresh()
for index,part in enumerate(fixtures['split']):parser.feed(part.encode(),10+index,'example')
check([r['owned'] for r in rows]==[True,False,True],'split messages preserve complete ordered owned/not-owned transitions')
check(parser.events==4 and len(rows)==3,'unchanged focus events cause no duplicate transition')
parser,rows=fresh();parser.feed(fixtures['unrelated'].encode(),10,'example')
serialized=json.dumps(rows)
check(len(rows)==1 and rows[0]['owned'] is False,'unrelated owner focus is retained only as a boolean')
check(all(s not in serialized for s in fixtures['forbidden']),'unrelated titles identifiers and event payloads are absent from retained output')
parser,rows=fresh();parser.feed(b'activewindowv2>>def\n',10,'example');parser.snapshot(True,11,'example');parser.feed(b'activewindowv2>>def\n',12,'example')
check([r['kind'] for r in rows]==['transition','snapshot'] and parser.last is False,'snapshot cannot reset or reorder already observed event state')
check(rows[1]['ordered_event_barrier'] is False,'snapshot does not pretend to be a socket2 acknowledgement or event barrier')
parser,rows=fresh();parser.snapshot(True,99,'example');parser.feed(b'activewindowv2>>abc\n',100,'example');parser.feed(b'activewindowv2>>def\n',101,'example')
check([r['kind'] for r in rows]==['snapshot','absolute_deadline'] and parser.events==0,'absolute expiry refuses late events and is not reset by a snapshot')
parser,rows=fresh();parser.feed(b'activewindowv2>>abc',10,'example');parser.eof(11,'example')
check(rows==[dict(kind='remote_eof',monotonic=11,utc='example',incomplete_line=True)],'EOF reports an incomplete frame without retaining its payload')
parser,rows=fresh();parser.feed(b'activewindowv2>>\n',10,'example');parser.eof(11,'example')
check(rows[0]['owned'] is False and rows[1]['incomplete_line'] is False,'empty focus address and clean remote EOF are explicit')
parser,rows=fresh();parser.feed(b'activewindowv2>>NOT_AN_ADDRESS\n',10,'example')
check(parser.closed and rows[0]['error']=='malformed_focus_address' and 'NOT_AN_ADDRESS' not in json.dumps(rows),'malformed focus payload refuses without leaking input')
parser,rows=fresh();parser.feed(b'x'*65537,10,'example')
check(parser.closed and rows[0]['error']=='unterminated_protocol_line','unterminated framing is bounded')
parser,rows=fresh();parser.error('OSError',10,'example')
check(parser.closed and rows[0]['error']=='OSError','listener error is an explicit terminal observation')
parser,rows=fresh();parser.feed(b'activewindowv2>>abc\n',10,'example');parser.finish(11,'example')
check(rows[-1]['kind']=='local_subscription_close' and not rows[-1]['incomplete_line'],'normal local close is distinct from observed remote EOF')
parser,rows=fresh();parser.feed(b'activewindowv2>>ab',10,'example');parser.finish(11,'example')
check(rows[-1]['incomplete_line'] and parser.events==0,'local close preserves an incomplete-interval limitation')
result={'passed':True,'checks':checks,'count':len(checks),'scope':'PURE offline fragments only; no real socket/window/device/pose/button/domain action.',
 'actual_listener_armed':False,'case10_extension':'UNRUN: case10 retired before instruction81 arrived.'}
(ev/'focus-checks-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
