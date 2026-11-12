# Phase 3 client gate run 01 stopped on `spaces`

`phase3-client-01-spaces` failed at `SpaceChecks.cs:241`: the check still
expected the create form's default width to be `100`. The ontology default is
now 10 m, so the check was stale; the client and ontology behaved as intended.
The navigation and local-backup steps of run 01 never started.

Fix: that one expectation (`"100"` to `"10"`). Server gates
(`phase3-server-01-*`) passed on `phase3-01-tree.diff` and read no client test
file, so they are not repeated. Client gates are repeated in full as
`phase3-client-02-*` on `phase3-02-tree.diff`.
