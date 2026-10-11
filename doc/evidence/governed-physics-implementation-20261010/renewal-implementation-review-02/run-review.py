import pathlib,subprocess,json,hashlib,datetime
b=pathlib.Path(__file__).resolve().parent
packet=b/'review-request.txt'; metadata=json.loads((b/'payload.json').read_text()); digest=metadata['sha256']
assert hashlib.sha256(packet.read_bytes()).hexdigest()==digest
args=['/home/yan/.local/bin/claude','--print','--model','fable','--no-session-persistence','--permission-mode','dontAsk','--tools','','--disable-slash-commands','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--settings','{"disableAllHooks":true}','--output-format','json']
start=datetime.datetime.now(datetime.timezone.utc).isoformat()
(b/'invocation.json').write_text(json.dumps({'started':start,'args':args,'payload_sha256':digest,'scope':metadata['scope']},indent=2)+'\n')
with (b/'stdout.json').open('xb') as out,(b/'stderr.log').open('xb') as err:
 q=subprocess.run(args,cwd=b,input=packet.read_bytes(),stdout=out,stderr=err)
d=json.loads((b/'stdout.json').read_text())
if isinstance(d.get('result'),str):(b/'fable-review.md').write_text(d['result']+'\n')
receipt={'started':start,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'child_exit':q.returncode,'is_error':d.get('is_error'),'models':list(d.get('modelUsage',{})),'payload_unchanged':hashlib.sha256(packet.read_bytes()).hexdigest()==digest,'payload_sha256':digest,'tools':[]}
(b/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt));raise SystemExit(q.returncode)
