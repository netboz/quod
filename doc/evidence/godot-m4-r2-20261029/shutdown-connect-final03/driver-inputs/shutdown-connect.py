#!/usr/bin/env python3
"""Close the real window after an actual TLS challenge reaches a silent peer.

The peer injects a transport wait, never a fabricated domain response. A child0
and complete retirement observation are required; arming output is not success.
"""
import argparse,ctypes,faulthandler,hashlib,json,os,queue,re,shutil,socket,ssl,subprocess,threading,time
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--export',type=Path,required=True);p.add_argument('--diagnostic',action='store_true');a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent;out=evidence/a.label;out.mkdir(exist_ok=False)
private=Path('/home/yan/.cache/quod-m4-r2-artifacts/private')/a.label;private.mkdir(mode=0o700)
retained=out/'driver-inputs';retained.mkdir()
for src in [Path(__file__),root/'client/godot-tests/desktop_input.py']:shutil.copy2(src,retained/src.name)
import sys
sys.path.insert(0,str(retained));from desktop_input import deliver
record={'passed':False,'physical_acceptance':False,'fault':'TLS challenge reply deliberately withheld; no domain reply generated','native_input':[],
 'watchdog_seconds':60,'driver_inputs':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in retained.iterdir()}}
key=private/'tls-key.pem';cert=private/'tls-ca.pem'
command=['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost']
with (out/'certificate.log').open('xb') as log:record['certificate_exit']=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT).returncode
if record['certificate_exit']:raise RuntimeError('Owned certificate creation failed')
key.chmod(0o600)
listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(1);listener.settimeout(60)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(cert,key)
arrived=threading.Event();peer_closed=threading.Event();connection=None;peer_error=[]
def peer():
 global connection
 try:
  connection=context.wrap_socket(listener.accept()[0],server_side=True);connection.settimeout(60)
  request=b''
  while b'\r\n\r\n' not in request:
   block=connection.recv(4096)
   if not block:raise RuntimeError('Challenge connection closed before request headers')
   request+=block
  if not request.startswith(b'POST /api/auth/challenge HTTP/1.1\r\n'):raise RuntimeError('Unexpected request route')
  record['challenge_request_observed']=True;arrived.set()
  while connection.recv(4096):pass
  peer_closed.set()
 except Exception as error:peer_error.append(type(error).__name__)
 finally:
  if connection is not None:connection.close()
peer_thread=threading.Thread(target=peer);peer_thread.start()
env=dict(os.environ,M1B_PHASE='shutdown-connect',M1B_RESULT=str(out/'client-armed.json'),
 XDG_DATA_HOME=str(private/'data'),XDG_CONFIG_HOME=str(private/'config'),DOTNET_ROOT=str(private/'no-runtime'))
command=[str(a.export),'--display-driver','wayland','--','--qualification','--profile',str(private/'identity'),'--node','https://localhost:'+str(listener.getsockname()[1]),'--ca',str(cert)]
record['client_command']=command;record['diagnostic_export']=a.diagnostic
def allow_trace():
 if ctypes.CDLL(None).prctl(0x59616d61,os.getppid(),0,0,0)!=0:os._exit(125)
child=None;timer=None;receiver=None;start=time.monotonic();output=queue.Queue();receiver_errors=[]
def capture():
 if child is None or child.poll() is not None:return
 diagnostics=private/'diagnostics';diagnostics.mkdir(mode=0o700)
 with (diagnostics/'harness-stacks.log').open('x') as log:faulthandler.dump_traceback(file=log,all_threads=True)
 trace=diagnostics/'native-stacks.log'
 command=['gdb','-q','-nx','-batch','-p',str(child.pid),'-ex','set auto-load off','-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','thread apply all bt 20','-ex','detach']
 detail={'owned_pid':child.pid,'command':command,'capture_timeout_seconds':15,'memory_dump':False,'frame_arguments':False}
 try:
  with trace.open('x') as log:trace.chmod(0o600);detail['child_exit']=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=15).returncode
 except Exception as error:detail['error']=type(error).__name__
 (diagnostics/'result.json').write_text(json.dumps(detail,indent=2)+'\n');record['diagnostic_capture']=detail
try:
 child=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,preexec_fn=allow_trace)
 def receive():
  try:
   for line in child.stdout:output.put(line)
  except Exception as error:receiver_errors.append(type(error).__name__)
  finally:output.put(None)
 receiver=threading.Thread(target=receive);receiver.start();text=''
 with (private/'client-raw.log').open('x') as log:
  while True:
   line=output.get(timeout=60)
   if line is None:break
   log.write(line);log.flush();text+=line
   if line.startswith('M4_PENDING_CONNECT'):
    if not arrived.wait(timeout=10):raise RuntimeError('TLS challenge did not reach the owned peer')
    timer=threading.Timer(20,capture);timer.start()
   if line.startswith('M2_NATIVE_CLOSE '):deliver(line,child.pid,True,record['native_input']);record['native_close_delivered']=True
 record['client_exit']=child.wait(timeout=10);receiver.join(timeout=5)
 record['output_eof']=not receiver.is_alive();record['output_errors']=receiver_errors
 peer_thread.join(timeout=5);record['peer_saw_cancellation']=peer_closed.is_set()
 phases=[]
 for line in text.splitlines():
  if line.startswith('M4_R1_SHUTDOWN '):phases.append(json.loads(line.split(' ',1)[1]))
 record['managed_phases']=phases
 names=[r['phase'] for r in phases]
 record['passed']=record['client_exit']==0 and record.get('native_close_delivered') and record.get('challenge_request_observed') and record['peer_saw_cancellation'] and record['output_eof'] and not receiver_errors and 'ERROR:' not in text and (not a.diagnostic or ('quit-requested' in names and 'exit-tree-return' in names))
except Exception as error:record['failure']=type(error).__name__+': '+str(error)
finally:
 if timer:timer.cancel();timer.join(timeout=16)
 if child is not None and child.poll() is None:child.kill();record['client_exit']=child.wait(timeout=10)
 if receiver:receiver.join(timeout=5)
 if connection is not None:
  try:connection.shutdown(socket.SHUT_RDWR)
  except OSError:pass
 listener.close();peer_thread.join(timeout=5);record['peer_thread_released']=not peer_thread.is_alive();record['peer_errors']=peer_error
 raw=private/'client-raw.log'
 if raw.exists():
  raw.chmod(0o600);data=re.sub(rb'<<\s*(?:\d+\s*,\s*)*\d+\s*>>',b'<<redacted-byte-binary>>',raw.read_bytes());(out/'client.log').write_bytes(data)
 record['elapsed_seconds']=time.monotonic()-start
 (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
raise SystemExit(0 if record['passed'] and record['peer_thread_released'] else 1)
