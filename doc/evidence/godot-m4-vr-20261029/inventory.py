#!/usr/bin/env python3
"""Read-only native display/runtime/tool inventory; private raw JSON on /data."""
import hashlib,json,os,shutil,subprocess
from pathlib import Path
from environment import TASK,environment
os.umask(0o077);ev=Path(__file__).resolve().parent
private=TASK/'private/inventory01';private.mkdir(mode=0o700,exist_ok=False)
commands=[['hyprctl','version'],['hyprctl','-j','monitors','all'],['wayland-info'],['drm_info','-j'],
    ['vulkaninfo','--summary'],['nvidia-smi','--query-gpu=name,driver_version,pci.bus_id,display_active,display_mode','--format=csv,noheader'],
    ['scons','--version'],['gcc','--version'],['clang','--version'],['dotnet','--info'],
    ['pacman','-Q','hyprland','aquamarine','nvidia-utils','openxr','wayland','wayland-protocols','scons']]
receipts=[];native={};env=environment()
for i,command in enumerate(commands):
    if not shutil.which(command[0]):receipts.append({'command':command,'unavailable':True});continue
    try:child=subprocess.run(command,env=env,capture_output=True,timeout=20)
    except subprocess.TimeoutExpired:receipts.append({'command':command,'timeout':True});continue
    for name,data in [('stdout',child.stdout),('stderr',child.stderr)]:
        (private/(str(i)+'-'+name+'.raw')).write_bytes(data)
    receipts.append({'command':command,'child_exit':child.returncode,'stdout_sha256':hashlib.sha256(child.stdout).hexdigest(),'stderr_sha256':hashlib.sha256(child.stderr).hexdigest(),'raw_prefix':str(private/str(i))})
    native[command[0]+' '+(command[1] if len(command)>1 else '')]=child.stdout.decode(errors='replace')
connectors=[]
for status in sorted(Path('/sys/class/drm').glob('card*-*/status')):
    path=status.parent;row={'connector':path.name,'status':status.read_text().strip()}
    for name in ['enabled','dpms','connector_id','modes']:
        if (path/name).exists():row[name]=(path/name).read_text().splitlines()
    if (path/'edid').exists():
        data=(path/'edid').read_bytes()
        if data:
            (private/(path.name+'-edid.bin')).write_bytes(data);row['edid_sha256']=hashlib.sha256(data).hexdigest()
            row['edid_manufacturer_hex']=data[8:10].hex();row['edid_product_hex']=data[10:12].hex()
    connectors.append(row)
monitors=[]
try:
    for row in json.loads(native.get('hyprctl -j','[]')):
        monitors.append({key:row.get(key) for key in ['name','description','make','model','width','height','disabled','dpmsStatus','drmFormat','nonDesktop']})
except ValueError:pass
processes=[]
for path in Path('/proc').iterdir():
    if not path.name.isdigit():continue
    try:name=(path/'comm').read_text().strip()
    except (FileNotFoundError,PermissionError,ProcessLookupError):continue
    if name in ['Hyprland','Xwayland','Xorg','monado-service','vrserver','vrcompositor','vrmonitor','envision']:
        processes.append({'pid':int(path.name),'comm':name})
record={'commands':receipts,'connectors':connectors,'monitors':monitors,'relevant_processes_no_arguments':processes,
    'environment':{key:os.environ.get(key) for key in ['DISPLAY','WAYLAND_DISPLAY','XDG_RUNTIME_DIR','XDG_SESSION_TYPE','XR_RUNTIME_JSON']},
    'task_free_bytes':shutil.disk_usage(TASK).free,'task_device':TASK.stat().st_dev,
    'tools':{name:shutil.which(name) for name in ['scons','gcc','clang','wayland-info','wayland-scanner','drm_info','pkg-config','curl']},
    'cpu_threads':os.cpu_count(),'modified_global_state':False}
(ev/'inputs/inventory01.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'connectors':connectors,'monitors':monitors,'processes':processes,'tools':record['tools'],'cpu_threads':record['cpu_threads'],'free_bytes':record['task_free_bytes']}))
