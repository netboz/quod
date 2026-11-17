"""Finite pure publication cases, plus retained real-wrapper fixture outputs."""
import ast,hashlib,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
root=Path.cwd();ev=Path(__file__).resolve().parent
sys.path.insert(0,str(ev.parent/'godot-m4-vive-physical-20261029'))
from publication import redact_devices
checks=[]
def check(condition,name):
    if not condition:raise AssertionError(name)
    checks.append(name)
marker=b'<device-serial-redacted>'
check(redact_devices(b'LHR-TEST')==marker,'LHR identifier is redacted')
check(redact_devices(b'LHB-TEST')==marker,'LHB identifier is redacted')
check(redact_devices(b'lhr-test lhb-test')==marker+b' '+marker,'existing case-insensitive stream behavior is shared')
plain=b'LHX-other LHRAnear LHR_nearby fields=unchanged\n'
check(redact_devices(plain)==plain,'unrelated bytes remain unchanged')
raw=b'prefix LHR-TESTLEFT LHB-TESTBASE suffix\n';original=bytes(raw)
check(redact_devices(raw)==b'prefix '+marker+b' '+marker+b' suffix\n' and raw==original,'raw immutable input remains unchanged')
expected={'stdout':b'LHR-TESTLEFT LHB-TESTBASE unrelated=keep\n','stderr':b'lhr-testlower lhb-testbase unrelated=keep\n'}
task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
for label,folder,kind in [('focus12-publication-manual01',ev.parent/'godot-m4-vive-physical-20261029/logs','manual'),('focus12-publication-metadata01',ev/'logs','metadata')]:
    record=json.loads((folder/(label+'.json')).read_text());check(record['child_exit']==0 and not record.get('timed_out'),'actual '+kind+' publisher fixture child0')
    for stream,data in expected.items():
        p=task/'private/runs'/label/(stream+'.raw');before=hashlib.sha256(p.read_bytes()).hexdigest()
        check(p.read_bytes()==data and p.stat().st_mode&0o7777==0o600,kind+' retains original private '+stream)
        published=(folder/(label+'-'+stream+'.log')).read_bytes()
        check(published==redact_devices(data),kind+' publishes both observed prefixes '+stream)
        check(hashlib.sha256(p.read_bytes()).hexdigest()==before,kind+' publication leaves raw '+stream+' unchanged')
sources={'physical09.py':ev.parent/'godot-m4-vive-retest-20261030/physical09.py','manual_run.py':ev.parent/'godot-m4-vive-physical-20261029/manual_run.py','metadata_run.py':ev/'run.py'}
for name,p in sources.items():
    tree=ast.parse(p.read_text());calls=[n for n in ast.walk(tree) if isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and n.func.id=='redact_devices']
    check(len(calls)==({'physical09.py':2,'manual_run.py':2,'metadata_run.py':1}[name]),name+' existing publishing callsites use the one owner')
result={'passed':True,'count':len(checks),'checks':checks,'scope':'Finite non-sensitive byte fixtures and actual diagnostic publication wrappers only; no product/runtime/device or domain action.','old_parser_budget_and_stdin_probes_repeated':False}
(ev/'publication-checks.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
