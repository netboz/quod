"""Read-only desktop/runtime preservation check after all owned cases have closed."""
import importlib.util,json,subprocess
from pathlib import Path
root=Path.cwd();ev=Path(__file__).resolve().parent
path=root/'doc/evidence/godot-m4-vr-20261029/vive_display.py'
spec=importlib.util.spec_from_file_location('retained_vive_display',path);display=importlib.util.module_from_spec(spec);spec.loader.exec_module(display)
before=json.loads((root/'doc/evidence/godot-m4-vive-charged-20261029/native-vive-product07/result.json').read_text())['display_rule']['after'];after=display.snapshot()
desktop=lambda s:sorted([m for m in s['monitors'] if m['name']!='HDMI-A-1'],key=lambda m:m['name'])
hdmi=[m for m in after['monitors'] if m['name']=='HDMI-A-1'];owned_alive=[]
for pid in [2078120,2220917]:
    if Path('/proc',str(pid)).exists():owned_alive.append(pid)
record={'desktop_unchanged_since_case07':desktop(before)==desktop(after),'config_unchanged_since_case07':before['config_sha256']==after['config_sha256'],'config_files_checked':len(after['config_sha256']),'HDMI-A-1_disabled':len(hdmi)==1 and hdmi[0]['disabled'] is True,'known_closed_owned_client_pids_remaining':owned_alive,'scope':'Read-only monitors/config check; no runtime/display/config mutation and no whole-host identity claim. All actual qualification child exits/EOF are checked separately.'}
target=ev/'inputs/final-ownership.json';assert not target.exists();target.write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
assert record['desktop_unchanged_since_case07'] and record['config_unchanged_since_case07'] and record['HDMI-A-1_disabled'] and not owned_alive
