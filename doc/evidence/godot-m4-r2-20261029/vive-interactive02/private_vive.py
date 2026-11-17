"""Qualification-only namespace for Valve's installed lighthouse driver.

The driver writes beside Steam's lighthouse calibration. Bind a private copy
there inside an owned read-only mount namespace; never redirect HOME or expose
the real configuration as writable.
"""
import hashlib,json,os,shutil,subprocess
from pathlib import Path

STEAM=Path('/home/yan/.local/share/Steam')
CONFIG=STEAM/'config'
STEAMVR=STEAM/'steamapps/common/SteamVR'

def fingerprints(root):
    return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file()}

def calibration_fingerprints():
    result={'lighthouse/'+name:digest for name,digest in fingerprints(CONFIG/'lighthouse').items()}
    for name in ['steamvr.vrsettings','chaperone_info.vrchap']:
        if (CONFIG/name).is_file():result[name]=hashlib.sha256((CONFIG/name).read_bytes()).hexdigest()
    return result

def prepare(private):
    before=calibration_fingerprints()
    target=private/'steam-config';target.mkdir(mode=0o700)
    shutil.copytree(CONFIG/'lighthouse',target/'lighthouse',symlinks=True)
    for name in ['steamvr.vrsettings','chaperone_info.vrchap']:
        if (CONFIG/name).exists():shutil.copy2(CONFIG/name,target/name)
    (private/'temporary').mkdir(mode=0o700)
    namespace=['bwrap','--die-with-parent','--new-session','--ro-bind','/','/',
               '--dev-bind','/dev','/dev','--bind',str(private),str(private),
               '--bind',str(target),str(CONFIG),'--chdir',str(private),'--']
    env={'STEAMVR_LH_ENABLE':'1','STEAMVR_PATH':str(STEAMVR),'LH_STANDBY_ON_EXIT':'0',
         'TMPDIR':str(private/'temporary')}
    return namespace,env,before

def unchanged(before):
    return calibration_fingerprints()==before

def active_runtime_processes():
    # comm contains executable names only, never private launch arguments.
    found=[]
    for p in Path('/proc').iterdir():
        if not p.name.isdigit():continue
        try:name=(p/'comm').read_text().strip()
        except (FileNotFoundError,PermissionError,ProcessLookupError):continue
        if name in {'monado-service','vrserver','vrcompositor','vrmonitor','envision'}:
            found.append({'pid':int(p.name),'comm':name})
    return found
