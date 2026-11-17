"""Only run after the matched unmodified template has been built and retained."""
import difflib,hashlib,json,shutil
from pathlib import Path
from environment import TASK
assert (TASK/'artifacts/engine/baseline01/receipt.json').is_file()
source=TASK/'builds/engine01/godot-4.7.2-stable'
changes={
 'modules/openxr/openxr_interface.cpp':('\t\t\t\tif (interaction_profile_array.has(ip)) {\n\t\t\t\t\tinteraction_profile_array.push_back(ip);','\t\t\t\tif (!interaction_profiles.has(ip)) {\n\t\t\t\t\tinteraction_profiles.push_back(ip);'),
 'modules/openxr/extensions/spatial_entities/openxr_spatial_marker_tracking.cpp':('void OpenXRSpatialMarkerTrackingCapability::on_session_destroyed() {\n','void OpenXRSpatialMarkerTrackingCapability::on_session_destroyed() {\n\tif (!spatial_marker_tracking_ext) {\n\t\treturn;\n\t}\n\n')
}
out=TASK/'artifacts/engine/patch01';out.mkdir(parents=True,exist_ok=False)
patch='';manifest={}
for name,(old,new) in changes.items():
    path=source/name;before=path.read_text();assert before.count(old)==1,name
    original=out/'original'/name;original.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,original)
    after=before.replace(old,new);path.write_text(after)
    changed=out/'patched'/name;changed.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,changed)
    patch+=''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
    manifest[name]={'before':hashlib.sha256(before.encode()).hexdigest(),'after':hashlib.sha256(after.encode()).hexdigest()}
(out/'godot-4.7.2-openxr-lifetimes.patch').write_text(patch)
(Path(__file__).resolve().parent/'godot-4.7.2-openxr-lifetimes.patch').write_text(patch)
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(patch);print(json.dumps(manifest))
