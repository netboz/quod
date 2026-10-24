# Leaving during missing query coverage

Diagnostic 01 reproduces `coverage` after unwatch and a real runtime
reconciliation. Diagnostic 02 also waits for installed-state notifications;
it times out after 15 seconds with the same owner paused. The retained runtime
snapshot has no selection, no pending reconciliation and no source waits.
The current body's chunk is installed. Both runs pass ordinary completion and
expiry and fail only the added disconnect case. No assertion was weakened.

The query was the missing-coverage consumer. Removing it updates demand, but
the ordinary installation path deliberately preserves a coverage wait when
the collider selection is unchanged. There is then no new installation to
wake the owner. This is distinct from the earlier premature query eviction.

Socket removal now cancels the input through the shared cancellation helper,
which clears its retained query coverage. At that actual dependency change,
the owner rechecks native physics once if no insertion is unfinished and its
navigation source is still current. Native coverage/occupancy checks decide
whether it resumes or remains unavailable. No new timer, queue, process,
deadline extension or unchanged-selection retry was added. Internal viewer
clearing during installation does not reenter physics installation.

`terrain-disconnect-fix-01` passes all six focused cases: applied, expired and
disconnected input; two original pending restoration scenarios; and the
large-coordinate pending motion regression. The disconnect case re-enters
the same owner and checks that cancelled query coverage is gone.
`terrain-disconnect-fix-02` passes eight cases, adding the converse checks:
removing a viewer leaves an unfinished insertion or actual missing body
coverage unavailable, and installing the required terrain then resumes it.

Clean-integration-04 remains unchanged and has an explicit stop request for
the end of its current EUnit gate. The narrow correction needs a new frozen
campaign and Fable validation before deployment.
