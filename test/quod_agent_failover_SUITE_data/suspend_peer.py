"""Suspend one test peer; EOF or the fixed fault deadline always resumes it."""
import os
from pathlib import Path
import select
import signal
import sys

pid = int(sys.argv[1])
assert pid > 1
assert Path(f"/proc/{pid}/comm").read_text().strip() == "beam.smp"
with os.fdopen(os.pidfd_open(pid), "rb") as process:
    try:
        signal.pidfd_send_signal(process.fileno(), signal.SIGSTOP)
        # Signal delivery is asynchronous. Verify the held suspension after the
        # survivor's committed recovery/work barriers, immediately before CONT.
        print("stop_accepted", flush=True)
        assert select.select([sys.stdin], [], [], 120)[0], "fault deadline expired"
        assert sys.stdin.readline() == "resume\n", "test owner exited"
        assert Path(f"/proc/{pid}/stat").read_text().rpartition(") ")[2].split()[0] == "T"
    finally:
        signal.pidfd_send_signal(process.fileno(), signal.SIGCONT)
    print("resumed", flush=True)
