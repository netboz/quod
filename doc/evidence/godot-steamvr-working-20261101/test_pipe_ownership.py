"""Finite real pipes: a normal child exit need not retire an inherited writer."""
import json,os,select,subprocess,sys
from pathlib import Path
from pipe_ownership import identity,engine_pipes,helper_pid,helper_writer,NamedWriter

if len(sys.argv)>1 and sys.argv[1]=='preexec':
    os.set_inheritable(int(sys.argv[2]),False)
    print('PRE_EXEC',flush=True)
    sys.stdin.buffer.readline()
    os.execv(sys.argv[3],[sys.argv[3]])

if len(sys.argv)>1 and sys.argv[1]=='helper':
    os.read(int(sys.argv[2]),1)
    raise SystemExit(0)
if len(sys.argv)>1 and sys.argv[1]=='engine':
    gate=int(sys.argv[2])
    child=subprocess.Popen([sys.executable,'-B',__file__,'helper',str(gate)],pass_fds=(gate,))
    print('vrenv.sh['+str(child.pid)+']: exec '+sys.executable+' -nokillprocess',flush=True)
    sys.stdin.buffer.readline()
    raise SystemExit(0)

checks=[]
def check(value,name):
    assert value,name
    checks.append(name);print('PASS '+name,flush=True)

gate,release=os.pipe();child=None
try:
    child=subprocess.Popen([sys.executable,'-B',__file__,'engine',str(gate)],pass_fds=(gate,),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    incarnation=identity(child.pid);pipes=engine_pipes(child,incarnation)
    check(pipes['stdout']['inode']!=pipes['stderr']['inode'],'capture distinct direct-engine pipes immediately at Popen')
    check(all(p['writable'] and p['fifo'] for p in pipes.values()),'direct engine descriptors are real write ends')
    check(select.select([child.stdout],[],[],5)[0]==[child.stdout],'actual helper launch notification arrives within finite bound')
    line=child.stdout.readline();pid=helper_pid(line,sys.executable)
    check(pid is not None,'existing runtime launch-line seam identifies only its named helper')
    check(helper_pid(line,'/bin/false') is None and helper_pid(b'unrelated process 1\n',sys.executable) is None,'other executable and unrelated lines do not select a process')
    first=helper_writer(pid,sys.executable,pipes)
    check(first['status']=='observed' and first['parent_pid']==child.pid,'real helper incarnation and direct parent are recorded')
    check(all(p['retains_engine_writer'] for p in first['streams'].values()),'helper write descriptors exactly match both captured engine pipes')
    wrong=first['incarnation'][:];wrong[2]+=1
    check(helper_writer(pid,sys.executable,pipes,wrong)['status']=='identity_mismatch','replaced incarnation refuses descriptor attribution')
    check(helper_writer(pid,'/bin/false',pipes)['status']=='identity_mismatch','wrong helper executable refuses descriptor attribution')
    child.stdin.write(b'finish\n');child.stdin.flush()
    check(child.wait(timeout=5)==0,'direct engine exits normally through its owned input')
    after=helper_writer(pid,sys.executable,pipes,first['incarnation'])
    check(after['status']=='observed' and all(p['retains_engine_writer'] for p in after['streams'].values()),'same helper remains an exact writer after direct engine exit')
    check(select.select([child.stdout,child.stderr],[],[],0)[0]==[],'no EOF is invented while the helper retains both write ends')
    os.write(release,b'x');os.close(release);release=None
    for name in ['stdout','stderr']:
        stream=getattr(child,name)
        check(select.select([stream],[],[],5)[0]==[stream] and stream.read()==b'','actual '+name+' EOF follows normal helper completion')
    missing=helper_writer(2147483647,sys.executable,pipes)
    check(missing['status']=='exited_before_observation','missing process is explicit unknown rather than writer attribution')
finally:
    if release is not None:os.close(release)
    os.close(gate)
    if child is not None:
        child.stdin.close()
        child.wait(timeout=5)

transition_read,transition_write=os.pipe();child=None
try:
    target=Path('/bin/cat').resolve()
    child=subprocess.Popen([sys.executable,'-B',__file__,'preexec',str(transition_write),str(target)],pass_fds=(transition_write,),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    os.close(transition_write);transition_write=None
    pipes=engine_pipes(child,identity(child.pid))
    assert select.select([child.stdout],[],[],5)[0]==[child.stdout] and child.stdout.readline()==b'PRE_EXEC\n'
    observer=NamedWriter(child.pid,target,pipes);early=observer.observe()
    check(early['status']=='identity_mismatch' and observer.start==early['incarnation'][2] and observer.incarnation is None,'pre-exec observation pins process birth without pinning the wrong executable')
    child.stdin.write(b'begin\n');child.stdin.flush()
    check(select.select([transition_read],[],[],5)[0]==[transition_read] and os.read(transition_read,1)==b'','CLOEXEC pipe observes actual executable transition without polling')
    accepted=observer.observe()
    check(accepted['status']=='observed' and observer.incarnation==identity(child.pid) and observer.start==early['incarnation'][2],'same process after real exec is admitted as the named helper')
    check(all(p['retains_engine_writer'] for p in accepted['streams'].values()),'exec transition preserves exact inherited pipe writer attribution')
    check(helper_writer(child.pid,target,pipes,expected_start=observer.start+1)['status']=='identity_mismatch','different process birth refuses writer attribution even with matching executable')
    child.stdin.close();check(child.wait(timeout=5)==0,'exec fixture closes normally without signals')
    check(child.stdout.read()==b'' and child.stderr.read()==b'','exec fixture produces genuine EOF on both streams')
finally:
    os.close(transition_read)
    if transition_write is not None:os.close(transition_write)
    if child is not None:
        child.stdin.close();child.wait(timeout=5)
print('PIPE_OWNERSHIP_PASS '+json.dumps({'checks':len(checks),'engine_exit':0,'eof':{'stdout':True,'stderr':True},'observation_only':True,'runtime_or_hardware':False,'signals':0,'real_owner':'pipe_ownership'}))
