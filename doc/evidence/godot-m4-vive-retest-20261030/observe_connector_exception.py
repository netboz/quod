"""One protocol snapshot inside the approved temporary HDMI-only exception."""
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
os.umask(0o077)
ev=Path(__file__).resolve().parent
sys.path.insert(0,str(ev.parent/'godot-m4-vr-20261029'))
from vive_display import ViveDisplay
TASK=Path('/data/quod-m4-vr-ca84d4f8-20261029')
private=TASK/'private/retest-connector-exception01'
private.mkdir(mode=0o700,exist_ok=False)
binary=TASK/'builds/display-inventory02/display-inventory'
record={'runtime_started':False,'lease_requested':False,'passed':False,'inputs':{}}
for p in [Path(__file__).resolve(),binary,ev.parent/'godot-m4-vr-20261029/vive_display.py',
          ev.parent/'godot-m4-vr-20261029/display_inventory.c']:
    shutil.copy2(p,private/p.name)
    record['inputs'][str(p)]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),
      'mode':oct(p.stat().st_mode&0o7777),'bytes':p.stat().st_size}
display=ViveDisplay(private)
try:
    owners=subprocess.run(['ps','-eo','pid=,comm='],capture_output=True,timeout=5)
    assert owners.returncode==0
    record['runtime_processes_before']=[line for line in owners.stdout.decode().splitlines()
      if any(x in line.lower() for x in ['monado','godot','quod.x86','steamvr','vrserver','vrcompositor'])]
    assert not record['runtime_processes_before'], 'Another runtime/application owns the test environment'
    display.enable()
    command=[str(binary),'/dev/dri/card1']
    result=subprocess.run(command,capture_output=True,timeout=5)
    for stream,data in [('stdout',result.stdout),('stderr',result.stderr)]:
        (private/f'{stream}.raw').write_bytes(data)
    record.update(command=command,true_child_exit=result.returncode,
      stdout=result.stdout.decode(),stderr=result.stderr.decode(),
      stdout_sha256=hashlib.sha256(result.stdout).hexdigest(),
      stderr_sha256=hashlib.sha256(result.stderr).hexdigest())
    record['passed']=result.returncode==0 and b'DISPLAY_INVENTORY_COMPLETE status=0' in result.stdout
finally:
    display.restore();record['display_rule']=display.record
    (ev/'inputs/current-connector-exception01.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps({k:v for k,v in record.items() if k!='display_rule'}))
if not record['passed']:raise SystemExit(1)
