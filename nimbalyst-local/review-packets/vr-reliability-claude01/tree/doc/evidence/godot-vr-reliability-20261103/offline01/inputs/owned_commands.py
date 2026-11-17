"""Existing supervisor's addressed stdin seam; no process or domain executor."""
from pipe_ownership import identity

class OwnedCommands:
    def __init__(self, child, expected, owned, windows, clock, record_write):
        self.child=child;self.expected=expected;self.owned=owned
        self.windows=windows;self.clock=clock;self.record_write=record_write

    def current(self):
        assert self.child.poll() is None, 'owned child already exited'
        assert identity(self.child.pid)==self.expected, 'owned executable incarnation changed'

    def mapped(self):
        self.current();owned=self.owned()
        assert owned is not None and owned['pid']==self.child.pid and owned['incarnation']==self.expected
        matches=[w for w in self.windows() if w.get('pid')==self.child.pid and w.get('address')==owned['address'] and w.get('mapped')]
        assert len(matches)==1, 'begin requires the same currently mapped owned incarnation'
        self.current()

    def begin(self, supervisor):
        self.mapped()
        # The read-only mapped-window query has its own finite wait. Recheck
        # the ORIGINAL cutoff after that wait, before writing to the child.
        supervisor.cutoff(self.clock())
        if supervisor.finish_reason is not None:return
        self.record_write('begin',None)
        self.child.stdin.write(b'begin\n');self.child.stdin.flush()

    def finish(self, reason):
        if self.child.poll() is not None:return
        self.current();self.record_write('finish',reason)
        self.child.stdin.write(b'finish\n');self.child.stdin.flush()

    def delegated_begin(self, supervisor, authorized):
        # Authorization comes only from the future LAUNCH_AND_BEGIN command.
        # No stored early stdin, repeated setup, model round trip or new timer.
        if authorized and supervisor.prepared and self.owned() is not None:
            supervisor.command('begin',self.clock(),mapped=True)
