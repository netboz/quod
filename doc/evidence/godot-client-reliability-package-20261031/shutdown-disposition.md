# Shutdown evidence and limits

The accepted workbench-final05-render and final09-render remain whole failures.
Their existing C# companion prints completion before awaiting Main.CloseApplication.
The saved Python parent then waits for both client pipe EOFs with the original
60-second no-progress guard. Its cleanup records unretired_client_failure only
after Popen.poll() still reports a live child, then records the actual -15 exit.
Thus these were live client processes at cleanup, not merely an already-dead
client hidden by a pipe-reader wait. Earlier logs have no stage timestamps or
stack at that boundary, so they do not locate the wait inside managed retirement
versus native engine/renderer cleanup.

Main's current close owner cancels actions/backups, retires views/controllers and
representations, awaits ViewsDisposed/activeAction/backupWork/XR completion,
releases render models, awaits XR shutdown, releases the identity writer, then
requests SceneTree.Quit. Its ordinary external-quit path preserves the writer
lease until cancelled I/O finishes. ScenePanel owns its viewport/nodes and queued
framing callback. No source trace establishes that any one of these stages is
the retained pause's cause; changing close order would be speculative.

New shutdown-owner-probe01 adds only completion/EOF/exit observations and the
existing exact-owned trace trigger. It failed earlier at an actual native
OptionButton Pressed assertion, client1/server0/4EOF. It did not reach completion
or trigger a stack capture. Its source and failure are retained; no identical
retry was used to obtain a green result.

The coherent current-journey01 exercises a smaller, distinct ordinary
space/workbench path and a second-process reopen. Each completes and exits0;
the actual ordinary extracted product also exits0. The journey retains the
original total bound and caps its post-completion EOF wait at60 seconds, never
extending it. Its parent-only exact-incarnation optional trace branch did not
run; no ptrace/gdb result or stack is claimed. Normal exit is non-recurrence,
not a cause, a demonstrated fix, or complete shutdown reliability.

No product, engine, close policy, deadline, GC, forced quit, swallowed failure
or exit timer changed. Reliability and the historical desktop stalls remain
open. Further diagnosis needs a meaningful new owned observation at the actual
trigger; this checkpoint starts no soak or automatic repeated launches.
