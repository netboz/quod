# Release 263 clean gate 02: suite passed, candidate withdrawn

All eleven sequential gates passed with the same 684 input hashes throughout:
27 native tests in debug and release, Clippy, 134 client tests, UI build/lint,
3,884 EUnit tests, 146 Common Tests, xref, Dialyzer and production packaging.
The runner returned zero. Full logs and Common Test reports are retained.

This is **not release clearance**. The additional skin-boundary and landing
regressions requested by the plan review exposed failures beyond this suite.
The contact-precheck implementation has been withdrawn without deployment.
A corrected implementation requires a new frozen campaign; this result must
not be relabelled as its validation.

Campaign 01's socket-permission failure remains recorded. Campaign 02 used the
identical source hashes with required local network access. Its complete frozen
inputs are the identical [campaign 01 archive](../release-263-gates-01/frozen-inputs.tar.gz).
Generated browser outputs are hashed here but were not installed into the worktree.
