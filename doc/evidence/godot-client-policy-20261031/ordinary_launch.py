"""Ordinary extracted app in a thin filesystem; exact-owned native window close."""
import json,os,select,socket,subprocess,time
from pathlib import Path
from hashes import TASK,raw
from isolation import command
os.umask(0o077);ev=Path(__file__).resolve().parent;label=__import__('sys').argv[1]
private=TASK/'private'/label;private.mkdir(mode=0o700,exist_ok=False)
package=Path(json.loads((ev/'inputs/package-inspection02.json').read_text())['extracted'])
sock=socket.socket(socket.AF_UNIX);sock.settimeout(5)
sock.connect(str(Path(os.environ['XDG_RUNTIME_DIR'])/'hypr'/os.environ['HYPRLAND_INSTANCE_SIGNATURE']/'.socket2.sock'))
args=command(package,private/'sandbox',['--display-driver','wayland','--audio-driver','Dummy','--xr-mode','off','--','--profile','/home/test/profile with spaces'],wayland=True)
args[args.index('--') : args.index('--')]=['--setenv','LD_DEBUG','libs']
record={'passed':False,'command':args,'ordinary_launch':True,'qualification_flag':False,'build_tools_available':False,'developer_paths_mounted':False,'no_network_namespace':True,'native_xr':False,'reader_errors':[]}
def query():
    r=subprocess.run(['hyprctl','-j','clients'],capture_output=True,timeout=5);assert r.returncode==0
    return json.loads(r.stdout)
def identity(pid):
    p=Path('/proc')/str(pid);exe=(p/'exe').stat();fields=(p/'stat').read_text().rsplit(')',1)[1].split()
    return [exe.st_dev,exe.st_ino,int(fields[19])],int(fields[1])
child=None;owned=None;deadline=time.monotonic()+30;buf=b''
try:
    with (private/'stdout.raw').open('xb') as out,(private/'stderr.raw').open('xb') as err:
        child=subprocess.Popen(args,stdout=out,stderr=err);record['wrapper_pid']=child.pid
        while owned is None:
            remaining=deadline-time.monotonic();assert remaining>0,'ordinary window readiness expired'
            readable,_,_=select.select([sock],[],[],remaining);assert readable,'ordinary window readiness expired'
            data=sock.recv(65536);assert data,'compositor event EOF before owned window'
            buf+=data
            while b'\n' in buf:
                line,buf=buf.split(b'\n',1)
                if not line.startswith(b'openwindow>>'):continue
                address='0x'+line.split(b'>>',1)[1].split(b',',1)[0].decode().removeprefix('0x')
                for w in query():
                    if w.get('address')!=address or not w.get('mapped'):continue
                    pid=w['pid']
                    try:ident,parent=identity(pid)
                    except FileNotFoundError:continue
                    expected=(package/'quod.x86_64').stat()
                    if ident[:2]!=[expected.st_dev,expected.st_ino]:continue
                    current=pid
                    while current!=child.pid and current>1:_,current=identity(current)
                    if current==child.pid:owned={'pid':pid,'address':address,'incarnation':ident};break
                if owned:break
        # Revalidate the same incarnation/window immediately before the one
        # existing addressed close. Never focus or control any other window.
        assert identity(owned['pid'])[0]==owned['incarnation']
        windows=[w for w in query() if w.get('pid')==owned['pid'] and w.get('address')==owned['address'] and w.get('mapped')];assert len(windows)==1
        record['owned_binding']=owned;record['mapped_window_observed']=True
        r=subprocess.run(['hyprctl','dispatch','hl.dsp.window.close({window="address:'+owned['address']+'"})'],capture_output=True,timeout=5)
        record['normal_close_exit']=r.returncode;assert r.returncode==0
        record['true_exit']=child.wait(timeout=60)
        assert record['true_exit']==0
        record['passed']=True
except Exception as error:
    record['failure']=type(error).__name__+': '+str(error)
finally:
    sock.close()
    if child is not None and child.poll() is None:
        record['owned_cleanup_required']=True
        if owned:
            assert identity(owned['pid'])[0]==owned['incarnation']
            subprocess.run(['hyprctl','dispatch','hl.dsp.window.close({window="address:'+owned['address']+'"})'],capture_output=True,timeout=5)
            record['true_exit']=child.wait(timeout=60)
        else:
            child.terminate();record['true_exit']=child.wait(timeout=10)
    if child is not None:record['true_exit']=child.returncode
    record['streams']={}
    for name in ['stdout','stderr']:
        p=private/(name+'.raw');p.chmod(0o600);record['streams'][name]={'path':str(p),'sha256':raw(p),'bytes':p.stat().st_size}
    text=(private/'stderr.raw').read_text(errors='replace')
    record['packaged_coreclr_loaded']='calling init: /opt/Quod app/data_Quod_linuxbsd_x86_64/libcoreclr.so' in text
    record['ordinary_launch_errors']='ERROR:' in text
    record['passed'] &= record['packaged_coreclr_loaded'] and not record['ordinary_launch_errors']
    (ev/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({k:v for k,v in record.items() if k not in ['command','owned_binding','streams']}))
raise SystemExit(0 if record['passed'] else 1)
