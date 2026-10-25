# Governed spaces

A **space** contains placed instances and can display references to other
instances or information. A **physical_space** adds explicitly governed physical
participation. Location and display membership are independent of ontology
membership: an ontology owns code, committed facts, authorization and history.
An ontology can be depicted or edited in 3D without acquiring space semantics.
An instance can carry both roles only through explicit authored membership and policy.

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
| `space_member(Space, EntityRef)` | Space ontology | Independent display reference, possibly many-to-many |
| `space_assignment_state(Entity, Revision, DestinationRef)` | Entity ontology | Exclusive admission assignment, or `none` after withdrawal |
| `space_placement(Space, EntityRef, Revision)` | Space ontology | Admission corresponding to that assignment revision |
| `space_contains(Space, EntityRef)` | Derived query at space ontology | Direct view subjects: display references or placed instances |

The assignment and placement facts express the entity's exclusive assignment
and the space's admission. They contain no duplicate pose, body, code or geometry.
Their transition is one existing atomic transaction. Assignment absence means
revision zero and `none`; after first use the empty slot retains its revision,
so withdrawal cannot let an obsolete admission reuse revision zero. Multiple
assignment rows are invalid configuration and fail explicitly.

Display members may be classes, ordinary instances or other spaces. Removing
a display reference deletes neither the instance nor its assignment, stored
state or ownership. A placed instance has one containing space; it can still
appear in several spaces through independent references. The view-subject query
`space_contains/2` is a direct graph relation: it does not flatten descendants,
propagate access rights, infer parent transforms or imply physical presence.
Self-containment and self-placement are refused. Longer display or
placement cycles need explicit domain constraints where inappropriate;
the relation does not claim a physical frame tree. Class membership and
containment alone do not establish a depicted occurrence. Existing lenses,
Eidolons and anchored `depicts/3` marks remain the representation path.
A local view layout is transient presentation, requiring no domain transaction.
Persisting a display reference or changing containing-space assignment requires
an authorized action. Hot controls retain their existing transient path.

## Governed transitions

`space_contain(Space, EntityRef)` executes at the destination and checks both
owners' committed operation policy in `display` mode. Only the destination
writes `space_member/2`. `space_remove/2` removes that reference when destination
policy allows removal or the entity owner allows withdrawal. Display grants
provide no placement, disclosure or ownership authority.

`space_place(Entity, ExpectedRevision, DestinationRef)` executes at the entity
owner. It checks that owner's `space_enter` permission in `placement` mode,
an empty slot at the expected revision and the destination's `space_admit`
permission. It stages the next assignment and calls `space_accept_placement/3`,
which checks `space` membership and reads the staged assignment back through
the existing re-entrant proof scope before admitting the entity. This supports
ordinary and physical spaces, in the same ontology or different ontologies.
Two completed proofs from the same empty slot conflict at the single assignment
owner. Refusal, stale revision and conflict leave no partial assignment.

`space_withdraw(Entity, ExpectedRevision, DestinationRef)` is the common entry
for instance withdrawal and destination revocation. It stages the next empty
assignment and calls `space_release_placement/4`. Destination policy must allow
removal, or the instance owner must allow that principal to leave. The callback
checks the new empty slot, performs any required physical consequence and removes
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
failures; denied operation policy remains ordinary Prolog failure.

## Shared operation authorization

All four permissions use [the shared committed guard](proofs.md#class-and-instance-operation-permissions).
The operation inputs are `space_enter(SourceRef, DestinationRef, Mode)`,
`space_leave(SourceRef, DestinationRef, Mode)`,
`space_admit(DestinationRef, SourceRef, Mode)` and
`space_remove(DestinationRef, SourceRef, Mode)`. `Mode` is `placement` or
`display`. The executing owner supplies its own exact reference; the other
reference comes from the requested transition. Placement requires instance
subjects; display consent also accepts class subjects.

Authors declare `class_permission/3`, `class_requirement/3` and governed
`instance_permission/3` overrides. The bundle grants no default permission.
Each owner checks its own committed memberships, ancestry and policy; staged
grants cannot authorize the current transition. Compulsory requirements from
every applicable parent survive overrides. Policy reads participate in the
existing conflict checks. Scope invocation remains separately required.

Callbacks use only local committed policy. Exact identities are already operation
inputs, so callbacks need neither the identity bridge nor a foreign scope call.
The lobby's `lobby_admission/4` supplies its local admission definitions to both
permission checks and the existing anchored physics projection. Physical
consequences retain their checks independently of default permission overrides.

## Direct depiction

The existing `space_view.pl` projects the union of placement and display
references, deduplicating each exact subject within that view. It asks the source
owner for `entity_scene/3` and uses the existing Eidolon, `place_model/5`, local
`transform/6` and anchored `depicts/3` contracts. Ordinary placement uses the
scene's local transform. Display references use that same presentation path;
no domain facts, ownership or storage move to the viewing space.

Physical placement still requires one matching live body definition and uses
its `body_pose/2`. Missing or ambiguous physical bindings do not fall back to a
decorative transform. Retained client views keep their existing dependencies,
renewal and installed-change notification lifecycle. Unchanged projections
allocate no physics resources and require no history replay or projection rebuild.
A committed source update refreshes each subscribed display through those owners.

## Optional physical integration and recovery

`space_physical_change(Space, EntityRef, admitted|withdrawn)` is required for
a physical destination inside the same transaction, with no default success.
An ordinary destination skips the physical hook and allocates no physics
resources. Withdrawal still releases an existing live physical binding after
the destination is reclassified or loses its space membership. That binding
remains the physical owner's cleanup obligation; missing or refused composition
rolls back both owners. An unsimulated physical space explicitly supplies a
no-effect rule; class membership does not
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
Creation destination selection (explicit, near-agent or unplaced), same-agent
entry and recursive views are separate work. Placement here requires an existing
committed instance. Creation-time consent must use committed class policy, and
near-agent placement must choose a pose owner; those are S1.7 integration work.
General transfer between independent simulations is outside this slice: atomic
membership delete/add is insufficient and provides no authority-transfer claim.

The production-owner tests are [quod_space_tests.erl](../test/quod_space_tests.erl).
They use non-lobby identities and signed requests, including distinct principals,
competing prepared proofs, rollback, replay and exact operation resolution.
Physics resource selection is present during the no-allocation checks. The
simulated integration is exercised through production owners in
[quod_physics_tests.erl](../test/quod_physics_tests.erl).
