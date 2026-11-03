#!/usr/bin/env python3
"""Build an unpatched, pinned official Monado runtime in the R2 private cache."""
import argparse,hashlib,json,os,re,subprocess
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('phase',choices=['configure','build','install']);p.add_argument('--label',required=True);a=p.parse_args()
evidence=Path(__file__).resolve().parent
runtime=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime')
commit='59be345db769a89c93d1bdf6ed8316fa6209d8ae'
source=runtime/'monado-current-source'/('monado-'+commit)
build=runtime/('monado-'+a.label+'-build');install=runtime/('monado-'+a.label+'-install')
temporary=runtime/('monado-'+a.label+'-temporary');temporary.mkdir(mode=0o700,exist_ok=True)
enabled={'STEAMVR_LIGHTHOUSE','VIVE','SIMULATED'}
options=sorted(set(re.findall(r'option(?:_with_deps)?\((XRT_BUILD_DRIVER_[A-Z0-9_]+)',(source/'CMakeLists.txt').read_text())))
command={
 'configure':['cmake','-S',str(source),'-B',str(build),'-G','Ninja','-DCMAKE_BUILD_TYPE=RelWithDebInfo',
  '-DCMAKE_INSTALL_PREFIX='+str(install),'-DGIT_DESC='+commit,'-DBUILD_TESTING=OFF',
  '-DXRT_OPENXR_INSTALL_ACTIVE_RUNTIME=OFF','-DXRT_FEATURE_SERVICE_SYSTEMD=OFF',
  '-DXRT_FEATURE_STEAMVR_PLUGIN=OFF','-DXRT_FEATURE_DEBUG_GUI=OFF','-DXRT_FEATURE_WINDOW_PEEK=OFF',
  '-DXRT_MODULE_MERCURY_HANDTRACKING=OFF','-DXRT_FEATURE_SLAM=OFF','-DXRT_MODULE_CONSTELLATION_TRACKING=OFF']+
  ['-D'+name+('=ON' if name.removeprefix('XRT_BUILD_DRIVER_') in enabled else '=OFF') for name in options],
 'build':['cmake','--build',str(build),'--parallel','8'],
 'install':['cmake','--install',str(build)]}[a.phase]
record={'phase':a.phase,'label':a.label,'commit':commit,'command':command,'source_changes':False,'global_install':False,'TMPDIR':str(temporary)}
record['source_inputs']={str(f.relative_to(source)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(source.rglob('*')) if f.is_file()}
receipt=evidence/'inputs'/('runtime-'+a.label+'-'+a.phase+'.json')
assert not receipt.exists(),receipt
receipt.write_text(json.dumps(record,indent=2)+'\n')
(evidence/'inputs'/('runtime-'+a.label+'-'+a.phase+'-driver.py')).write_bytes(Path(__file__).read_bytes())
child=subprocess.run(command,env=dict(os.environ,TMPDIR=str(temporary)));record['child_exit']=child.returncode
if a.phase=='install' and child.returncode==0:
 record['installed_outputs']={str(f.relative_to(install)):{'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'mode':oct(f.lstat().st_mode),'link':os.readlink(f) if f.is_symlink() else None} for f in sorted(install.rglob('*')) if f.is_file()}
receipt.write_text(json.dumps(record,indent=2)+'\n')
raise SystemExit(child.returncode)
