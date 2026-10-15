# Independent disposition

This records the earlier design-review disposition. Subsequent
[solution consultation](solution-consultation/README.md) and
[implementation review](implementation-review-02/review.md) resolve its blockers;
the historical findings below describe the reviewed draft, not the final design.

Checked Fable's findings against the current source. The reviewed design remains
unchanged, so its manifest still identifies the document the user sees.

## Accepted design gaps

1. The existing physics projection requires an assigned hosted authority. A
   first-host phase cannot be driven merely by declaring the completed world's
   rows. Extend the existing installation owner with an explicit unassigned
   phase; do not create a separate driver. Fable's proposed sentinel row is not
   sufficient by itself: `quod_physics:spec/3` requires positive host epoch,
   positive structure revision and a 32-byte key. Resource-source resolution also
   assumes the current row shape. Specify and validate the whole phase contract.
2. Node execution, key preparation and custodied signing currently cannot be
   composed in the proposed way. `quod_agent:sign_request/4` requires the node
   mode wrapper, while its custodied branch re-enters with plain execute.
   Preserve the authenticated executor mode through preparation and signing.
3. `signed_physics_request/3` currently verifies a signer in the world's own
   scope. Node-origin initialization needs narrow verification of the selected
   exact node and the exact anchored target/action. Ordinary hosted activation
   must retain its existing checks.
4. Recovery of an inner request stored but never submitted does not guarantee
   progress. Resolving an unknown request must not become resubmission. Existing
   explicit, authorized cancellation can fence a retained request; expose the
   actual state instead of promising automatic recovery. Exact-redelivery
   permission for prepared claims does not authorize re-proving signed goals.
5. Local live definitions currently reach both an authored subscription check
   and a foreign-projection lookup (`quod_runtime:resolve_physics_body/6`). A
   Prolog-only self-subscription bypass is incomplete. Resolve exact local
   definitions from the existing committed selection and retain its ordinary
   dependencies; keep foreign verification unchanged.
6. `entity_eidolons/2` currently starts from direct instance classes. Shared
   inherited Eidolon selection and a space-based scene composition are required;
   remove the lobby-private dispatch and placement inventories in that coherent
   replacement. Preserve deliberate representation choices and exact identities.
7. Scene body marks and pilot controls must resolve current admitted bindings.
   Founding must supply the initial run, allocator and structure state. Initial
   admission/control/host facts belong in the same ordinary atomic transition.
   No native resource may be released for partial staging.

## Advice not accepted as written

- **Finding 11 is incorrect.** `instance_of(lobby_floor, floor)` is already
  class-first: `lobby_floor` is the class and `floor` is the instance. Likewise
  `lobby_roof`/`roof` and `prolog_console`/`console`. Do not invert these terms.
- **Finding 13 is already supported by shared code.** Reflexive/transitive
  ancestry is defined in `common_predicates.pl` from line 129, with cycle-safe
  traversal and existing `quod_class_semantics_tests` coverage. The composed
  lobby must use it; no new inheritance engine is required. These source/tests
  were inspected, not rerun as part of this documentation review.
- **Finding 5 cannot weaken the uncertain-write rule.** The proposed new
  custody-store attempt after restart may be mutually exclusive with an earlier
  attempt, but commit exclusivity is not permission to resubmit or replace an
  uncertain write. The design's strict rule covers the store operation too.
  The existing physics owner's volatile uncertainty field does not establish
  durable knowledge of the outer store request after a crash.
- The proposed initialization sequence includes an extra hosted activation after
  the node's composite first-host transition. That may follow current run fencing,
  but it is a proposal to validate, not a proven minimal sequence or acceptance.

## Remaining blocking contract

Specify how the original custody-store operation retains recoverable identity
across the crash-before-observed-commit window, without a second journal, hidden
retry, deadline change or borrowed FIPA exception. Current direct-effect custody
stores prepared effects, not arbitrary unexecuted requests. The review does not
provide a complete resolution of that gap. It remains a shared-lifecycle design
question before implementation can be accepted.

Keep the requested inheritance model unchanged while resolving this contract.
Review completion does not authorize declaring the fix implemented, running a
release, or marking the lobby bug done.
