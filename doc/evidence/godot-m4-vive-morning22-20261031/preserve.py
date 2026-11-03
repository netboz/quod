"""Preserve the failed invocation and existing preflight bytes; execute nothing live."""
import hashlib,json,os,shutil,stat
from pathlib import Path
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
stage=task/'private/native-vive-product22-preparation'
destination=task/'private/case22-failure01';destination.mkdir(mode=0o700,exist_ok=False)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
receipt=json.loads((ev/'execution-receipt.json').read_text())
assert receipt['tty'] and receipt['completion_tool_response']['exit_code']==2
preflight=json.loads((stage/'preparation-private.json').read_text())
expected={'passed':True,'case_label':'native-vive-product22','runtime_started':False,'lease_requested':False,
          'provider_true_child_exit':0,'provider_complete':True,'hdmi_offer':True,'connector828_offered':True,
          'hdmi_restored_disabled':True,'other_displays_unchanged':True,'config_unchanged':True}
assert all(preflight[k]==v for k,v in expected.items())
launch=root/'doc/evidence/godot-m4-morning-journey-20261031/launch.py'
assert digest(launch)=='c92745e767e9eef8594391b747c205d91a47e46292bf0d32792836ccce040d56'
prepared=task/'private/morning-launch-inputs02/prepared.json'
assert digest(prepared)=='bcdd55be554101e1d28652f7a3880444cf55331ebeaec26a7fb5e8549fcd4298'
wrapper=stage/'unchanged-owners/godot-m4-vive-physical-20261029/manual_run.py'
assert digest(wrapper)=='2620ffe864b19135f1557e19280cec34fe18c19ac51f940379573da56b0e9639'
assert "'--timeout','2100'" in launch.read_text() and "p.add_argument('label')" in wrapper.read_text()
assert 'child.wait(timeout=2100)' in wrapper.read_text() and "add_argument('--timeout'" not in wrapper.read_text()
assert not (task/'private/runs/native-vive-product22-run').exists()
sources=[(p,'preflight/'+str(p.relative_to(stage))) for p in stage.rglob('*') if p.is_file()]
sources += [(launch,'invocation/launch.py'),(prepared,'invocation/prepared.json'),
            (prepared.parent/'prepare_live.py','invocation/prepare_live.py'),
            (prepared.parent/'case_hashes.py','invocation/case_hashes.py'),
            (ev/'execution-receipt.json','invocation/execution-receipt.json'),(Path(__file__),'invocation/preserve.py')]
records=[]
for source,relative in sources:
    assert not source.is_symlink() and stat.S_ISREG(source.stat().st_mode)
    target=destination/relative;target.parent.mkdir(mode=0o700,parents=True,exist_ok=True);shutil.copy2(source,target)
    h=digest(source);assert digest(target)==h and source.stat().st_mode==target.stat().st_mode
    records.append({'source':str(source),'copy':str(target),'sha256':h,'bytes':source.stat().st_size,'full_mode':source.stat().st_mode})
result={'case':'native-vive-product22','passed':False,'actual_launch_exit':2,'preservation_passed':True,
        'cause':'launch.py supplied --timeout 2100 to the unchanged wrapper, whose parser accepts only label and command; its existing watchdog is already 2100 seconds',
        'preflight':expected,'fixture_runtime_application_and_human_step':'UNRUN; argparse stopped before wrapper body/child launch',
        'streams':'Actual combined PTY transcript retained; separate child streams/readers never created',
        'new_invocation_or_source_correction':'UNRUN','accepted_parent_snapshot':'bf4b7235f3c9b923bbd7780a7a956540a5c18bedeb3e41870ad406eac82094f5',
        'files':records,'export_bytes_rehashed':0,'old_api_bytes_read':0}
(ev/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'preservation_passed':True,'actual_launch_exit':2,'files':len(records),'runtime_started':False,'hdmi_restored_disabled':True}))
