"""One read-only current lease snapshot; no lease request or display mutation."""
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
os.umask(0o077)
TASK=Path('/data/quod-m4-vr-ca84d4f8-20261029')
ev=Path(__file__).resolve().parent
private=TASK/'private/retest-connector-observation01'
private.mkdir(mode=0o700,exist_ok=False)
binary=TASK/'builds/display-inventory02/display-inventory'
source=ev.parent/'godot-m4-vr-20261029/display_inventory.c'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
bindings={}
for p in [Path(__file__).resolve(),binary,source]:
    saved=private/p.name
    shutil.copy2(p,saved)
    bindings[str(p)]={'sha256':digest(p),'bytes':p.stat().st_size,
      'mode':oct(p.stat().st_mode&0o7777),'saved':str(saved)}
record={'diagnostic':'current read-only connector offer snapshot after failed09 retirement',
  'preexecution_inputs':bindings,'runtime_started':False,'display_mutated':False,
  'lease_requested':False,'commands':[]}
commands=[['hyprctl','-j','monitors','all'],
 [str(binary),'/dev/dri/card1'],
 ['ps','-eo','pid=,comm=']]
for index,command in enumerate(commands):
    result=subprocess.run(command,capture_output=True,timeout=5)
    for stream,data in [('stdout',result.stdout),('stderr',result.stderr)]:
        (private/f'{index}-{stream}.raw').write_bytes(data)
    row={'command':command,'true_child_exit':result.returncode,
      'stdout_sha256':hashlib.sha256(result.stdout).hexdigest(),
      'stderr_sha256':hashlib.sha256(result.stderr).hexdigest()}
    if index==0:
        fields=['name','disabled','width','height','refreshRate','x','y','scale','transform','dpmsStatus']
        row['monitors']=[{k:m.get(k) for k in fields} for m in json.loads(result.stdout)]
    elif index==1:
        row['stdout']=result.stdout.decode();row['stderr']=result.stderr.decode()
    else:
        row['runtime_processes']=[line for line in result.stdout.decode().splitlines()
          if any(x in line.lower() for x in ['monado','godot','quod.x86','steamvr','vrserver','vrcompositor'])]
    record['commands'].append(row)
    if result.returncode:raise RuntimeError(f'Read-only observation child {index} failed: {result.returncode}')
record['sysfs']={name:(Path('/sys/class/drm/card1-HDMI-A-1')/name).read_text().strip()
  for name in ['status','enabled','dpms']}
record['passed']=True
(ev/'inputs/current-connector-observation01.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record))
