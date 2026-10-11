# Independent disposition

Fable found no blocker in the test change. The queue's second wait is
reproduced by the real worker, owner and gproc custody; the regression now
checks it explicitly. The existing pinned SDK test exporter is reused.

The proposed hook timeout is unnecessary for worker cleanup: with_owner
starts the foreign owner linked to the EUnit process, and every admitted
worker is covered by quod_process:kill_when_owner_dies/2. Normal failure uses
the existing after cleanup; an EUnit process death terminates its gen_server
parent link and the directional owner watcher force-kills a held worker.
The gate itself is deliberately released by processing evidence, not a timer.

The existing custody_wait observation describes the queued request itself,
while active identifies its actual predecessor. This is explicit in the
production descriptor and existing dedicated custody tests. Missing linkage
is kept honest; this bounded test repair does not redesign observability.

The source trace keeps caller/PID and looks up registered names when collected.
A departed transient process may lack names, but its caller/PID and I/O still
fail the assertion. Moving lookup into the relay also cannot guarantee a
short-lived process remains live. No call is excluded on that basis.

The suggested journal-retirement ordering is a hypothesis, not a diagnosis.
Full code shows commit_finality calls install_live_entry (including transaction
retirement), reconciles the journal, and only then sends ordered apply_live to
Prolog. The operation's applied terminal source receipt cannot demonstrate
that earlier retirement remains outstanding. Later owner work and unrelated
consensus remain candidate causes. The first write observation is unresolved;
the next full campaign retains the assertion and attribution. Isolated passing
checks do not erase the failure or establish its cause.
