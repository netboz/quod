"""One ordinary human desktop window; no domain or input automation."""
import json,os,select,shutil,socket,subprocess,sys,threading,time
from pathlib import Path
os.umask(0o077);sys.dont_write_bytecode=True
root=Path.cwd();ev=Path(__file__).resolve().parent
base=root/'doc/evidence/godot-client-policy-20261031';sys.path.insert(0,str(base))
from isolation import command
task=Path('/data/quod-m4-vr-ca84d4f8-20261029');private=task/'private/desktop-human01'
private.mkdir(mode=0o700,exist_ok=False);(private/'drivers').mkdir()
for p in [Path(__file__),base/'isolation.py',root/'doc/evidence/godot-m4-vive-physical-20261029/manual_run.py']:shutil.copy2(p,private/'drivers'/p.name)
package=Path(json.loads((ev/'inputs/preflight02.json').read_text())['package'])
server=task/'private/quod-m4-live-desktop-human01-server'
ready=[json.loads(l[10:]) for l in (server/'server-raw.log').read_text().splitlines() if l.startswith('M1B_READY ')]
assert len(ready)==1;ready=ready[0]
record={'ordinary_product':True,'qualification':False,'XR':False,'domain_automation':False,'host_input_or_focus':False,'reader_errors':[],'participant_seconds':1800,'close_seconds':60,'outer_seconds':2100,'auth_state':'unobserved; no automated sign-in','private_profile':str(private/'sandbox/home/profile')}
def save(): (private/'invocation.json').write_text(json.dumps(record,indent=2)+'\n')
def identity(pid):
    p=Path('/proc')/str(pid);x=(p/'exe').stat();f=(p/'stat').read_text().rsplit(')',1)[1].split();return [x.st_dev,x.st_ino,int(f[19])],int(f[1])
def query():
    r=subprocess.run(['hyprctl','-j','clients'],capture_output=True,timeout=5);assert r.returncode==0;return json.loads(r.stdout)
sock=socket.socket(socket.AF_UNIX);sock.settimeout(5);instance=os.environ['HYPRLAND_INSTANCE_SIGNATURE']
sock.connect(str(Path(os.environ['XDG_RUNTIME_DIR'])/'hypr'/instance/'.socket2.sock'))
threads=[];child=None;owned=None;closed=False;info=private/'bwrap-info.json';started=time.monotonic();deadline=started+1800
record.update(start_monotonic=started,participant_deadline_monotonic=deadline,compositor_instance=instance)
read_exit,write_exit=os.pipe()
def close_owned():
    global closed
    if closed or child.poll() is not None:return
    assert owned and identity(owned['pid'])[0]==owned['incarnation']
    matches=[w for w in query() if w.get('pid')==owned['pid'] and w.get('address')==owned['address'] and w.get('mapped')]
    assert len(matches)==1
    result=subprocess.run(['hyprctl','dispatch','hl.dsp.window.close({window="address:'+owned['address']+'"})'],capture_output=True,timeout=5)
    record['normal_close_exit']=result.returncode;closed=True;assert result.returncode==0
try:
    with info.open('xb') as status:
        args=command(package,private/'sandbox',['--display-driver','wayland','--audio-driver','Dummy','--xr-mode','off','--','--profile','/home/test/profile','--node','https://127.0.0.1:'+str(ready['port']),'--ca','/fixture/ca.pem'],wayland=True,network=True)
        at=args.index('--');args[at:at]=['--info-fd',str(status.fileno()),'--ro-bind',str(server/'backend-ca.pem'),'/fixture/ca.pem']
        record['command']=args;child=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,pass_fds=(status.fileno(),));record['wrapper_pid']=child.pid
    for stream in ['stdout','stderr']:
        def drain(stream=stream):
            try:
                with (private/(stream+'.raw')).open('xb') as f:
                    for line in getattr(child,stream):f.write(line);f.flush()
            except Exception as error:record['reader_errors'].append(type(error).__name__)
        t=threading.Thread(target=drain);t.start();threads.append((stream,t))
    def ended():child.wait();os.write(write_exit,b'x')
    waiter=threading.Thread(target=ended);waiter.start();mapping_deadline=started+30;buf=b''
    while owned is None:
        remain=mapping_deadline-time.monotonic();assert remain>0,'ordinary mapping deadline expired'
        available,_,_=select.select([sock,read_exit],[],[],remain);assert available,'ordinary mapping deadline expired'
        assert read_exit not in available,'client exited before mapping'
        data=sock.recv(65536);assert data,'mapping stream EOF';buf+=data
        while b'\n' in buf:
            line,buf=buf.split(b'\n',1)
            if not line.startswith(b'openwindow>>'):continue
            address='0x'+line.split(b'>>',1)[1].split(b',',1)[0].decode().removeprefix('0x')
            for w in query():
                if w.get('address')!=address or not w.get('mapped'):continue
                pid=w['pid'];expected=(package/'quod.x86_64').stat()
                try:inc,parent=identity(pid)
                except FileNotFoundError:continue
                if inc[:2]!=[expected.st_dev,expected.st_ino]:continue
                ancestor=pid
                while ancestor!=child.pid and ancestor>1:_,ancestor=identity(ancestor)
                if ancestor==child.pid:owned={'pid':pid,'address':address,'incarnation':inc};break
            if owned:break
    sock.close();record.update(owned_binding=owned,mapped_monotonic=time.monotonic(),readiness='mapped ordinary window only; signed/UI state unobserved',finish_hook='send finish newline to this client wrapper PTY; guarded normal window close')
    save();print(json.dumps({'ordinary_window_mapped':True,'private_invocation':str(private/'invocation.json'),'remaining_seconds':deadline-time.monotonic(),'first_action':'Create my key, then Connect','auth_state':'not observed; no automated sign-in'}),flush=True)
    while child.poll() is None:
        remain=deadline-time.monotonic()
        if remain<=0:record['participant_deadline_reached']=True;close_owned();break
        available,_,_=select.select([sys.stdin,read_exit],[],[],remain)
        if read_exit in available:break
        if sys.stdin in available:
            text=sys.stdin.readline().strip()
            if text in ['finish','stop','']:record['finish_requested']=True;close_owned();break
            if text=='status':print(json.dumps({'owned_alive':child.poll() is None,'remaining_seconds':deadline-time.monotonic(),'auth_state':'unobserved'}),flush=True)
    record['client_exit']=child.wait(timeout=60)
except Exception as error:record['failure']=type(error).__name__+': '+str(error)
finally:
    sock.close()
    if child is not None and child.poll() is None:
        try:close_owned();record['client_exit']=child.wait(timeout=60)
        except Exception as error:record['retirement_failure']=type(error).__name__+': '+str(error)
    for name,t in threads:t.join(timeout=5)
    record['eof']={name:not t.is_alive() for name,t in threads};record['completed_monotonic']=time.monotonic();save()
    print(json.dumps({'closed':child is not None and child.poll() is not None,'client_exit':record.get('client_exit'),'eof':record.get('eof'),'failure':record.get('failure'),'retirement_failure':record.get('retirement_failure')}),flush=True)
raise SystemExit(0 if record.get('client_exit')==0 and not record.get('failure') and not record.get('retirement_failure') and all(record['eof'].values()) and not record['reader_errors'] else 1)
