# Integration regression 01

The retained command exited 1: 550 tests, two failures. Signup's direct-root
negative case returned `proof_unavailable` instead of a policy refusal. The
refactor moved option unification after `signup_name(Token, Name)`, so root's
independent permission check reached byte conversion with an unbound token.
The prior recipe bound that token from the supplied options in its head.

Correction: unify the composed options before validating identity and name.
Both normal signup and independent root authorization still use one recipe.
No assertion or deadline changed. The later content-tree restart failed its
minimum hosted-account assertion because the preceding signup test had not
created those accounts. Its recovery obligations remain unchanged.

The other 548 tests passed; the failed campaign is not a pass. The next run
must validate both signup and the subsequent restart with a fresh fixture.
