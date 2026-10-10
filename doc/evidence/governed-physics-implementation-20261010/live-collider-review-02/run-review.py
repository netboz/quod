import datetime, hashlib, json, pathlib, subprocess
p=pathlib.Path('/home/yan/src/quod/doc/evidence/governed-physics-implementation-20261010/live-collider-review-02')
manifest=json.loads((p/'source-manifest.json').read_text())
def mismatch():
 return [x['file'] for x in manifest['files'] if hashlib.sha256((p/'tree'/x['file']).read_bytes()).hexdigest()!=x['sha256']]
if mismatch(): raise SystemExit('frozen input changed before invocation')
args=['/home/yan/.local/bin/claude','--print','--model','fable','--no-session-persistence','--permission-mode','dontAsk','--tools','Read,Grep,Glob','--allowedTools','Read,Grep,Glob','--disable-slash-commands','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--settings','{"disableAllHooks":true}','--output-format','json']
start=datetime.datetime.now(datetime.timezone.utc).isoformat()
(p/'invocation.json').write_text(json.dumps({'started':start,'args':args,'cwd':str(p),'scope':'corrected live collider implementation; not release or full-task acceptance'},indent=2)+'\n')
with (p/'stdout.json').open('wb') as out, (p/'stderr.log').open('wb') as err:
 result=subprocess.run(args,cwd=p,input=(p/'review-request.md').read_bytes(),stdout=out,stderr=err)
data={}
try: data=json.loads((p/'stdout.json').read_text())
except ValueError: pass
if isinstance(data.get('result'),str): (p/'fable-review.md').write_text(data['result']+'\n')
receipt={'started':start,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'child_exit':result.returncode,'is_error':data.get('is_error'),'models':list(data.get('modelUsage',{})),'frozen_count':len(manifest['files']),'changed_frozen_inputs':mismatch()}
(p/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
raise SystemExit(result.returncode)
