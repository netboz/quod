"""The explicitly approved temporary HDMI-only exception; never edits config."""
import hashlib,json,subprocess
from pathlib import Path
PUBLIC=Path(__file__).resolve().parent
ENABLE=['hyprctl','eval','hl.monitor({output="HDMI-A-1", disabled=false})']
RESTORE=['hyprctl','eval','hl.monitor({output="HDMI-A-1", disabled=true})']
def snapshot():
    data=json.loads(subprocess.check_output(['hyprctl','-j','monitors','all']))
    fields=['name','width','height','refreshRate','x','y','scale','transform','disabled','dpmsStatus']
    monitors=[{k:m.get(k) for k in fields} for m in data]
    files={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in Path('/home/yan/.config/hypr').rglob('*.lua') if p.is_file()}
    return {'monitors':monitors,'config_sha256':files}
class ViveDisplay:
    def __init__(self,private):self.private=private;self.changed=False;self.record={'authorization':str(PUBLIC/'inputs/display-exception-authorization.json'),'before':snapshot()}
    def enable(self):
        self.changed=True # Restore even if the command is interrupted after delivery.
        result=subprocess.run(ENABLE,capture_output=True,timeout=10)
        self.record['enable']={'command':ENABLE,'child_exit':result.returncode,'stdout':result.stdout.decode(),'stderr':result.stderr.decode()}
        if result.returncode or result.stdout.strip()!=b'ok':raise RuntimeError('Vive-only runtime rule failed')
    def restore(self):
        if self.changed:
            result=subprocess.run(RESTORE,capture_output=True,timeout=10)
            self.record['restore']={'command':RESTORE,'child_exit':result.returncode,'stdout':result.stdout.decode(),'stderr':result.stderr.decode()}
        self.record['after']=snapshot()
        desktop=lambda s:sorted([m for m in s['monitors'] if m['name']!='HDMI-A-1'],key=lambda m:m['name'])
        self.record['desktop_unchanged']=desktop(self.record['before'])==desktop(self.record['after'])
        self.record['config_unchanged']=self.record['before']['config_sha256']==self.record['after']['config_sha256']
        (self.private/'display-rule.json').write_text(json.dumps(self.record,indent=2)+'\n')
        if not self.record['desktop_unchanged'] or not self.record['config_unchanged']:raise RuntimeError('Display/config preservation check failed')
