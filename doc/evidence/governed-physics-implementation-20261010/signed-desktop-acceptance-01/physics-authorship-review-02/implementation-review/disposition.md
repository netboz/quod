# Checked disposition: stronger evidence, activation still blocked

Fable reviewed the revised plan and test implementation on 28 frozen files,
returned child exit 0 with no reported error, and changed no frozen input.
The exact reviewed tree subsequently passed all 15 affected tests in
`source-authoring-04.log`. This is offline verification, not live acceptance.

Accepted test improvements are a second restart after all entry points have
been installed, canonical source readback after every edit, and decoding the
specific `not_allowed` and `edit_conflict` refusal reasons. The partial-program
restart remains covered. These changes are undergoing separate verification
and a focused follow-up review; the earlier result does not certify them.

The runtime's zero reaction-failure counter is explicitly limited: without
hosted agents, no domain binding runs those reactions. The separate matcher
regression checks that both clauses return `unmatched` for ordinary domain
metadata; this is the evidence for their authenticated-observation guard.
Likewise, the failure map belongs to internal resource work. The test relies
on the existing owner processing the committed invalidation before its later
explicit reconcile request; that request independently must return `ok`.

The source-guard concern uncovered a concrete cold-symbol gap. The retained
`cold-source-fence-02.log` shows that source inspection of a completely unknown
predicate succeeds with no read dependency and no atom allocation. The first
reproduction failed because the existing test helper was not on the escript
code path; its log is retained. The revised authoring guard adds ordinary
negated `physics_space/3` and `agent_host/4` calls. Normal target admission
materializes their callable names before execution, and their absent procedure
reads join ordinary predicate OCC. A regression starts with a random absent
symbol and checks that exact production materializer/overlay read dependency.
No change to the source-inspection primitive or a live-query exemption is made.

The cold-follower limitation remains. Neither a single-VM new-symbol test nor
the pure symbol-count measurement proves a cold remote committee applies this
publication. The final atomic activation must also fit the 2048-token parser
and 1024-diff-operation allowances, alongside the previously reported bounds.

The initial key-custody finding is confirmed against all production callers.
The first-host action accepts a public key, while private preparation through
`prepare_agent_custody/3` is currently restricted to recovery of an already
hosted agent. Existing vault and agent custody owners are the place to resolve
this; a new physics service or capability-manifest bypass is unnecessary.
The suggestion to retire recovery in favour of operator-only key generation
is not adopted: governed recovery remains a required existing lifecycle.
The next design must define first-host preparation, authorization, exact
identity/assignment fencing, resource policy, rollback and uncertain-operation
handling before a real key or activation request is submitted.

The actual publication sequence must be explicit: all helpers first, then
`agent_hosting_projection/4`, `physics_projection/2` and `react_on/2`. No live
publication driver or manual browser sequence is approved by these tests.
The complete physical configuration and its size, real geometry, initial
custody and real-world collision/remote installation acceptance remain open.
