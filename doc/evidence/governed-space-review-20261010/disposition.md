# Independent assessment of the requested Fable review

The [report](review-02/fable-review.md) reviews the frozen preliminary draft,
not the final implementation. The receipt records `claude-fable-5-1`, successful
exit, and unchanged frozen inputs. Review-01 never launched Claude: sandbox
EPERM stopped manifest preparation. That failed attempt remains intact.

The parent checked the findings against the production source. The corrected
plan keeps composable Prolog vocabulary, destination-owned organizational
membership, entity-owned versioned exclusive assignment, and atomic destination
admission. No runtime owner or bridge changes are needed for this prerequisite.

## Adopted changes

- D1/P4: add independent publisher and curator signing keys in different
  ontologies. Grant exact entry shapes to those principals and separately test
  source invocation, source delegation, destination admission and curator
  revocation. Administrative node grants remain setup/lifecycle conveniences;
  the distinct-principal scenario cannot use them.
- D2: add explicit revision, held-placement, ambiguous-assignment and physical
  configuration/consequence refusal reasons. Check those reasons in tests.
- D3: inline the slot mutation inside the complete entry transitions and remove
  the separately callable `space_assign/5` helper. Document exact ACL shapes
  and the distinction between domain actions and unrestricted administration.
- D4/D5: use the real outcome-resolution shape and registry API; park both
  completed proofs with the existing scope-safe barrier and monitor their
  cleanup. Release the second after the first commit, proving stale-plan
  rejection without relying on scheduling or sleeps.
- D6/D7: compose the physics vocabulary while asserting no simulation or domain
  actor installation; preserve genesis anchors and applied heights across replay,
  together with existing identity attributes, memberships and assignment state.
- P1: explicitly bound acceptance to unsimulated physical admission. Simulated
  entity/body bindings and atomic constraint/checkpoint/activity cleanup are
  physics integration work. The mandatory consequence fails closed when absent
  or refused; it is not a claim of implemented body cleanup.
- P2/P5: document that both owners must participate, with no offline unilateral
  release; reject direct self-containment and self-placement. Containment is a
  direct graph, not a transform tree; other cycle restrictions are domain policy.

## Qualifications to the review

The repository's failure contract permits ordinary false policy to fail without
an explicit custom reason (`doc/proofs.md`, failure class 1). D2 does not require
turning every missing grant into configuration failure. Invocation denial has
the engine's `not_allowed` reason; tests identify the relevant policy predicate
where a false authored policy is expected. Failure payloads also include automatic
call frames, so explicit reasons are checked within the decoded payload.

Inlining a helper is useful API simplification, not protection against an
unrestricted administrator. Such an ACL already permits arbitrary assert/retract
and code editing. The production boundary remains exact invocation policy plus
domain grants, not a Prolog predicate-name privacy convention.

Re-entrant staged reads are an existing engine guarantee, independently exercised
by signed admission, two completed competing proofs and replay through the real
owners. No duplicate proof/coordinator implementation was introduced.

## Verification record

All attempts and failures are retained in the evidence directory. The initial
suite's first failure was a mismatched resolution result API; the second was a
nonexistent registry function. Subsequent retained attempts exposed a top-level
context assumption in the reused barrier, the distinction between ordinary
failure traces and explicit reasons, and plain `fail` for an absent predicate.
These were test defects; no production guarantees were weakened to make them pass.
The final evidence manifest and test logs record the accepted tree and results.
