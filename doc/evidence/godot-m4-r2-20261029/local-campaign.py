#!/usr/bin/env python3
"""Retain the existing real local-UI driver plus bounded shutdown observation."""
import argparse,hashlib,json,runpy,shutil,subprocess,sys
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--client',required=True);p.add_argument('--phase',choices=['backup-cancel','menu','crypto'],required=True);a=p.parse_args()
root=Path.cwd();ev=Path(__file__).resolve().parent
manifest=json.loads((ev/'inputs'/('client-'+a.client+'-manifest.json')).read_text());assert manifest['passed'] and manifest['distributable']
export=Path(manifest['export_executable']);assert hashlib.sha256(export.read_bytes()).hexdigest()==manifest['export_outputs']['client/godot/dist/quod.x86_64']['sha256']
drivers=ev/'inputs'/(a.label+'-drivers');drivers.mkdir(exist_ok=False);sources={}
instrument=runpy.run_path(str(ev/'observe-drivers.py'))['instrument']
for path in [Path(__file__),ev/'observe-drivers.py',ev/'shutdown_observation.py',root/'client/godot-tests/local.py',root/'client/godot-tests/desktop_input.py']:
    target=drivers/path.name;shutil.copy2(path,target)
    adaptation=instrument(target) if path.name=='local.py' else None
    sources[path.name]={'source_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'supplied_sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'adaptation':adaptation}
command=[sys.executable,str(drivers/'local.py'),'--export',str(export),'--phase',a.phase,'--desktop','--evidence',str(ev/a.label),'--private',str(Path('/home/yan/.cache/quod-m4-r2-artifacts/private')/a.label)]
record={'command':command,'driver_inputs':sources,'watchdog_seconds':60,'phase':a.phase,'physical_headset_acceptance':False}
receipt=ev/'inputs'/(a.label+'-invocation.json');receipt.write_text(json.dumps(record,indent=2)+'\n')
child=subprocess.run(command);record['child_exit']=child.returncode;receipt.write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({'child_exit':child.returncode,'phase':a.phase}))
sys.exit(child.returncode)
