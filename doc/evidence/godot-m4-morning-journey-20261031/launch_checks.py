"""Finite offline checks of the prepared invocation; never import live code."""
import ast,json,stat
from pathlib import Path
from cue_hashes import TASK,raw
root=Path.cwd();ev=Path(__file__).resolve().parent
directory=TASK/'private/morning-launch-inputs02';p=directory/'prepared.json';v=json.loads(p.read_text());checks=[]
def check(value,name):
    if not value:raise AssertionError(name)
    checks.append(name);print('PASS '+name)
check(v['passed'] and v['offline_only'] and v['tty_required'],'prepared invocation is offline with explicit PTY ownership required')
check(stat.S_IMODE(directory.stat().st_mode)==0o700 and stat.S_IMODE(p.stat().st_mode)==0o600,'prepared inputs and invocation remain task-private')
check(raw(v['manifest'])==v['manifest_sha256'],'invocation binds the exact selected diagnostic manifest')
m=json.loads(Path(v['manifest']).read_text())
check(len(m['live_source_inputs'])==93 and len(m['supplied_inputs'])==97 and len(m['export_outputs'])==196 and not m['distributable'],'current product and removable diagnostic input/output sets are explicit')
check(v['startup_seconds']==30 and v['single_inventory_seconds']==5 and v['manual_seconds']==1800 and v['close_seconds']==60 and v['wrapper_seconds']==2100,'all existing absolute bounds are preserved')
text=Path(v['prepare_live']).read_text();tree=ast.parse(text);launch=(ev/'launch.py').read_text()
check(raw(v['prepare_live'])==v['prepare_live_sha256'] and raw(directory/'case_hashes.py')==v['digest_owner_sha256'],'generated preflight and digest binding are exact before execution')
check("label=sys.argv[1]" in text and "(label+'-preparation')" in text and "native-vive-product21';private=" not in text,'future case label and private target are supplied fresh')
check("TASK/'cache'/(label+'-preparation-used-digests.json')" in text and "TASK/'cache/mapped21-preparation-used-digests.json'" not in text,'future receipt cache cannot overwrite the closed case21 cache')
check(str(Path(v['manifest'])) in text and v['manifest_sha256'] in text and 'client-workspace-cue01-manifest.json' not in text,'preflight selects the new current payload rather than a historical cue')
check("wait_line" not in text and not any(isinstance(n,(ast.While,ast.AsyncFor)) for n in ast.walk(tree)),'prepared current-provider preflight contains no readiness polling or retries')
check("display.enable()" in text and "finally:" in text and "display.restore()" in text,'future provider snapshot retains the same approved HDMI exception and restoration owner')
check("sys.stdin.isatty()" in launch and "os.execv" in launch and "--require-wands" in launch,'single supported live path keeps interactive stdin and both-device admission')
check('subprocess.run([sys.executable' in launch and "if status:raise SystemExit(status)" in launch,'a fresh preflight failure stops the launch without a fallback')
check(len(v['server_bindings'])==3 and len(v['runtime_bindings'])==5 and raw(v['accepted_closure']['path'])==v['accepted_closure']['sha256'],'retained server/runtime and accepted closure references are explicit')
check(all('no runtime bytes reread' in r['custody'] for r in v['runtime_bindings'].values()),'runtime content hashes are accepted references, not fabricated fresh cache hits')
record={'passed':True,'checks':checks,'prepared_path':str(p),'prepared_sha256':raw(p),'live_code_imported':False,'live_query_or_launch':False}
(ev/'launch-checks.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({'passed':True,'checks':len(checks)}))
