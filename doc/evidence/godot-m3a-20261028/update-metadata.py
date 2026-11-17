#!/usr/bin/env python3
"""Publish only authorized metadata after clean qualification; never bodies."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

evidence=Path(__file__).resolve().parent
root=evidence.parents[2]
campaign=sys.argv[1]
gates=json.loads((evidence/(campaign+'-result.json')).read_text())
assert gates['all_true_exits_zero'] and gates['source_unchanged'] and not gates['unrun']
inputs=json.loads((evidence/'inputs'/(campaign+'-source-manifest.json')).read_text())
for name,expected in inputs['files'].items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==expected,name
output=evidence/'tracker-metadata-outcomes.json'
assert not output.exists()
env=dict(os.environ)
env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None)
base=['node','/home/yan/src/quod/nimbalyst-local/tools/tracker-call.mjs',
      '/home/yan/src/quod','8d55a3f3-e558-46e2-afbb-2e028558f371']
result=dict(campaign=campaign,worker_session=base[-1],
    timestamp_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    body_write_attempted=False,shared_body_publication=False,updates=[])
def objects(value):
    if isinstance(value,dict):
        yield value
        for child in value.values(): yield from objects(child)
    elif isinstance(value,list):
        for child in value: yield from objects(child)
    elif isinstance(value,str):
        try: yield from objects(json.loads(value))
        except ValueError: pass

def item(row,key):
    canonical='tsk_01M5YNM08XYDABJXFR89HJV6YK' if key=='QUO-64' else key
    candidates=[d for d in objects(row['stdout']) if d.get('id')==canonical and 'customFields' in d]
    assert len(candidates)==1,(key,len(candidates))
    return candidates[0]

def call(name,args):
    assert not any(k in args for k in ['description','published','body','content'])
    child=subprocess.run(base+[name,json.dumps(args)],env=env,capture_output=True,text=True)
    row=dict(tool=name,args=args,child_exit=child.returncode,stdout=child.stdout,stderr=child.stderr)
    if child.returncode: raise RuntimeError(row)
    outer=json.loads(child.stdout)
    assert not any(d.get('isError',False) for d in objects(outer)),row
    return row
try:
    for key,progress,meaning in [
        ('QUO-64',13,'Only the M3a server-subset check, one of eight full-M3 checks; M3b remains open'),
        ('tsk_01M5PY8TEXKG858WBZJ1RHC6EW',25,
         'Same-agent server entry only; broader D5/D6/D7 and other Stage2 checks remain open')]:
        radar=call('work_radar',dict(issueKey=key))
        before=call('tracker_get',dict(id=key))
        previous=item(before,key)
        assert previous['customFields']['progress'] in (0,progress), 'Concurrent progress changed; preserve it'
        assert previous['status'] in ('in-development','in-review'), 'Concurrent status changed; preserve it'
        updated=call('tracker_update',dict(id=key,status='in-review',progress=progress))
        readback=call('tracker_get',dict(id=key))
        current=item(readback,key)
        assert current['status']=='in-review' and current['customFields']['progress']==progress,current
        result['updates'].append(dict(key=key,credited_scope=meaning,radar=radar,before=before,
                                      update=updated,readback=readback))
    result['parent_readback']=call('tracker_get',dict(id='QUO-60'))
    result['parent_update_attempted']=False
    parent=item(result['parent_readback'],'plan_1793104481306_y8rhic')
    result['parent_progress']=parent['customFields']['progress']
    assert result['parent_progress']==50,'Parent progress changed independently; preserve and report it'
    result['attribution_limit']='Local reads and linkedCount:0 are not shared publication or visible attribution proof'
    result['requests_accepted']=True
finally:
    output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(dict(path=str(output),requests_accepted=result.get('requests_accepted',False),
                     body_write_attempted=False)))
