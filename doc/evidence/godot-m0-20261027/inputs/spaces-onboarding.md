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

## New-user onboarding and parentless spaces

[Normal-user signup provisions a distinct personal agent A and an ordinary empty
space S0 for human U; S0 is the initial personal lobby, has no containing space,
and initially contains A.]{decided by="yan.guiborat" email=yan.guiborat@gmail.com on=2026-10-27 over="a dedicated lobby subclass for this delivery"} [Y](https://console.nimbalyst.com/app/cite/ed9cd520-b2a4-4607-a8f5-ff99d08f3e46/prompt/80fe5d70d8db7a67f1cc071ad91cced3 "by=yan.guiborat email=yan.guiborat@gmail.com at=2026-10-27T14:04:14.517Z quote='some points before starting :%0A- I would like to clarify new users onbording. These should only prolog if possible:%0A%2A When a normal user is created atm we will create for it a simple empty space. It will be later the user lobby %28 we will create a dedicated subclass for it %29 but for now we will use a simple space class. So I guess when registering a new user, we should create a space and an agent…'")

This is the target onboarding composition for the clean Godot/seven-foundation
delivery, not a claim that the existing physical-lobby signup implements it.
Use the existing `space` class and defaults, including its 100-metre box extent.
A dedicated user-lobby subclass is later work. S0 is a space instance, not the
root ontology, a shared lobby foundation or a new ontology per room.

Having a containing space is optional for every ordinary space. S0 is unplaced
while A is placed inside it; these are different assignments. Other spaces may
also remain unplaced. A placed instance has at most one containing space, with
independent display references still allowed. No synthetic outer space, second
parent registry, universal parent tree or inherited access rights follow.

The initial interior has a black background, with controllers visible when
available and the ordinary GUI accessible. It has no required floor, sky,
terrain, physical simulation or visible agent body. This presents an empty
ordinary space; it does not trigger rebuilding the old physical lobby.

From S0, U uses the offered GUI to instruct A to create another space S1.
Storage remains an explicitly selected existing ontology and default owner is
U; near-agent placement puts S1 inside A's current space. S1 appears there via
the ordinary default exterior Eidolon (currently the half-metre cube), whose
size is independent of its interior extent. Creating S1 does not enter it.
Authorized GUI entry moves the same A to S1; navigation follows the committed
assignment. The same creation and entry rules apply inside S1 to create S2,
and at further levels, without a separate agent, class or storage ledger per
level. The selected exterior Eidolon may display a mesh or the space's contents;
the current default cube is one recipe, not a restriction on exterior views.
If both S1 and S2 select contents exteriors, their contents are recursively
displayed in S0 as one continuous space, subject to physics and each source
owner's disclosure policy. No entry into S1 or S2 is required for that display.

```mermaid
flowchart LR
    S0["S0: initial space, no containing space"] -->|contains placed space| S1["S1: ordinary space"]
    S1 -->|contains placed space| S2["S2: ordinary space"]
```

Signup composition, ownership, initial placement, offered operations and grants
belong in Prolog. Reuse existing governed founding, key custody, actions,
construction, atomic writes and recovery; Godot renders descriptors and sends
authenticated instructions. The onboarding composition must explicitly select
and record its authorized storage after any required existing founding step;
automatic onboarding does not introduce an implicit storage default for later
Create operations. M0 specifies the exact lifecycle and permissions. Related
instance facts and admission changes forming one transition commit together;
ontology founding retains its existing lifecycle. A lost reply or restart must
recover the original U/A/S0 references, not provision replacements. Initial A
placement reuses existing placement; later same-agent travel remains entry work.

See the [space architecture plan](../nimbalyst-local/plans/space-conceptual-architecture-review.md)
for the existing Stage 1/Stage 2 boundaries, and [QUO-60](nimbalyst://QUO-60)
for delivery status. Recursive rendering/exposure and ontology predicate editing
have their own integration obligations. They must not be used to impose a
mesh-only exterior or require entry before a contents-displaying exterior works.

## Empty creation

U instructs the distinct personal agent A through the existing immediate signed
route, selecting an **existing** ontology explicitly. Compose `space.pl` into
that storage owner and A's ontology, and `space_view.pl` where space exteriors
or contents are projected. Finite dimensions use the storage owner's exact
`measure_vocabulary(Namespace, Anchor)` reference to the measurement ontology.
No automatic lobby storage selection or ontology founding occurs.

The shared assertion mechanism creates the instance. A goal inside the selected
anchored scope can return both durable outputs:

```prolog
with_build_plan([attribute(name, <<"Workshop">>)],
                assert(instance_of(space, Space))),
current_ontology_identity(Ns, Anchor),
Ref = entity_ref(Ns, Anchor, Space),
attribute(Space, name, Name).
```

The default name is `<<"Space">>`; supplied names override it. Names are stored,
mutable and nonunique. The generated ULID and anchor form the identity. Named
outputs `Ref` and `Name` use the ordinary selected-result machinery: a lost
reply is recovered from the original operation, including after restart or
later instance deletion. Recovery does not run construction again.

`dimensions` defaults to `box(q(100, <<"m">>), q(100, <<"m">>),
q(100, <<"m">>))`: X, Y and Z lengths centred on the local origin, extending
50 metres in each direction. It also accepts `infinite` or three strictly
positive exact length quantities. Existing measurement conversion validates
compatible units and rational values without floats or rounding. Malformed,
unitless, non-length, zero and negative dimensions fail construction. Supplied
quantities remain stored as supplied; interior extent does not impose a resource
budget, allocate geometry or establish collision boundaries.

The default `owner` is U, proved by A's anchored `personal_agent_owner/1` query.
An explicit owner is a construction input subject to the storage/class policy.
Ownership, storage and containing space remain independent. The bundle supplies
no invocation or class permission grants: authors admit A's exact request and
declare `create` and `space_enter` policy. The destination separately enforces
`space_admit` and its invocation policy. During a constructor, the shared guard
checks committed class policy using the scoped
`construction(Class, Id, Inputs)` subject; staged instance grants cannot supply
permission. See [construction authorization](proofs.md#class-and-instance-operation-permissions).

An optional `attribute(placement, at(DestinationRef, transform(X,Y,Z,RX,RY,RZ)))`
chooses an exact destination and exterior transform, using existing integer
millimetres/degrees. The constructor consumes this input; it stores no second
location record. Omission or explicit `near_agent` reads A's `space_location/2`. A successful
`unplaced` result creates an unplaced space; `placed(Destination, Transform)`
places it one metre along that frame's X axis from A. This is one-time placement,
not following A. A denied, unavailable, ambiguous or incomplete location read
fails creation. A placed agent needs its ordinary `attribute(Agent, transform,
Transform)`; missing pose does not prove absence. Physical-pilot entry and live
body poses remain the separate physical/entry integration.

Creation and placement use the existing assertion savepoint and `space_place/3`
transaction. Refused explicit placement rolls back the instance and all admission
writes; it never tries another destination or unplaced creation. Physical
destinations retain their mandatory physical hook and checks. Creation does not
prepare a simulation, terrain, sky or walls. The defined solid Eidolon uses a
half-metre cube independently of finite or infinite interior extent, through the
existing scene/model/rendering path. Contents remain empty. The landscape/terrain
creation route is unchanged.

Compose `space_gui.pl`, `gui_instance.pl` and `gui_operation.pl` in the storage
owner to offer **Create space** and **Create infinite space**. The existing
`gui_vocabulary/2` must pin the component vocabulary. The forms initialize name
and finite dimensions from class defaults; leaving those fields unchanged uses
the defaults, while edits supply explicit values. Finite controls accept positive
integers in mm, cm, m or km (1–1,000,000 per axis); the domain model still accepts
the wider exact measurement contract above. The placement selector supplies
`near_agent` and authored exact destinations. Storage authors may replace its
options with permitted local or foreign references. Submission returns both
`result(space, entity_ref(...))` and the committed `result(location, ...)`.
The [shared operation panel](gui-implementation-plan.md#offered-class-and-instance-operations)
displays these bindings and can open the returned subject's offered operations.
Source composition in an already founded ontology requires its existing owner
authority; installing client files does not rewrite ontology data.

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
Each owner checks its own committed memberships, ancestry and policy. A live
constructor supplies its original class and inputs through the shared assertion
scope before the new membership commits; this does not read staged grants or
weaken destination checks. Staged grants cannot authorize the current transition. Compulsory requirements from
every applicable parent survive overrides. Policy reads participate in the
existing conflict checks. Scope invocation remains separately required.

Callbacks use only local committed policy. Exact identities are already operation
inputs, so callbacks need neither the identity bridge nor a foreign scope call.
The lobby's `lobby_admission/4` supplies its local admission definitions to both
permission checks and the existing anchored physics projection. Physical
consequences retain their checks independently of default permission overrides.

## Direct depiction

[A space's exterior Eidolon may display its contents instead of a mesh.]{decided by="yan.guiborat" email=yan.guiborat@gmail.com on=2026-10-27} [Y](https://console.nimbalyst.com/app/cite/ed9cd520-b2a4-4607-a8f5-ff99d08f3e46/prompt/0ed00d8751e1d31d9ff931cbc71dfcc9 "by=yan.guiborat email=yan.guiborat@gmail.com at=2026-10-27T14:14:39.228Z quote='please remember that a space, can have an external eidolon pourposed to display its content instead of a mesh, I wish you remember taht%0A%3CNIMBALYST%5FSYSTEM%5FMESSAGE%3E%0AThe user is currently looking at this document. They are not necessarily asking you about this document, but they may be. Use your best judgement to decide if they are making a general request or asking specifically about this…'")

Exterior and interior describe viewing purposes, not fixed representation types: showing
contents does not require entering the space, moving A or changing containment.

[When S0 contains S1 containing S2, and both S1 and S2 select contents exteriors,
their contents are displayed recursively in S0, subject to physics, as if all
were one space.]{decided by="yan.guiborat" email=yan.guiborat@gmail.com on=2026-10-27} [Y](https://console.nimbalyst.com/app/cite/ed9cd520-b2a4-4607-a8f5-ff99d08f3e46/prompt/34b88d269f157c7d9f9af331466e44d4 "by=yan.guiborat email=yan.guiborat@gmail.com at=2026-10-27T14:18:41.935Z quote='of course I wish it isn%27t necesseray to say that if S0 include S1 that include S2, if S1 and S2 are set to show their content eidolon, then all contents are recursively displayed into S0, subject to physics, as if al this would be a single space'")

This is required composition, not an optional later visual effect. Apply it at
each level selecting a contents exterior, composing relative transforms through
the existing view owners. A mesh exterior selects that mesh representation;
there is no artificial one-level display limit for contents exteriors. Preserve
exact subjects, disclosure/revocation, cycle handling and Prolog-governed
resources. Physical behavior must agree with the composed scene through the
existing authoritative physics owners; rendering alone does not establish that
agreement. Visual composition does not merge identities, storage or grants.
The cube described under Empty creation is the installed solid recipe, not a
restriction on authored exterior forms.

The [current physics profile](physics-native.md#installation-and-policy) uses
separate actors for independently enabled spaces and does not establish shared
physics for recursive contents composition. M0 must specify the required frame,
binding and physical-interaction contract against the existing owners, naming
any demonstrated adapter gap. M3 acceptance must exercise the recursive S0/S1/S2
scene and applicable physical behavior, not only meshes or successive entry.
Empty ordinary spaces still allocate no physics solely because they are spaces;
the target does not waive existing admission, custody or transfer guarantees.

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
Creation destination selection uses the constructor and source-owned transform
described under [Empty creation](#empty-creation). During construction, placement
checks committed class policy through the shared construction scope; existing
instances use committed instance policy. Same-agent entry and recursive views
remain separate work.
General transfer between independent simulations is outside this slice: atomic
membership delete/add is insufficient and provides no authority-transfer claim.

The production-owner tests are [quod_space_tests.erl](../test/quod_space_tests.erl).
They use non-lobby identities and signed requests, including distinct principals,
competing prepared proofs, rollback, replay and exact operation resolution.
Physics resource selection is present during the no-allocation checks. The
simulated integration is exercised through production owners in
[quod_physics_tests.erl](../test/quod_physics_tests.erl).
