import pathlib,subprocess,json,hashlib,datetime
b=pathlib.Path(__file__).resolve().parent
packet=b/'review-request.txt'; metadata=json.loads((b/'payload.json').read_text()); digest=metadata['sha256']
assert hashlib.sha256(packet.read_bytes()).hexdigest()==digest
args=['/home/yan/src/quod/_build/quod27-opus-review-cli/node_modules/@anthropic-ai/claude-code-linux-x64/claude','--print','--model','claude-opus-5-5','--effort','high','--no-session-persistence','--permission-mode','dontAsk','--tools','','--disable-slash-commands','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--settings','{"disableAllHooks":true}','--output-format','json']
start=datetime.datetime.now(datetime.timezone.utc).isoformat()
(b/'invocation.json').write_text(json.dumps({'started':start,'args':args,'payload_sha256':digest,'scope':metadata['scope']},indent=2)+'\n')
timed_out=False
with (b/'stdout.json').open('xb') as out,(b/'stderr.log').open('xb') as err:
 q=subprocess.Popen(args,cwd=b,stdin=subprocess.PIPE,stdout=out,stderr=err)
 try:q.communicate(input=packet.read_bytes(),timeout=1200)
 except subprocess.TimeoutExpired:
  timed_out=True;q.terminate()
  try:q.communicate(timeout=10)
  except subprocess.TimeoutExpired:q.kill();q.communicate()
try:d=json.loads((b/'stdout.json').read_text())
except (ValueError,UnicodeError) as e:d={'is_error':True,'parse_error':type(e).__name__}

if isinstance(d.get('result'),str):(b/'opus-review.md').write_text(d['result']+'\n')
receipt={'started':start,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'child_exit':q.returncode,'is_error':d.get('is_error'),'models':list(d.get('modelUsage',{})),'payload_unchanged':hashlib.sha256(packet.read_bytes()).hexdigest()==digest,'payload_sha256':digest,'tools':[],'timeout_seconds':1200,'timed_out':timed_out,'parse_error':d.get('parse_error')}
(b/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt));raise SystemExit(q.returncode or (1 if timed_out or d.get('is_error') else 0))
