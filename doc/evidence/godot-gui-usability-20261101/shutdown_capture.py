"""One exact-owned observation at the original no-EOF trigger; never a retry."""
import ctypes,json,os,subprocess,time
from pathlib import Path
def allow_owned_trace():
    if ctypes.CDLL(None).prctl(0x59616d61,os.getppid(),0,0,0)!=0:os._exit(125)
def capture(private,pid,expected,environment,raw):
    from hashes import raw as digest
    result={'original60s_no_EOF_trigger':True,'attempted':False,'inspected':False}
    try:
        p=Path('/proc')/str(pid);s=(p/'exe').stat();ticks=int((p/'stat').read_text().rsplit(')',1)[1].split()[19])
        assert [s.st_dev,s.st_ino,ticks]==expected
        owner=private/'shutdown-owner.json';owner.write_text(json.dumps({'pid':pid,'incarnation':expected,'monotonic':time.monotonic()},indent=2)+'\n')
        result['alive_at_trigger']=True
        result['thread_count']=len(list((p/'task').iterdir()))
        command=['gdb','-nx','-nh','-q','-batch','-p',str(pid),'-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','thread apply all bt 16']
        invocation=private/'shutdown-invocation.json';invocation.write_text(json.dumps({'command':command,'timeout':15,'owner_binding_sha256':digest(owner)},indent=2)+'\n')
        with raw.open('xb') as log:
            child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,env={**environment,'DEBUGINFOD_URLS':''})
            result['attempted']=True
            try:code=child.wait(timeout=15)
            except subprocess.TimeoutExpired:result['timed_out']=True;child.kill();code=child.wait(timeout=5)
        result.update(true_exit=code,inspected=code==0,invocation_sha256=digest(invocation),stack_sha256=digest(raw))
    except Exception as error:result['error_type']=type(error).__name__
    return result
