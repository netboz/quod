#!/usr/bin/env python3
"""One fresh headed backup-import observation; never repeats an outcome."""
import hashlib,json,os,queue,re,subprocess,sys,threading,time
from pathlib import Path

os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent
cache=Path('/home/yan/.cache/quod-m4-observation1-artifacts');private=cache/'private/backup-import01'
private.mkdir(mode=0o700,parents=True,exist_ok=False)
record_path=ev/'observation01.json';assert not record_path.exists()
manifest=json.loads((ev/'inputs/diagnostic-build.json').read_text());source=Path(manifest['source'])
def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
assert manifest['passed'] and not manifest['distributable'] and manifest['diagnostic_only']
assert all(digest(source/name)==row['sha256'] for name,row in manifest['export_outputs'].items())
assert all(digest(root/name)==sha for name,sha in manifest['live_source_inputs'].items())
assert all(json.loads((ev/('build-'+name)/'result.json').read_text())['exit']==0 for name in ['restore-debug','restore-exportrelease','export'])
record={'single_observation':True,'headed_desktop':True,'physical_hardware_action':False,'passed':False,
    'marker':'M4_QUIT_RETURNED','marker_seen':False,'historical_cause_or_resolution':False,'driver_commands':[]}
def sanitize(raw):
    def binary(match):
        values=re.findall(rb'\d+',match[0])
        return b'<<REDACTED_BYTE_BINARY>>' if len(values) in [32,64] and all(int(v)<256 for v in values) else match[0]
    return re.sub(rb'<<\s*(?:\d+\s*,\s*)*\d+\s*>>',binary,raw)
def run(label,command,cwd=root,timeout=300):
    stdout=private/(label+'-stdout.raw');stderr=private/(label+'-stderr.raw')
    started=time.monotonic();entry={'label':label,'command':command,'cwd':str(cwd),'stdout_raw_private':str(stdout),'stderr_raw_private':str(stderr)}
    record['driver_commands'].append(entry)
    with stdout.open('xb') as out,stderr.open('xb') as err:
        child=subprocess.Popen(command,cwd=cwd,stdout=out,stderr=err,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'))
        entry['driver_pid']=child.pid
        try:status=child.wait(timeout=timeout);entry['outer_timeout']=False
        except subprocess.TimeoutExpired:
            entry['outer_timeout']=True;child.terminate();status=child.wait(timeout=10)
    for kind,path in [('stdout',stdout),('stderr',stderr)]:
        path.chmod(0o600);data=path.read_bytes();target=ev/(label+'-'+kind+'.log');target.write_bytes(sanitize(data))
        entry[kind+'_raw_sha256']=hashlib.sha256(data).hexdigest();entry[kind+'_public_sha256']=digest(target)
    entry.update(child_exit=status,elapsed_seconds=time.monotonic()-started)
    if status or entry['outer_timeout']:raise RuntimeError(label+' failed; no automatic retry')
server_command=['python3',str(ev/'serve.py'),'observation1-server01','--stage','/tmp/quod-m3b-8b352c53/m3b-gates01/source','--profile','prod','--qualified']
server=None;reader=None;server_lines=queue.Queue();reader_errors=[];server_eof=threading.Event()
try:
    # Fixture provider build only; reuse exact previously qualified Core bytes,
    # without invoking its189-check executable or rebuilding production owners.
    provider=cache/'account-preparation-tool'
    run('preparation-restore',['dotnet','restore','Prepare.csproj','--configfile','NuGet.Config'],provider)
    run('preparation-build',['dotnet','build','Prepare.csproj','-c','Release','--no-restore'],provider)
    record['server_command']=server_command
    server=subprocess.Popen(server_command,cwd=root,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    def receive():
        try:
            for line in server.stdout:server_lines.put(line)
        except Exception as error:reader_errors.append(type(error).__name__)
        finally:server_eof.set();server_lines.put(None)
    reader=threading.Thread(target=receive);reader.start()
    while True:
        line=server_lines.get(timeout=60)
        if line is None:raise RuntimeError('Fixture ended before readiness; observation unlaunched')
        print(line.rstrip(),flush=True)
        if line.startswith('M1B_READY '):ready=json.loads(line[len('M1B_READY '):]);break
    ca=cache/'private/quod-m4-live-observation1-server01/backend-ca.pem'
    endpoint='https://127.0.0.1:'+str(ready['port'])
    preparation=private/'settled-account'
    run('account-preparation',['dotnet',str(provider/'bin/Release/net10.0/Prepare.dll'),endpoint,str(ca),str(preparation),str(root/'client/test/fixtures/native-contract/contracts.json')])
    command=['python3',str(ev/'inputs/desktop-drivers/local.py'),'--phase','backup-import','--export',manifest['export_executable'],
        '--journey-private',str(preparation),'--node',endpoint,'--ca',str(ca),'--evidence',str(ev/'backup-import01'),
        '--private',str(private/'fresh-device'),'--desktop']
    record['desktop_observation_launched']=True
    run('desktop-driver',command,timeout=600)
    result=json.loads((ev/'backup-import01/result.json').read_text());record['child_results']=result
    log=(ev/'backup-import01/backup-import.log').read_text()
    record.update(marker_seen='M4_QUIT_RETURNED' in log,marker_count=log.splitlines().count('M4_QUIT_RETURNED'),
        client_exit=result[-1]['child_exit'],client_output_eof=result[-1].get('output_eof',False),
        client_watchdog=result[-1].get('watchdog',False),local_pass_marker='M1B_LOCAL_PASS' in log)
    stderr=(ev/'desktop-driver-stderr.log').read_text(errors='replace')
    record['driver_reader_exception_text']=any(text in stderr for text in ['Exception in thread','UnicodeDecodeError','Traceback'])
    record['passed']=all(row.get('passed') for row in result) and record['marker_seen'] and record['client_output_eof'] and not record['client_watchdog'] and not record['driver_reader_exception_text']
except Exception as error:record['failure']=str(error)
finally:
    if server is not None:
        try:
            server.stdin.write('stop\n');server.stdin.flush();server.stdin.close();record['server_child_exit']=server.wait(timeout=30)
        except Exception as error:
            record['server_stop_error']=type(error).__name__;server.terminate();record['server_child_exit']=server.wait(timeout=10)
        reader.join(timeout=5);record['server_output_eof']=server_eof.is_set() and not reader.is_alive();record['server_reader_errors']=reader_errors
        raw=cache/'private/quod-m4-live-observation1-server01/server-raw.log'
        if raw.exists():(ev/'server-sanitized.log').write_bytes(sanitize(raw.read_bytes()))
    case=ev/'backup-import01'
    if (case/'result.json').exists():
        record['child_results']=json.loads((case/'result.json').read_text())
    if (case/'backup-import.log').exists():
        data=(case/'backup-import.log').read_bytes();raw=private/'client-raw.log'
        if not raw.exists():raw.write_bytes(data);raw.chmod(0o600)
        (case/'backup-import.log').write_bytes(sanitize(data))
        record['marker_seen']=b'M4_QUIT_RETURNED' in data
    record['passed']=record['passed'] and record.get('server_child_exit')==0 and record.get('server_output_eof',False) and not reader_errors
    record['original_stalls_remain_failed_open']=True
    record_path.write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({k:v for k,v in record.items() if k!='driver_commands'}),flush=True)
sys.exit(0 if record['passed'] else 1)
