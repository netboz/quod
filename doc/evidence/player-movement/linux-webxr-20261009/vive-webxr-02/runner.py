from pathlib import Path
import subprocess, json, hashlib, os, sys

root = Path('/home/yan/src/quod')
e = Path(sys.argv[1]).resolve()
e.mkdir(exist_ok=False)
result = {}
def monitors():
    return json.loads(subprocess.run(['hyprctl','monitors','all','-j'], capture_output=True, text=True, check=True).stdout)
before = monitors()
(e/'monitors-before.json').write_text(json.dumps(before,indent=2)+'\n')
files = ['client/test/linux-webxr-run.py','client/test/linux-webxr-preflight.py','client/test/linux-webxr.fixture.html']
(e/'source.json').write_text(json.dumps({f:hashlib.sha256((root/f).read_bytes()).hexdigest() for f in files},indent=2)+'\n')
(e/'runner.py').write_bytes(Path(__file__).read_bytes())
try:
    r = subprocess.run(['hyprctl','eval','hl.monitor({output="desc:HTC Corportation HTC-VIVE", disabled=false})'],capture_output=True,text=True)
    (e/'override.log').write_text(r.stdout+r.stderr)
    result['override_exit'] = r.returncode
    if r.returncode: raise RuntimeError('headset override rejected')
    env = os.environ.copy()
    env['STEAMVR_PATH'] = '/home/yan/.local/share/Steam/steamapps/common/SteamVR'
    result['steamvr_path'] = env['STEAMVR_PATH']
    with (e/'runner.log').open('x') as out:
        r = subprocess.run(['python3',str(root/'client/test/linux-webxr-run.py'),
                            '--device','vive','--browser',str(root/'client/_build/webxr-linux/chromium/src/out/QuodWebXR/chrome'),
                            '--evidence',str(e/'preflight')],env=env,stdout=out,stderr=subprocess.STDOUT)
    result['preflight_exit'] = r.returncode
except Exception as error: result['error'] = str(error)
finally:
    r = subprocess.run(['hyprctl','eval','hl.monitor({output="desc:HTC Corportation HTC-VIVE", disabled=true})'],capture_output=True,text=True)
    result['restore_exit'] = r.returncode
    (e/'restore.log').write_text(r.stdout+r.stderr)
    after = monitors()
    (e/'monitors-after.json').write_text(json.dumps(after,indent=2)+'\n')
    fields = ['name','width','height','x','y','refreshRate','scale','disabled']
    def summarize(ms):
        return sorted([{k:m[k] for k in fields} for m in ms if m['name']!='HDMI-A-1'],key=lambda m:m['name'])
    result['desktop_monitor_geometry_preserved'] = summarize(before)==summarize(after)
(e/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
for name in ['result.json','browser.log']:
    p = e/'preflight'/name
    if p.exists(): print(p.read_text()[-5500:])
raise SystemExit(0 if result.get('preflight_exit')==0 and result['restore_exit']==0 and result['desktop_monitor_geometry_preserved'] else 1)
