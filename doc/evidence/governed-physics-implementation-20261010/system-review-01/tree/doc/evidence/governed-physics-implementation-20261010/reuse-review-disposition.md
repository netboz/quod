# Checked disposition of the reuse audit review

The requested Claude review used `--model fable`; the receipt reports
`claude-fable-5-1`, child exit 0, no model error and 52 unchanged frozen inputs.
The original [report](reuse-review-01/fable-review.md), prompt, stdout/stderr,
source manifest and frozen tree are preserved. Current reviewed files also
matched their frozen hashes when the report was received, before this correction.

The reviewer accepts the audit's factual account of the existing model and
withdrawal of the mandatory capability-epoch proposal. This is a scoped audit
verdict, not approval of an implementation plan, release or completed feature.

## Findings checked against the task and code

1. **Live reference versus materialized recipe: recommendation rejected.**
   The review correctly identifies the local-only resource selector and missing
   source-notice invalidation. It then recommends copying a body at admission
   using the existing versioned door recipe path. The original task explicitly
   requires a live collider in ontology A to follow A's committed edits through
   the existing subscriptions, with no mirrored mutable collider store or
   manual re-adoption. It explicitly distinguishes deliberately pinned recipes.
   The review prompt compressed this requirement and did not include that full
   paragraph; this contributed to treating the pinned option as undecided.
   `physics_door_definition/2` and the door recipe documentation confirm the
   recipe path exists, but it cannot satisfy the live-instance case. The exact
   source-instance/body/assignment/authority binding remains to be specified;
   the required live-update behavior is already settled.

2. **Incomplete review snapshot: accepted limitation, independently checked.**
   The packet omitted `quod_agent_predicates`, `quod_committee_predicates`,
   `quod_ontology_predicates` and `quod_simplex`. These were inspected after the
   review. Agent loading registers authenticated principal, local-node, signing
   and reconciliation bridges; it does not register physics. Committee bridges
   are common. The ontology module supplies governed lifecycle/principal entries.
   Simplex constructs the founding manifest and extracts exactly one canonical
   manifest fact from genesis. This supports the source-code claims, but does
   not establish the live personal lobby's manifest. Supplemental source hashes
   are recorded separately; Claude did not review those supplemental files.

3. **Common registration qualifications: accepted.**
   Registration is distinct from allocation. Exact repeated descriptors already
   return the unchanged interpreter state. A shared-base change needs retained
   replay/recovery and incompatible-validator checks under the existing cold
   release authority. Independently add retained predicate-name collisions to
   those checks. No edit of founding provenance follows from shared registration.
   The audit now lists the Prolog configuration, authority, custody and policy
   that registration does not supply. No new capability-epoch contract follows.

4. **Per-space settings and permissions: accepted.**
   Current Prolog allowances and read/control policy already take the world as
   an argument. Ordinary instance attributes and derived predicates can supply
   those values without another settings owner. A restricted interpreted result
   wrapper can preserve the bridge's existing checks. Optional field privacy
   would also have to govern other allowed result paths; it was not requested.
   Independently qualify that `authorization_result/2` returns only allowed or
   denied and discards bindings. Entry ACL unification cannot be treated as a
   filter on subsequent answers. The executing rule must enforce any such
   restriction; current live physics calls already require ground inputs.

5. **Compiled following and call-path precision: accepted.**
   Compiled predicates bypass generated argument-following clauses. Explicit
   foreign calls use target-owned authorization; the ACL sees namespace names
   in the call path while exact target identities remain bound to proof scopes.
   A same-scope `::` is an internal call, not a fresh authorization boundary.

6. **View-dependency narrowing: not adopted.**
   The report calls the extension conditional on a foreign lobby view proof.
   The task requires actual dependencies, including disabled/denied selection,
   and the existing `lobby_instance:lobby_view/2` already calls anchored lobby
   and modelling vocabularies. `physics_client_view/1` being local today does
   not prove the ordinary composed view will depend on just two subscriptions.
   Use actual proof dependencies through the existing owner; neither invent
   extra dependencies nor omit ones that a particular policy reads.

## Result

The corrected audit is a sound basis for replacing the speculative capability
proposal with a concrete reuse-based plan. It does not erase the demonstrated
source-to-resource and view-dependency gaps, or complete the required body
binding, admission/withdrawal and recovery design. The review's proposed
two-ontology gravity/permission fixture is useful as part of that plan, but
cannot substitute for real remote propagation and signed personal-lobby
acceptance. No production changes or new test runs were made for this review.
