"""One owned lifetime observation/capture after the original failed EOF guard."""
import ctypes,json,os,select,subprocess,time
from pathlib import Path

def allow_owned_trace():
    # The existing parent-only permission, never ANY or a global Yama change.
    if ctypes.CDLL(None).prctl(0x59616d61,os.getppid(),0,0,0)!=0:os._exit(125)

def identity(pid):
    p=Path('/proc')/str(pid);s=(p/'exe').stat()
    f=(p/'stat').read_text().rsplit(')',1)[1].split()
    return [s.st_dev,s.st_ino,int(f[19])]

def mapped_owner(pid,expected):
    p=Path('/proc')/str(pid);assert identity(pid)==expected
    maps=(p/'maps').read_text();entries=[];main=[];anonymous=[]
    for line in maps.splitlines():
        fields=line.split(None,5)
        if len(fields)<6 or not fields[5].startswith('/') or 'x' not in fields[1]:continue
        address,permissions,offset,device,inode,name=fields
        if name.startswith('/memfd:'):
            anonymous.append({'address':address,'permissions':permissions,'name':name})
            continue
        assert not name.endswith(' (deleted)'), 'deleted mapped executable'
        f=p/'root'/name.lstrip('/');s=f.stat();major,minor=(int(v,16) for v in device.split(':'))
        assert (os.major(s.st_dev),os.minor(s.st_dev),s.st_ino)==(major,minor,int(inode)),name
        row={'path':name,'address':address,'permissions':permissions,'offset':offset,
             'stat_key':[s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns]}
        entries.append(row)
        if [s.st_dev,s.st_ino]==expected[:2]:main.append(row)
    assert main and identity(pid)==expected
    return {'pid':pid,'incarnation':expected,'main_mappings':main,'mapped_code_files':entries,'anonymous_code':anonymous,'maps':maps}

def owned_descriptors(wrapper_pid,expected):
    """Only this known wrapper and descendants enumerated by its children file."""
    assert identity(wrapper_pid)==expected
    queue=[(wrapper_pid,None)];seen=set();rows=[]
    while queue:
        pid,parent=queue.pop(0)
        if pid in seen:continue
        seen.add(pid);p=Path('/proc')/str(pid)
        try:
            f=(p/'stat').read_text().rsplit(')',1)[1].split()
            if parent is not None and int(f[1])!=parent:
                rows.append({'pid':pid,'ownership_changed':True});continue
            row={'pid':pid,'parent':int(f[1]),'starttime':int(f[19]),'state':f[0],'stdio':{}}
            for fd in ['0','1','2']:
                try:row['stdio'][fd]=str((p/'fd'/fd).readlink())
                except FileNotFoundError:row['stdio'][fd]='closed'
            rows.append(row)
            queue.extend((int(x),pid) for x in (p/'task'/str(pid)/'children').read_text().split())
        except FileNotFoundError:rows.append({'pid':pid,'exited_during_observation':True})
    return rows

def capture(private,wrapper,wrapper_owner,pid,expected,pidfd,environment):
    from hashes import raw
    result={'original_guard_failed':True,'capture_attempted':False,'captured':False}
    binding={'at_monotonic':time.monotonic(),'wrapper_pid':wrapper.pid,
             'wrapper_returncode':wrapper.poll(),'engine_pid':pid,'engine_expected':expected,
             'engine_pidfd_exited':bool(select.select([pidfd],[],[],0)[0])}
    try:
        if wrapper.poll() is None:
            assert identity(wrapper.pid)==wrapper_owner
            binding['wrapper_incarnation']=wrapper_owner
        if binding['engine_pidfd_exited']:
            binding['engine_alive']=False
            if wrapper.poll() is None:binding['owned_stdio']=owned_descriptors(wrapper.pid,wrapper_owner)
        else:
            binding.update(mapped_owner(pid,expected));binding['engine_alive']=True
        owner=private/'lifetime-at-cutoff.json';owner.write_text(json.dumps(binding,indent=2)+'\n')
        result['owner_binding_sha256']=raw(owner);result['engine_alive']=binding['engine_alive']
        if not binding['engine_alive']:return result
        # Set the verified namespace root and explicit executable BEFORE attach.
        # Only embedded/local exact mapped symbols; no auto-load/init/downloads.
        commands=['set auto-load off','set debuginfod enabled off','set debug-file-directory /nonexistent',
                  'set sysroot /proc/'+str(pid)+'/root','file "/proc/'+str(pid)+'/exe"',
                  'set print frame-arguments none','set print entry-values no','attach '+str(pid),
                  'info sharedlibrary','thread apply all bt 16','detach']
        command=['gdb','-nx','-nh','-q','-batch']
        for item in commands:command+=['-ex',item]
        invocation=private/'shutdown-invocation.json'
        invocation.write_text(json.dumps({'command':command,'timeout':15,'owner_binding_sha256':raw(owner)},indent=2)+'\n')
        assert identity(pid)==expected and not select.select([pidfd],[],[],0)[0]
        stack=private/'shutdown-stacks.raw'
        with stack.open('xb') as log:
            child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,env={**environment,'DEBUGINFOD_URLS':''})
            result['capture_attempted']=True
            try:code=child.wait(timeout=15)
            except subprocess.TimeoutExpired:result['capture_timed_out']=True;child.kill();code=child.wait(timeout=5)
        result.update(true_exit=code,captured=code==0,stack_sha256=raw(stack),invocation_sha256=raw(invocation))
    except Exception as error:
        result['error_type']=type(error).__name__
        (private/'lifetime-observation-error.json').write_text(json.dumps({'binding':binding,'error_type':type(error).__name__,'error':str(error)},indent=2)+'\n')
    return result
