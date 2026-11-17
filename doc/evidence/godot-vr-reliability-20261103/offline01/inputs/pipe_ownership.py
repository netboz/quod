"""Payload-free observations of one invocation's explicitly named pipe writers."""
import os,re,stat
from pathlib import Path

def identity(pid):
    q=Path('/proc')/str(pid);s=(q/'exe').stat();fields=(q/'stat').read_text().rsplit(')',1)[1].split()
    return [s.st_dev,s.st_ino,int(fields[19])]

def descriptor(pid,fd):
    q=Path('/proc')/str(pid);p=q/'fd'/str(fd);s=p.stat()
    flags=next(line.split()[1] for line in (q/'fdinfo'/str(fd)).read_text().splitlines() if line.startswith('flags:'))
    return {'dev':s.st_dev,'inode':s.st_ino,'fifo':stat.S_ISFIFO(s.st_mode),
            'writable':(int(flags,8)&os.O_ACCMODE) in [os.O_WRONLY,os.O_RDWR]}

def engine_pipes(child,expected):
    assert identity(child.pid)==expected
    pipes={}
    for name,fd in [('stdout',1),('stderr',2)]:
        local=os.fstat(getattr(child,name).fileno());remote=descriptor(child.pid,fd)
        assert remote['fifo'] and remote['writable'] and [remote['dev'],remote['inode']]==[local.st_dev,local.st_ino]
        pipes[name]=remote
    assert identity(child.pid)==expected
    return pipes

def helper_pid(line,executable):
    match=re.match(rb'^vrenv\.sh\[(\d+)\]: exec '+re.escape(os.fsencode(executable))+rb'(?: |\r?\n|$)',line)
    return int(match[1]) if match else None

def helper_writer(pid,executable,pipes,expected=None,expected_start=None):
    row={'pid':pid,'expected_incarnation':expected,'status':'unobserved'}
    try:
        before=identity(pid);s=Path(executable).stat();row['incarnation']=before
        if before[:2]!=[s.st_dev,s.st_ino] or (expected is not None and before!=expected) or (expected_start is not None and before[2]!=expected_start):
            row['status']='identity_mismatch';return row
        q=Path('/proc')/str(pid)
        row['parent_pid']=int((q/'stat').read_text().rsplit(')',1)[1].split()[1])
        values={}
        for name,fd in [('stdout',1),('stderr',2)]:
            value=descriptor(pid,fd);pipe=pipes[name]
            value['same_engine_pipe']=value['fifo'] and [value['dev'],value['inode']]==[pipe['dev'],pipe['inode']]
            value['retains_engine_writer']=value['same_engine_pipe'] and value['writable']
            values[name]=value
        if identity(pid)!=before:row['status']='identity_changed';return row
        row.update(status='observed',streams=values)
    except (FileNotFoundError,ProcessLookupError):row['status']='exited_before_observation'
    except PermissionError:row['status']='permission_denied'
    return row

class NamedWriter:
    """A launch line may precede exec; process birth stays fixed across that exec."""
    def __init__(self,pid,executable,pipes):
        self.pid=pid;self.executable=executable;self.pipes=pipes
        self.start=None;self.incarnation=None;self.exited=False

    def observe(self):
        if self.exited:return {'pid':self.pid,'status':'already_exited_before_observation'}
        row=helper_writer(self.pid,self.executable,self.pipes,self.incarnation,self.start)
        if self.start is None and 'incarnation' in row:self.start=row['incarnation'][2]
        if row['status']=='observed':self.incarnation=row['incarnation']
        if row['status']=='exited_before_observation':self.exited=True
        return row
