"""Removable qualification observation; never controls application completion."""
import ctypes,json,os,subprocess,threading
from pathlib import Path

def allow_owned_trace():
    if ctypes.CDLL(None).prctl(0x59616d61,os.getppid(),0,0,0)!=0:os._exit(125)

class ShutdownObservation:
    def __init__(self,child,private):
        self.child=child;self.private=Path(private);self.timer=None
        self.receipt={'owned_pid':child.pid,'after_completion_seconds':2,'capture_timeout_seconds':5,'arguments':False,'memory_dump':False,'armed':False,'captured':False}
    def observe(self,line):
        if self.timer is None and ((line.startswith('M') and '_PASS' in line[:50]) or line.startswith('PASS backup processing started')):
            self.receipt['armed']=True;self.timer=threading.Timer(2,self.capture);self.timer.start()
    def capture(self):
        if self.child.poll() is not None:return
        self.private.mkdir(mode=0o700,parents=True,exist_ok=False)
        command=['gdb','-q','-nx','-batch','-p',str(self.child.pid),'-ex','set auto-load off','-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','thread apply all bt 20','-ex','detach']
        self.receipt.update(captured=True,command=command)
        try:
            trace=self.private/'native-stacks.log'
            with trace.open('x') as stream:
                trace.chmod(0o600);self.receipt['child_exit']=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=5).returncode
        except Exception as error:self.receipt['error']=type(error).__name__
        (self.private/'capture.json').write_text(json.dumps(self.receipt,indent=2)+'\n')
    def finish(self):
        if self.timer is not None:self.timer.cancel();self.timer.join(timeout=6)
        return self.receipt
