# Phase 3 client gate run 02 stopped on `gui`

`phase3-client-02-gui` failed in its `fresh` phase: the headless pointer press
on a checkbox (`ExportChecks.Mouse`, `ExportLifecycle.cs:58`) did not toggle
within its 5 s wait. The same journey passed in `phase3-client-01-gui` and
`phase2-client-02-gui` with the same client code path; the only source change
between run 01 and run 02 is one expected string in `SpaceChecks.cs`, which
this phase does not execute. The same timeout at the same line is retained in
earlier campaigns (`godot-m1b-20261028/journey-10`,
`godot-m4-r2-20261029/gui-headless-final01`). Cause not established here;
treated as the known intermittent headless pointer step, not as a regression.

The spaces, navigation and local-backup steps of run 02 never started. Run 03
repeats the client gates in full on the same frozen tree (`phase3-02-tree.diff`).
