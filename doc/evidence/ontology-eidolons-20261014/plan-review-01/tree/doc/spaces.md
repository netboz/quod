# Governed spaces

A **space** organizes instances or information. A **physical_space** is a
space with explicitly governed physical participation. Neither is an ontology:
an ontology owns code, committed facts, authorization and history. An ontology
can be depicted or edited in 3D without acquiring space semantics. An instance
can carry both roles only through explicit authored membership and policy.

[space.pl](../priv/ontologies/space.pl) is composable domain source, like
[fipa_request.pl](../priv/ontologies/fipa_request.pl). Compose it into the
ontologies owning the affected facts through ordinary founding or authorized
source editing. It is not an automatically founded system ontology. Existing
histories, native capability manifests and deployment authority are unchanged.

## Classes and dispatch

The vocabulary declares `isa(space, thing)` and
`isa(physical_space, space)`. Shared `isa/2` rules compute reflexive/transitive
ancestry, including authored multiple inheritance. `instance_of(Class, Entity)`
is class-first, remains authored, and does not itself expand ancestry.
`space_instance(Entity, Class)` explicitly combines membership with ancestry.
Neither declaration imports behavior or grants invocation rights. The existing
lobby likewise explicitly expands its device classes before recipe selection.
This vocabulary does not change lobby classes or ontology-instance reflection.

An `entity_ref(Namespace, GenesisAnchor, Entity)` refers to an existing entity
in its owning ontology. It is a reference term, not a new object registry or
class. The owner establishes class or instance identity using existing `isa/2`
and `instance_of/2`. Every cross-owner call checks the exact history. Moving
membership changes neither the entity reference, code, ACL nor history.

## Relations and owners

| Relation | Sole owner | Assertion |
| --- | --- | --- |
| `space_member(Space, EntityRef)` | Space ontology | Organizational membership, possibly many-to-many |
| `physical_assignment(Entity, Revision, DestinationRef)` | Entity ontology | Exclusive admission assignment, or `none` after withdrawal |
| `space_placement(Space, EntityRef, Revision)` | Space ontology | Physical admission corresponding to that assignment revision |
| `space_contains(Space, EntityRef)` | Derived query at space ontology | Either organizational membership or physical admission |

The two physical facts express the entity's exclusive assignment and the
space's admission. They contain no duplicate pose, body, code or geometry.
Their transition is one existing atomic transaction. Assignment absence means
revision zero and `none`; after first use the empty slot retains its revision,
so withdrawal cannot let an obsolete admission reuse revision zero. Multiple
assignment rows are invalid configuration and fail explicitly.

Organizational members may be classes, ordinary instances or other spaces.
Containment is a direct graph relation: it does not flatten descendants,
propagate access rights, infer parent transforms or imply physical presence.
Self-containment and self-placement are refused. Longer organizational or
physical admission cycles need explicit domain constraints where inappropriate;
the relation does not claim a physical frame tree. Class membership and
containment alone do not establish a depicted occurrence. Existing lenses,
Eidolons and anchored `depicts/3` marks remain the representation path.
A local view layout is transient presentation, requiring no domain transaction.
Persisting a domain membership or changing authored physical location requires
an authorized action. Hot controls retain their existing transient path.

## Governed transitions

`space_contain(Space, EntityRef)` executes at the destination. It requires
`can_admit_space_member(Space, Principal, EntityRef, organizational)` there
and `can_enter_space(Entity, Principal, DestinationRef, organizational)` at
the entity owner. Only the destination writes. `space_remove/2` removes that
organizational fact when destination policy allows removal or the entity owner
allows withdrawal through `can_leave_space/4`. Removing physical admission
does not remove independent organizational membership.

`space_place(Entity, ExpectedRevision, DestinationRef)` executes at the entity
owner. It requires its physical `can_enter_space/4` delegation, an empty slot
at the expected revision, and the destination's physical admission policy.
It stages the next assignment and calls `space_accept_placement/3`, which
checks `physical_space` membership and reads the staged assignment back through
the existing re-entrant proof scope before admitting the entity. Two completed
proofs from the same empty slot conflict at this one assignment owner; unchanged
read-only consent cannot authorize two exclusive admissions. The current slice
supports exclusive physical admission only, not multiple embodiments.

`space_withdraw(Entity, ExpectedRevision, DestinationRef)` is the common entry
for instance withdrawal and destination revocation. It stages the next empty
assignment and calls `space_release_placement/4`. Destination policy must allow
removal, or the instance owner must allow that principal to leave. The callback
checks the new empty slot, performs the domain lifecycle consequence and removes
the exact old admission. Both owners commit together or neither changes.
Changing a future-entry grant alone does not revoke existing membership; compose
that policy edit with the withdrawal/removal action when immediate revocation is
required. Neither a missing owner nor a timeout authorizes unilateral release.
If either required ontology is unavailable, this transition remains unavailable;
there is no offline eviction or invented successful withdrawal.

Participant entries cannot create or release a slot. Invoking them alone in a
valid committed state fails: admission lacks a matching new assignment or
already exists; release lacks the next empty assignment. Failed candidates use
ordinary transaction savepoints. No handoff process, transfer ledger or second
executor is introduced.

## Invocation policy

The bundle installs no `can_invoke/4` clauses. Entry ACLs and domain grants are
separate requirements. The authenticated principal is unchanged through `::`;
calling from a space does not impersonate the entity owner. Expose only exact
needed shapes, with appropriate principals and authenticated call paths:

| Owning scope | Shapes required by the composition |
| --- | --- |
| Space | Public `space_contain/2`, `space_remove/2`; anchored `space_accept_placement/3`, `space_release_placement/4` for admitted callers |
| Entity | Public `space_place/3`, `space_withdraw/3`; anchored `space_consent/4`, `space_withdrawal_consent/4`, `space_assignment/3` |
| Caller whose operation enters another scope | The exact outer `Namespace::Goal` request permitted by its own entry policy |

An anchored shape is `(current_ontology_identity(Namespace, Anchor), Goal)`.
A curator evicting an entity needs the entity owner's invocation grant for
`space_withdraw/3` as well as the space's removal policy. Otherwise it is denied
even if that curator may edit the space. Conversely, a publisher's delegation
does not grant destination invocation or admission. Read disclosure remains
subject to the owning scope's policy. Helpers, raw assertions/retractions and
lifecycle callbacks are not end-user entries. An unrestricted administrative
ACL already authorizes arbitrary source/state editing and is not constrained
by these domain actions. Revision/configuration conflicts return reasoned
failures; ordinary false policy remains ordinary Prolog failure.

## Optional physical integration and recovery

`space_physical_change(Space, EntityRef, admitted|withdrawn)` is a required
authored consequence inside the destination's transaction, with no default
success. Missing or refused composition rolls back both owners. An unsimulated
physical space explicitly supplies a no-effect rule; class membership does not
supply it. Unsimulated physical admission allocates no native body and does not
prove physically fulfilled placement.

The [native physics composition](physics-native.md#live-definitions-and-atomic-admission)
supplies `physics_space_change/3` for simulated membership. Its live binding
names the exact source entity, assignment and definition revisions; the
destination owns body identity and placement. Admission, definition edits and
withdrawal compose their source and receiver changes in the same transaction.
Unsupported constraint groups, agent bindings or unresolved original physical
operations refuse removal. Live collider dependencies advance through existing
subscriptions and retained verified projections; this vocabulary supplies no
alternate update mechanism. Several rooms may share one
simulation domain. There is no class-level one-ontology or one-simulator-per-room
rule. The current physics adapter's narrower limits remain explicit integration
constraints, not class semantics.

Commit records governed admission/removal. Runtime installation is a separate
owner notification, and physically fulfilled placement requires the applicable
authenticated observation transition. Neither `space_contains/2` nor a commit
receipt proves that an object physically arrived. Enablement, hosting, body
admission, observation/control and budgets remain separate Prolog policies.

After restart the existing ontology owners recover their committed slot and
admission facts and complete existing atomic obligations. They do not replay
historical reactions or manufacture new placement operations. A caller retaining
an uncertain signed request resolves that exact operation through existing
outcome resolution; absence or timeout is not rejection and must not trigger a
fresh admission/withdrawal. Physical recovery additionally obeys current run
fences, compatible checkpoints and custody described in [world.md](world.md).
General transfer between independent simulations is outside this slice: atomic
membership delete/add is insufficient and provides no authority-transfer claim.

The production-owner tests are [quod_space_tests.erl](../test/quod_space_tests.erl).
They use non-lobby identities and signed requests, including distinct principals,
competing prepared proofs, rollback, replay and exact operation resolution.
Physics resource selection is present during the no-allocation checks. The
simulated integration is exercised through production owners in
[quod_physics_tests.erl](../test/quod_physics_tests.erl).
