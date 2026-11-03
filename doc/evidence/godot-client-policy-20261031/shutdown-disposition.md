# Shutdown observation

The historical workbench05/09 whole failures and checkpoint196's earlier
button-assertion failure are preserved. No cause or fix follows their later
normal exits.

The new removable diagnostic places payload-free milestones around the real
`Main.CloseApplication` session disposal, existing task awaits, model retirement,
XR adapter shutdown with XR disabled, identity release, SceneTree.Quit and
`_ExitTree`. It does not change order, deadlines, task completion or authority.
The exact-owned parent-only stack capture remains conditional on the original
60-second post-completion no-EOF trigger; it was not triggered.
This diagnostic is bound to the accepted96 production inputs with the removable
Main observation override. The later Transport-only error presentation fix
does not change Main or its disposal owners; the new ordinary package's normal
exit is a separately recorded observation.

Observation01 failed in fixture startup before launching a client because the
standalone runtime code path omitted compiled checkout dependencies. Observation02
used that corrected code path and reached a signed account and the exact authored
workbench with live source/view/scene consumers. All close awaits settled, Quit
and tree exit were observed, and client/server exited 0 with all four EOFs.
Final scene, socket, source, appearance and capture counts are zero; XR is off.

Its original wrapper is still failed: its metadata assertion expected one
`models.settled` row, while instrumentation emitted both task completion and the
following awaited milestone. The separate offline reconciliation checks their
recorded task-status distinction and exact order against the original bytes.
No application rerun or shutdown fix was made to obtain a green wrapper.

The measured interval from close-begin to the `_ExitTree` milestone in that one
run is 0.051128695 seconds; it is not process-exit latency.
This is non-recurrence, not a reliability guarantee. The prior intermittent
native/client wait remains unresolved; no speculative engine, GC, close-order,
timeout or forced-success change is included.
