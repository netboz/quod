# Independent checks before the final Fable validation

This is not the final release assessment. Full gates and the correction review
are still pending.

The review-02 functional findings are reproduced in source: the parser retains
unary minus in data positions, and the library discarded the resolver result
vector. The corrected real library form and eleven controller tests pass.
The four frozen EUnit failures have causal triage and focused passing evidence;
the original assertions for pending movement and rebasing were preserved.

Malformed plan-policy changes now fail at the existing seal boundary. The
check uses the selected policy's captured dependency set, so changing a helper
predicate cannot escape it. It judges the final candidate without trying to
capture unpublished OCC tokens. Admission still uses the committed allowance.
Tests cover invalid values, variables, unknown resources, duplicate overrides,
helper changes, atomic replacement and staged self-grants.

The review's proposed mandatory repair allowance would change authored policy.
Zero is explicitly accepted in the shared policy contract and tests; a valid
zero can deliberately stop later writes. The implementation does not claim
automatic recovery from such a decision. Malformed policy and intentional
denial are separate cases.

The allocation concern needs the existing trust contract kept explicit.
`src/quod_relay.erl:4-7` documents trusted committee atom handling, and its
`:28` calls unrestricted `binary_to_term` before consensus-message dispatch.
`git show HEAD:src/quod_relay.erl` has the same code and contract. The pinned
architecture in `doc/outdated/distributed-proof-plan.md:1026-1031` also
distinguishes Byzantine ordering/atomicity from trusted validator execution.
The new Prolog allowance is proof-side admission, not a claim that arbitrary
malicious committee traffic is an atom-allocation sandbox. Adding a check only
in `materialize_prepared_plan` would miss ordinary transactions, independent
applications and the earlier consensus ETF decode. A coherent change to that
boundary must cover all of those owners; a partial check would give a false
guarantee. The bounded Fable consultation is tracing those seams independently.
