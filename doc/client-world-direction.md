# Quod client and world runtime -- architectural direction

**Status:** the browser key, login, signed local and multi-ontology goals,
cursor, unresolved-operation journal, retired user-home generation, and
Explorer-console foundation are implemented and deployed. The world, agent, presentation,
and simulation sections remain direction except for the initial lobby/toolkit
contracts recorded in section 11.8; remaining proposals must be revalidated
before implementation.

The generic acting identity is now the deployed actor model in
`ontology-actor-architecture.md`: every acting node, agent, service, or
human-facing user is a classed instance in an exact ontology history; `agent`
is the generic acting class and `human_user` is its explicit human-specific
subclass. This correction reuses the one signed-goal path described here
rather than adding a world/client identity path.

This document records the intended architecture for client projection,
renderer-neutral model ontologies, GUI, client profiles, visual cues, hot
simulation, and editable voxel worlds. It is deliberately separate from
`doc/agent-fipa-plan.md`: none of this should expand or delay the immediate
agent/runtime substrate work.

The presentation-ontology, asynchronous-GUI, contextual-action-menu, client
profile, and semantic-theme directions below were revalidated with Yan on
2026-08-10. Predicate, module, and wire names remain illustrative until their
implementation slices are reviewed.

The signed-client work now supplies the transitional key identity and signed goal path
through local and remote ontology scopes. The remaining world-runtime direction
depends on the agent plan for immutable delegated subjects, hosted agents,
wielding, post-apply events, runtime reconciliation, and owner-gated effects.
Details here are expected to evolve after those pieces exist and can be
measured.

The concrete browser-key, open user-home creation, challenge, session, and
key-provider direction is recorded in `doc/client-authentication-plan.md`.

This direction already constrains the substrate in four ways:

- ordered runtime handlers must remain thin and enqueue heavy work;
- QUIC stream priorities must protect consensus before bulk consumers arrive;
- transaction throughput and latency are eventual gameplay budgets for edits;
- physics needs a native engine boundary, even though transport remains pure
  Erlang.

The useful predecessor ideas are:

- Onia's shared scene graph with per-agent perception filters;
- Onia's separate modality (3D/sensory) and view (structured GUI/data) bearers;
- Onia's snapshot-on-connect plus atomic incremental-delta client model;
- BBSvx's pure-data effect descriptors with inherited presentation defaults;
- BBSvx's owner/ghost physics authority;
- BBSvx's deterministic voxel generation from a compact seed.

The following predecessor choices are rejected:

- a generic effect dispatcher that invokes compiled code by descriptor functor;
- treating an unknown descriptor as implicitly safe client data;
- unsigned or unbounded client goals executed outside the ordinary proof and
  ACL path;
- committing generated blocks or per-frame transforms;
- one undifferentiated stream for scene state, GUI, physics, and visual cues.

A helper shortcut does not grant authority. A client may submit a signed,
bounded Prolog goal directly, or construct the same goal from a stable helper
description. Both enter the same ontology proof and ACL path described in
`doc/signed-client-goals-plan.md`.

## 1. Directional invariants

1. **No KB copies.** Client and world projections use shared MVCC snapshot
   handles and indexed P-state.
2. **Delivery semantics are explicit.** Rebuildable state, expiring cues, and
   hot frames use different channels.
3. **Reconnect means current state.** A missed state delta is repaired by a
   snapshot; disconnected transient cues are not replayed.
4. **One shared scene index.** Per-agent visibility filters a shared world index;
   it does not copy visible facts into agent KBs or build a full scene per agent.
5. **Hot simulation stays out of consensus.** Per-frame transforms are lossy
   authority state.
6. **Voxel edits are shared truth.** The procedural base is immutable; digging,
   building, and terrain-changing explosions are ordered durable overlays.
7. **Clients execute declared presentation data only.** Descriptor schemas,
   assets, payloads, and resource costs are validated and bounded.
8. **Presentation meaning is renderer-neutral.** Ontologies describe geometry,
  composition, GUI, and interaction semantics; a Babylon.js 9.18.1/WebXR adapter renders
   that vocabulary for the first client.
9. **Composition is the default.** Complex models reuse governed components;
   the server resolves their authorized attachment graph into one bounded scene
   projection.
10. **Human interaction never suspends a proof.** Draft input is client/session
   P-state. Submission starts a bounded transaction; a long wait is represented
   by durable correlated state and resumed by a later transaction.
11. **Profiles describe capabilities, not product names.** The same projected
    scene and interaction semantics adapt to immersive XR, tracked controllers,
    hand tracking, gamepads, keyboard/mouse, and flat displays.

## 2. D, P, and E for worlds

The agent plan's D/P/E categories remain sufficient. Hot simulation is a
specialized P/E profile, not a fourth external-predicate class.

Durable D facts describe:

- world identity, generator type and exact version, and deterministic seed;
- standard model/UI declarations, entity identity, model/material references,
  baseline transform, collision shape, component attachment, and simulation
  parameters;
- presentation policies, class associations, reusable lens definitions, and
  authored shared appearance;
- current logical simulation authority and monotonically increasing epoch;
- structured GUI component trees, durable pending interactions, private menu
  entries/preferences governed by the containing ontology's ACL;
- sparse voxel edits and semantic checkpoints.

Rebuildable P contains:

- shared scene and spatial indexes;
- filtered per-agent client view sessions;
- derived presentation descriptors and client model/GUI indexes;
- projected contextual menus, selected presentation purposes, session device
  capabilities, and unsubmitted GUI/VR editing drafts;
- simulation processes, bodies, ghosts, and colliders;
- generated voxel chunks, overlays, meshes, and caches.

E contains:

- socket and datagram writes;
- authenticated client input;
- expiring visual, sound, and GUI cues;
- hot control commands sent to a simulation authority.

An authority change is a durable action. The new authority rebuilds from the
latest durable checkpoint and current world facts before publishing a higher
epoch. Old-epoch commands and frames are rejected.

The ordered namespace handler tier only updates small indexes and enqueues
idempotent resource jobs. Scene elaboration, meshing, collider construction,
asset processing, and simulation stepping run in queue-fed workers outside that
tier. A dependent output waits for its resource revision; unrelated namespace
events do not.

## 2.1 Client endpoint and global release

Every Quod node may expose a separate client HTTPS service on port **14570**.
It is distinct from P2P (`14567`), metrics (`14568`), and the operational
Explorer (`14569`).  A browser or XR headset may load the client from any
healthy node and establish its authenticated session with that node; the node
then obtains the authorized world projection through normal Quod mechanisms.

The endpoint serves a small audited bootstrap and immutable, content-addressed
client bundles.  It is not an Explorer alias and does not expose arbitrary
`prove` or administrative endpoints.  Authentication belongs to the later
client-session protocol, not to the first static-file request.

A governed client-release declaration may be durable ontology data, for
example conceptually:

```prolog
client_release(ReleaseId, ProtocolRange, BootstrapHash, BundleHash,
               ManifestHash, ActivatedAt).
```

The declaration records which immutable release is active.  It does **not**
make JavaScript, shaders, or renderer plug-ins executable ontology rules.  A
node/browser obtains bundle bytes by hash, checks their bounded manifest,
integrity and protocol compatibility, and only then lets the audited bootstrap
load them.  An owner-governed ordinary transition activates a new release;
nodes may retain the preceding verified release during rollout so reconnecting
clients do not receive a half-updated application.

This separates two useful forms of global update:

- Ontology data may change declared screens, scene descriptors, menu entries,
  icons, preferences, and the active release manifest.
- Executable client bytes remain immutable signed/content-addressed assets with
  an explicit compatibility contract.  There is no `eval`, URL fetch, or
  arbitrary code path derived from a domain ontology.

The implemented local-client slice establishes the dedicated TLS endpoint,
node-bound Ed25519 challenge-response, short-lived node-local sessions, and one
signed-goal API for reads, writes, and cursors. Agent enrollment uses generic
root-owned `create_ontology/3` plus ordinary class, key, and ACL facts; the
specialized `create_user_home` workflow is deleted. The interactive Explorer console uses that same
login and API; the standalone Explorer listener is read-only. The same signed
request and stable agent principal now cross remote and nested ontology scopes through
the ordinary scope/DTX path. Any-node HTTP ingress forwarding, bundle
distribution, and governed release activation remain separate bounded
protocols; none is implied by loading the client or holding a session.

## 3. Client envelope families

The internal `ontology_event/7` from the agent plan is not a client protocol.
Client projection derives typed envelopes:

```text
state_snapshot(ViewSessionId, Namespace, Height, State)
state_delta(ViewSessionId, Namespace, Height, TransactionId, Operations)
simulation_frame(WorldId, AuthorityEpoch, Tick, StateDelta)
client_cue(EffectId, Origin, Deadline, Audience, Descriptor)
```

State covers scene entities, model instances, durable transforms, structured
views, and GUI trees. Snapshots are current-state D reads filtered through P.
Deltas atomically project one committed transaction. Connect, reconnect, owner
failover, or a sequence gap causes a fresh snapshot.

Simulation frames are latest-wins datagrams. They may be dropped or coalesced
without blocking consensus, Prolog apply, reliable client state, GUI traffic, or
ACL.

Client cues are one-shot presentation events such as explosions, particles,
sounds, highlights, camera shake, and toasts. `Origin` is either a committed
transaction identity or `{WorldId, AuthorityEpoch, Tick}`. Cues expire and are
not part of reconnect snapshots.

## 4. Scene and view projection

Illustrative scene vocabulary (authored declarations may be durable; derived
descriptors and client view sessions are P-state):

```prolog
world(WorldId, WorldClass, GeneratorVersion, Seed).
scene_entity(EntityId, WorldId).
depicts(VisualId, EntityRef).
model(VisualId, ModelDescriptor).
transform(VisualId, Transform).
attached(ChildId, ParentId, Socket, LocalTransform).
gui_component(ViewId, ComponentId, Kind).
gui_attribute(ViewId, ComponentId, Name, Value).
client_view_session(AgentId, Source, ViewType).
```

`client_view_session/3` names session-local P-state for one connected client.
It is deliberately distinct from the durable ontology-to-ontology
`subscribes/2` relation in `ontology-subscription-plan.md`. A client view may
consume an ontology projection, but its visibility window, reconnect cursor,
and queue are not committed ontology subscriptions.

The exact vocabulary belongs to future `quod:world` and `quod:client`
ontologies, not hard-coded Erlang dispatch.

Projected model/transform descriptors address rendered occurrences (section 4.3).
Authored domain appearance and placement are their inputs; entity references,
eidolon recipe identities and visual occurrence IDs are distinct. A visual
transform does not replace authoritative domain placement or physical attachment.

Asset references are content-addressed and policy checked. Ontology content
cannot cause clients to fetch arbitrary executable code or untrusted URLs.

### 4.1 Presentation ontologies

Quod should provide a small governed family of reusable presentation
ontologies. They define renderer-neutral model classes and bounded descriptor
schemas; they do not reproduce Babylon's JavaScript API in Prolog. The initial
family should cover:

- primitives such as spheres, boxes, planes, cylinders, and other bounded
  parameterized geometry;
- content-addressed mesh assets, with glTF/GLB as the preferred interchange
  format and additional audited import formats added through versioned schemas;
- heightfields, procedural terrain, and voxel surfaces;
- materials, textures, lights, cameras, and scene transforms;
- skeleton, animation, and morph references where the selected client supports
  them.

These are reusable ontology concepts, not a requirement to found one consensus
namespace for every primitive or widget. A domain ontology may use them to say
that an entity is a sphere, a rigged mesh, a heightfield, or a composite model.
Babylon/WebXR is the first rendering adapter; another client may map the same
descriptors to a different engine without changing durable domain truth.

Large meshes, textures, heightfields, audio, and video remain content-addressed
data. An ontology carries their identity, type, integrity hash, metadata, and
policy—not their unbounded bytes. Fetch, decoding, and resource limits are
validated outside consensus before a client resource becomes usable.

Presentation knowledge is also ontology content: classes and entities may
reference several reusable presentations for different purposes, and one
presentation may serve several classes. References identify the exact anchored
ontology. They are presentation associations, distinct from physical
`attached/4` relationships. Neither association requires a new namespace per
class, presentation, or visual primitive.

A lens selects subjects, properties, relations, grouping, measures, and detail
for a purpose. Its visual encoding selects eidolon recipes, scales, layout, and
interaction bindings. Shared layout algorithms produce bounded renderer-neutral
descriptors from these declarations; the client adapter realizes them. Both
authored appearances and appearances derived from class/attribute rules enter
the same projection path. For example, a licence overview can group by family
and encode ordinal reach as height; a naming lens can compare pool capacities
or explain selection probabilities. These are distinct questions over the
same domain, not an intrinsic shape assigned to every predicate.

Encodings require explicit semantic preconditions: entity identity, value
cardinality, ordinal versus quantitative scales, missing-value meaning, and
aggregation rules. An integer type alone does not establish a quantitative
measure; `attribute/3` need not be single-valued. Tree layouts must not silently
discard additional parents, and multiple memberships must remain represented.
An incompatible encoding yields a bounded diagnostic or a policy-declared
alternative. Begin with authored lenses and reusable encodings; automatic
selection may later rank compatible encodings without inventing domain meaning.

### 4.1.1 Modelling and edition toolkit

Eidolon authors should have convenience predicates for building and arranging
models, rather than hand-writing every descriptor. The toolkit expresses common
3D concepts; Babylon's API is a capability reference, not the ontology API.
The same recipes must remain meaningful to a future Unreal or other adapter.

| Area | Shared modelling concepts |
| --- | --- |
| Geometry | Plane, box, sphere, cylinder; later curves, extrusion, lathe and imported meshes |
| Composition | Named parts, groups, local transforms, pivots and reusable subrecipes |
| Arrangement | Named anchors/faces, alignment, spacing, repetition and distribution |
| Surfaces | Reusable materials, texture slots, UV coordinates, tiling and sampling |
| Motion | Rig/bone references, animation clips, blending and morph targets |
| Effects | Particle emitters, emission shape/rate, lifetime and appearance |
| Scene | Lights and camera descriptions, subject to the viewer's profile |

This is the vocabulary's direction, not a requirement to implement every row
before the lobby. Begin with its actual consumer: a console body, a screen,
their placement, reusable materials and a GUI surface. Extend the same model
for subsequent consumers rather than creating a second advanced-model path.

An authoring predicate computes model data. It does not create a Babylon object,
assert each generated shape into the ontology, or issue rendering side effects
during proof/backtracking. Authored recipes and their accepted parameters are
ontology content; evaluated descriptions are derived presentation state.
Shared recipes and assets may be reused, while each placed occurrence has its
own stable identity and transform. A graphical editor manipulates a local
parameter draft, previews through the same descriptor schema, then submits
accepted changes through the existing authorized action/transaction path.

Alignment needs a precise meaning: which anchor or face of each part, in which
coordinate frame, with what gap and orientation. For example, place the screen's
back anchor against the console body's front anchor with a small outward offset.
The helper derives a local transform from declared geometry or asset metadata;
it must not depend on measuring Babylon's rendered result. Re-evaluation after
an input change recomputes the arrangement. This is not a physical joint or a
continuous collision/constraint solver. Cyclic layout dependencies are invalid.

A material describes how a surface responds to light. A texture supplies image
or other sampled data to one of that material's properties. Prefer the glTF
metallic/roughness material model as the common baseline: base colour, metallic
factor, roughness, normal, occlusion and emission, with explicit opacity mode.
Texture references include their semantic slot, colour-space interpretation,
UV set and sampling/tiling rules. Do not expose Babylon class names or shader
source as the material contract. Advanced surface features require a declared
capability and an authored alternative or a visible unsupported-feature result;
clients must not silently substitute a different meaning.

The descriptor contract must also specify axes/handedness, transform order,
units, numeric precision and normal-map conventions. The current prototype
uses integer millimetres and whole degrees; this direction does not silently
change that format. Asset units and engine coordinates are converted at the
adapter boundary under the eventual versioned contract. Compatible clients
preserve geometry and surface meaning, not necessarily pixel-identical lighting.

Particle recipes describe an emitter, not one ontology fact per particle.
The client advances cosmetic particles and evaluates skeletal animation between
authoritative updates. Particle collisions or visual bones do not establish
domain damage, physical attachment or other authoritative consequences.
Procedural geometry, asset sizes and emitter costs need declared resource
budgets; CPU versus GPU implementation remains an adapter choice.

References for the capability vocabulary: Babylon's
[standard shapes](https://doc.babylonjs.com/features/featuresDeepDive/mesh/creation/set),
[parametric shapes](https://doc.babylonjs.com/features/featuresDeepDive/mesh/creation/param),
[PBR materials](https://doc.babylonjs.com/features/featuresDeepDive/materials/using/masterPBR),
[particles](https://doc.babylonjs.com/features/featuresDeepDive/particles/particle_system/particle_system_intro)
and the [glTF specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html).

### 4.2 Composition and attachment

Presentation is compositional. A character may use body, arm, equipment, and
animation ontologies; a table may use a top and four legs; a world may combine
terrain and independently governed objects. The parent owns the semantic
relationship and the child owns its reusable presentation. A private component
ontology need not be advertised by the network directory: authorized parents
may address it through their known route.

The current relationship is durable state, for example:

```prolog
attached(Child, Parent, Socket, LocalTransform).

action(attach(Child, Parent, Socket, LocalTransform),
       [component(Child), compatible(Child, Parent, Socket)],
       attached(Child, Parent, Socket, LocalTransform)).
```

A caller asks for `goal(attached(...))`. If that desired state already holds,
no transition runs; otherwise any declared action capable of reaching the same
state may be tried under the action semantics in `doc/agent-fipa-plan.md`.
Static genesis composition may assert `attached/4` directly. Per-frame bone,
joint, or animation transforms remain hot P-state unless a domain explicitly
commits a semantic checkpoint.

Projection resolves the authorized component graph server-side and sends a
bounded scene tree. A client does not crawl arbitrary ontologies, discover
private children, or interpret arbitrary predicates.

Server P maintains one scene/spatial index per hosted world and applies each
wielded agent's sight/view policy:

- modality streams target 3D and sensory rendering;
- view streams target GUI, table, log, and editor rendering;
- no connected client means no envelope construction;
- reconnect starts from current state, not presentation-event replay.

Keep two responsibilities distinct: a scene graph composes parts through
parent/local transforms; a spatial index finds nearby or potentially visible
objects. The client engine already supplies the rendered transform hierarchy.
The server index supports perception selection and does not become another
domain knowledge base; geometric candidates still pass the ontology's access
and perception policies. Onia's projection design proposes an initial Erlang/ETS
implementation and later measurement of rstar or Parry for spatial indexing.
Treat these as candidates, not an existing integrated Quod library or a
prerequisite for drawing the first lobby. Any native acceleration belongs
behind the same projection owner and governed external-predicate boundary.

Creating a model instance or GUI widget is the idempotent client result of
applying projected state, not a one-shot reaction. Stable entity references
identify domain subjects; stable visual occurrence and GUI component IDs drive
client create, update, and remove.

### 4.3 Presentation selection and visual identity

An **eidolon** is a reusable representation recipe defined in ontology rules.
A class may offer playing, edition, inspection or other eidolons. Applying a
selected recipe to a concrete instance produces its visual description in a
view. The recipe and the rendered occurrence are distinct: the term eidolon
names the recipe, not a mesh, occurrence ID or client object.

For example, a Prolog-console class can offer a playing eidolon composed from a
box body, a screen plane and textures, and an edition eidolon exposing its
structure and adjustable properties. Illustrative class associations are:

```prolog
class_eidolon(prolog_console, playing, console_playing).
class_eidolon(prolog_console, edition, console_edition).
```

Recipes use renderer-neutral primitive predicates/descriptors: box, sphere,
plane, cylinder, transforms, materials and textures first; mesh assets, bones,
skeletons, joints and animation bindings as the vocabulary grows. Rendering
bones and joints do not by themselves establish physical bodies or constraints.
The client reads the resulting bounded descriptions and realizes the supported
primitives. It does not execute arbitrary ontology code or a Babylon API encoded
as Prolog. Exact primitive signatures and recipe evaluation remain to be defined.

A lens selects the subjects and relevant data for a purpose; an eidolon supplies
the representation recipe. A simple object presentation need not invent a
separate data-analysis lens just to render one instance. Both reuse the same
projection and authorization path.

The current `mark/7` prototype in `quod:present` describes output occurrences,
not recipes. It must not simply be renamed to `eidolon/7`: implementation
vocabulary will be revised after the recipe/output contract is settled.
Presentation also covers sound; its relation to action progress is deferred in
section 4.5.

The world/application ontology owns presentation selection policy. Class
ontologies supply reusable defaults; entities supply particular appearance and
equipment; a view session supplies its purpose, requested presentation, and
device capabilities. Policy determines which combinations and overrides are
permitted. Class specificity alone is insufficient when several inherited
presentations match: precedence must be explicit, with unresolved ambiguity
reported rather than resolved by incidental enumeration order. Capability
alternatives remain subject to the same policy and authorization checks.

Illustrative relationships, whose exact predicates remain subject to review:

```prolog
presentation_policy(enchanted_forest, fantasy_realistic).
class_presentation(elf, fantasy_realistic, elven_character).
entity_appearance(aria, appearance_aria).
view_purpose(ViewId, first_person).
view_subject(ViewId, aria).
depicts(VisualId, EntityRef).
```

An acting identity may control a character without being identical to that
character or having any visible body itself. The character participates in a
world, whose policy selects its representation. A FIPA agent platform (AP)
coordinates agents through the existing hosting and lifecycle machinery;
hosting alone does not select appearance. An AP may carry an explicit
application/world policy, but moving an agent between hosts must not implicitly
change its presentation. An ontology hosting classes
may recommend presentations without imposing them on every consuming world.

First-person, third-person, tactical-map, inspection, and editing presentations
can coexist for one entity. In an FPS-style world, the controlling user's view
may render specialized hands and weapon geometry while other users see the
whole avatar. Both refer to the same character and equipment. Camera offsets,
display proportions, and animation conveniences do not change authoritative
collision, reach, attachment, or other gameplay state.

Each rendered occurrence has a stable visual identity scoped to its view and
occurrence, and refers to the domain entity in its exact anchored ontology.
Applying one or several eidolon recipes can produce multiple occurrences for
the same entity, including under several visual parents. A bounded scene tree
does not require the domain graph to be a tree. Switching eidolons preserves
domain identity and reconciles output through ordinary create/update/remove
projection. Selection resolves through the entity reference, not a mesh name.

Presentation policies, reusable definitions, and authored shared appearance are
D-state. Derived descriptors are rebuildable P-state; selected purpose, camera,
and temporary editing controls are session state, with persistent preferences
stored only when explicitly requested. Views reuse the shared scene index and
MVCC/verified projection machinery, not private KBs or full per-view world
copies. Dependency changes use existing scoped installed-state notifications,
with snapshot ordering, cancellation, and original deadlines preserved.
Reproducible derived descriptors require exact source snapshot references,
presentation versions, parameters, and layout algorithm version; one ledger
height alone does not identify a multi-ontology view or its camera image.

### 4.4 Editing presentations and authorization

An `edition` purpose may apply to one selected component while the rest of the
world keeps its normal presentation. For example, selecting an avatar's arm in
VR can expose a skeleton, joint handles, dimensions, attachment points, and
material controls. Other users continue to see the normal avatar. Shared draft
visibility requires an explicit collaboration policy; entering an editor does
not publish intermediate changes or mutate the arm.

The interaction reuses the GUI draft and signed-goal flow in section 6.1:

1. Request the editing presentation for the selected entity/component.
2. Authorize that view and project its permitted properties and controls.
3. Manipulate a local draft with immediate visual preview.
4. Apply by constructing and signing a bounded domain goal through normal
   ingress, with the relevant base revision/preconditions checked for conflict.
5. Render the accepted state through the chosen presentation. Returning to
   normal view alone never commits a draft; discard is explicit. Rejected or
   uncertain submissions are not displayed as accepted changes, and uncertain
   operations use the existing operation-resolution flow without resubmission.

Each control declares its semantic target and operation: changing a display
material updates appearance, changing anatomical length invokes the domain
action responsible for geometry and its consequences, and moving an editor
handle alone changes only the draft. Presentations do not establish gameplay
consequences or bypass the authoritative simulation update boundary.

Existing ontology ACL/proof authorization remains the sole authority. The
presentation contract distinguishes three checks: availability of a requested
presentation, permission to read every exposed property/asset, and permission
to perform the submitted domain edit. Availability does not imply readable
private anatomy or writable attributes. Selection and filtering occur
server-side before protected content is sent; hiding controls is not an access
check. Every edit is independently authorized under the authenticated subject
and current policy, including direct signed goals that bypass the UI.

Policy changes invalidate affected view content and controls through ordinary
projection updates; stale editor state cannot authorize a later write. Removing
previously delivered content cannot erase what its recipient already learned.
Exact view-access predicates and descriptor schemas must be defined at the
implementation boundary without introducing a parallel ACL system.

### 4.5 Presenting actions in progress

**Deferred elaboration:** retain the agreed direction below, but settle the
eidolon recipes, GUI and menu model first. Action/activity and sound predicate
signatures are not selected by this section.

The agreed direction is that a representation ontology describes both an
entity's appearance and how its actions are perceived, visually and audibly.
Different representations may interpret the same action differently. Action
patterns use ordinary Prolog unification to bind the affected entity and action
parameters. Yan's illustrative form is:

```prolog
eidolon(MyAction) :- do_something_visual(MyAction).
```

This expresses representation-owned behavior, not a settled predicate signature
or permission to render during an ordinary proof. The representation rules
produce governed descriptions for the rendering and audio adapters. They do not
invoke arbitrary client code or give failed proof branches external effects.
The implementation must reuse existing projection, reaction and effect owners;
a separately authored completion event and reaction for every animation is not
required by this model.

Presentation follows an action's actual progress and outcome, including partial
movement, interruption and failure to reach its intended result. For example,
authorized closing starts a door moving; an obstruction stops it halfway. The
rendered door shows the actual angle, movement sound stops, and an impact sound
may occur. `door_closed(Door)` remains false. A visual animation cannot independently
assume the door reached its target or override authoritative collision.

The existing `action/3` and `goal/1` contracts remain unchanged: a successful
candidate must establish its desired state, and a failed candidate rolls back
its staged changes. A physical activity lasting several seconds spans bounded
transitions rather than one suspended proof. An ordinary action may establish
an authorized start/request state; runtime motion follows that accepted state,
and later transitions record meaningful outcomes. Acceptance of the start is
not success of `goal(door_closed(Door))`. Actual movement is not rolled back
because the ultimate physical objective was not reached. Exact activity state,
correlation, interruption and recovery terms remain to be specified.

Continuous movement and ongoing sounds follow current simulation/activity state;
one-shot visual and audio cues describe occurrences. Both modalities share the
same entity, activity and timing references. Sounds may be spatially associated
with an entity without a visible rendered occurrence. Reconnect restores current
presentation and any still-active sound without replaying past impacts or completed activity.
Local previews remain distinguishable from accepted simulation state.

## 5. Cue descriptors

Cue appearance is pure ontology data and may inherit defaults from domain
classes. Every descriptor has an explicitly registered versioned schema.
Clients whitelist descriptor types and enforce hard limits on particle count,
lifetime, sound gain, asset size, spawn rate, and similar engine costs.

Unknown or invalid descriptors are rejected and counted. They never become
arbitrary Erlang, JavaScript, shader, or engine calls.

A transaction cue is emitted only by its logical effect executor. P resolves
the audience from the committed snapshot and current client presence. A
simulation cue is emitted only by the current world authority and carries its
epoch and tick. It remains best-effort and never enters a durable outbox.

Audience forms may include one wielded agent, viewers of a world, or agents
perceiving an entity. Receiver deduplication uses `EffectId`; deadlines suppress
stale cues after congestion.

A collision may emit a visual explosion immediately. If it also causes shared
truth such as damage, destruction, or a voxel edit, the authority submits a
separate authorized action. The cue is never evidence that the action committed.

## 6. GUI ontologies and human interaction

GUI output is state projection. Quod should provide a reusable, extensible GUI
ontology with a semantic class tree such as:

```text
gui_component
|- container: panel, form, row, column, grid
|- display:   label, image, progress, table, log, editor
|- input:     text_box, number_box, checkbox, select, slider, button
`- menu:      action_menu, menu_entry
```

The standard ontology defines roles, value and event schemas, containment, and
accessibility meaning. Domain ontologies instantiate or derive these concepts;
they do not each require a separate consensus namespace. Rendering adapters may
map the same semantic roles to spatial panels, a flat desktop UI, speech, or
native accessibility facilities.

GUI classes have their own eidolon recipes: the same form may be a spatial
panel in the lobby or a flat panel on desktop. A pie menu is a presentation of
an action menu. Device classes own their offered Prolog operations; GUI classes
supply reusable parameter entry, labels, selection and result display. The GUI
ontology therefore belongs in the first lobby design, alongside the primitive
representation vocabulary. There is no implemented general GUI ontology yet.

The first vocabulary needs only what the console and workshop consume:
panels/forms, text or goal editors, labels, result lists, action menus and menu
entries. Extend that shared model as devices require it, not one ontology or
client implementation per widget.

The modelling toolkit and GUI vocabulary meet at a surface/view binding. The
toolkit supplies the console body and screen geometry; the GUI supplies the
goal editor, controls, focus, input and result bindings. The same GUI view can
appear on that screen or in the focused workspace without duplicating device
actions or widget semantics. Babylon supports both mesh-mounted and fullscreen
[GUI rendering](https://doc.babylonjs.com/features/featuresDeepDive/gui/gui);
the adapter chooses the appropriate realization for desktop or spatial XR.
GUI eidolons may use modelling helpers for their appearance, but decorative
shapes alone do not replace the planned semantic GUI components.

### 6.1 Current values and local drafts

A projected widget describes current accepted state. A variable in a view rule
is bound when that projection is proved; it is not a suspended variable waiting
for a future person:

```prolog
text_box(View, Field, Label, Options, CurrentText) :-
    character_name(Character, CurrentText).
```

Typing and intermediate form edits remain client/session P-state. Quod does not
commit a transaction for every key press. On validate or submit, the client
constructs and signs one visible goal. A structured helper may first use a
message such as:

```text
gui_input(InputId, SessionId, AgentId, ViewId, ComponentId,
          Event, Payload, SeenHeight)
```

The helper/client:

1. binds the session to its authenticated user and wielded agent;
2. verifies that the component/event exists in the projected current view;
3. validates a bounded payload against the component schema;
4. constructs and displays a ground goal, normally `goal(DesiredState)`;
5. signs and submits it through the general goal ingress, which applies the
   ordinary ontology ACL, proof, transaction, and resource limits.

One form submission is one bounded payload and one transaction, so related
field changes may commit atomically. Quod does not first commit a generic GUI
event and then rely on a second transaction for the primary domain change: that
would introduce a partial-success window. Post-commit `react_on` handlers remain
appropriate for notifications, projections, and external effects.

`SeenHeight` allows stale-interface rejection or refresh. `InputId` may be used
by the helper as the signed operation identity. The result identifies
acceptance or returns a bounded public failure-reason stack and current height.
A client may bind those reasons to field/form errors; a failed submission does
not need to write an error fact. A developer or script may bypass the helper
and sign an ordinary goal directly, without gaining additional authority.

### 6.2 Waiting for a person

A proof, snapshot, or namespace process must not wait for human response. A
workflow that needs later input first reaches durable correlated state and
ends, for example:

```prolog
awaiting_input(RequestId, Agent, Form, Schema, Deadline).
```

A later `gui_input` starts a new transaction. It validates the correlation and
atomically applies the domain update while completing or retracting the pending
request. If a larger workflow must resume, D stores a ground, versioned
continuation intent—not a live Prolog continuation or an unbound variable.
Runtime processes may schedule timeouts or mirror pending requests, but the
durable state is sufficient to reconstruct them after restart.

### 6.3 Contextual action menus

An action menu is an optional bounded ontology projection, not an enumeration
of every internal `action/3` clause and not a second authorization system. Its candidates
may be derived from:

- goals exposed by the wielded avatar and its composed limbs, abilities,
  equipment, and tools;
- goals offered by the current target;
- avatar or tool goals that are applicable to that target;
- goals pinned in a private ontology whose ACL grants the relevant
  `human_user` instance access, associated with the avatar;
- a small set of client or platform operations such as opening settings.

Multiple actions may reach the same desired state, so a state-changing menu
entry normally constructs `goal(DesiredState)`, not a chosen transition.
Read-only entries may instead construct a query. The ontology projects a
ground, bounded descriptor with stable `MenuId` and `EntryId`; the client
constructs the resulting goal locally and makes it available for inspection
before signing it. The server verifies and proves that exact goal through the
general ingress. Pinning or presenting a goal grants no new authority.

This permits users to add their own contextual helpers while preserving direct
signed goal submission. Stale or no-longer-ground menu entries are rejected and
the menu is refreshed. Pure client operations such as opening settings remain
explicitly identified as client operations; they do not pretend to be ontology
transactions.

### 6.4 Device capabilities and user profiles

The same scene and interaction semantics support immersive VR and conventional
software. The concrete controls are the intersection of:

```text
session device capabilities
    intersect persistent user preferences
    intersect current world policy
```

Device capabilities are untrusted P-state discovered for the session, for
example immersive versus flat display, tracked pointers, touchpad or thumbstick
radial input, trigger/squeeze, hand tracking, haptics, mouse, keyboard, and
gamepad. Durable user preferences may select dominant hand, self-menu hand,
target-pointer hand, locomotion, comfort, and accessibility options. Security
decisions remain ontology policy; a claimed device capability never grants
authority. Arbitrary menu and profile data belongs in a private ontology whose
ACL grants the relevant `human_user` instance access, not in the
`quod:human_user` vocabulary ontology.

The XR adapter supplies stereo cameras, head/controller poses, spatial panels,
and an XR frame budget. The desktop adapter supplies a conventional camera,
mouse/keyboard or gamepad controls, and screen-space panels. Both consume the
same scene and GUI projections.

The default VR profile uses two related radial menus:

- the self context presents avatar, limb, equipment, and user-pinned goals;
- the target context follows the pointing ray and combines target-provided
  goals with avatar/tool goals applicable to that target.

The initial target interaction is explicit: point the controller's ray (the
"god ray") at a device, use the round touchpad to open and select within its pie
menu, then confirm the chosen entry. Bind an open menu to the selected instance;
moving the ray must not silently retarget the eventual command. An entry with
parameters opens its declared GUI before any goal is submitted. Exact touch,
press, confirmation and cancellation bindings remain profile details.

The hand assignment is configurable. A Vive touchpad maps naturally to a pie
gesture; a Quest 3 controller can use a thumbstick or button to open, tilt to
select, and trigger/click to confirm; hand tracking can use a palm menu and
pinch. A desktop profile presents the same entries through a toolbar, shortcut,
right-click, or radial mouse menu. This is one semantic menu with different
input adapters, not separate VR and desktop domain logic.

### 6.5 Icons and semantic themes

Action-menu presentation metadata belongs primarily to the requested
goal/desired state, because several transitions may reach that state and the actual transition is
chosen only during proof. Illustrative metadata includes a label, description,
group, priority, and icon. Icon resolution is:

1. the user's override for that menu entry;
2. goal-specific metadata;
3. inherited goal/class metadata;
4. the built-in abstract action icon.

Built-in icons and user/domain icons are bounded presentation descriptors or
content-addressed assets. They cannot contain executable URLs or code. Colour
is never the only signifier: icon shape, text, contrast, and accessibility
semantics must carry the same meaning.

Themes map semantic roles to concrete colour and material. The initial
Tarot-inspired direction uses red for action/transition and yellow/gold for its
manifested effect or visible consequence. The default abstract action icon
therefore uses a red circular arrow around a yellow/gold central spark.
Blue/teal may denote perception or receptive state, green/olive material or
growing state, violet abstraction or transformation, white potential/clarity,
and slate an unavailable or unresolved entry; these secondary associations
remain theme choices rather than protocol meanings.

Marseille and Rider-Waite colour language inform the semantic contrast;
Visconti-Sforza and the gilded/lithographic Pierre Jacquot/Raymond Abellio Tarot
portfolio inform material and graphic finish without copying their artwork. A
capable VR renderer may use restrained metallic or shimmering gold, while flat
and accessibility profiles use a stable high-contrast fallback. Here `effect`
is a presentation role, not a new D/P/E class or a change to `action/3`
semantics.

## 7. Editable voxel worlds

### 7.1 Procedural base and overlay

The base value for:

```text
(WorldId, GeneratorVersion, Seed, Coordinate)
```

is immutable and deterministic. Editing adds or replaces overlay cells; it
never mutates generator output and never commits generated blocks.

Illustrative logical facts:

```prolog
voxel_chunk_revision(WorldId, Chunk, Revision).
voxel_patch(WorldId, Chunk, Revision, EditId, Encoding).
```

This does not require one Prolog term per cell. `Encoding` is a canonical
bounded run, bitmap, or palette representation. One cross-chunk edit is one
transaction with one stable `EditId` and one patch per affected chunk.

### 7.2 Mutation action

The only mutation entry is:

```prolog
apply_voxel_edit(WorldId, ExpectedRevisions, EditId, Operation) :-
    stage_voxel_edit(WorldId, ExpectedRevisions, EditId, Operation),
    assertz(voxel_edit_applied(
        WorldId, ExpectedRevisions, EditId, Operation)).

action(apply_voxel_edit(WorldId, ExpectedRevisions, EditId, Operation),
       [may_edit_voxels(WorldId),
        valid_voxel_edit(WorldId, ExpectedRevisions, EditId, Operation)],
       voxel_edit_applied(
           WorldId, ExpectedRevisions, EditId, Operation)).
```

The ordinary helper asks for the ground desired state with `goal/1`, allowing
the ontology to choose a transition. A developer may instead sign an explicit
`apply_voxel_edit/4` goal if the ontology exposes and authorizes it; that is not
a separate execution path. Authorization reads the authenticated subject from
the engine-owned proof context rather than from an `action/3` argument. The
named transition derives and stages the canonical patch and revision facts,
then records the exact request state. Including the request identity in that
state makes an exact retry idempotent without treating a different operation
that reused `EditId` as success.
This transition deliberately records its target as a fact; that is a domain
choice in this example, not behavior supplied by the action framework.

`Operation` uses deterministic integer or fixed-point geometry, such as explicit
cell writes or a bounded fill/remove sphere. Validators derive identical
canonical patches from the same base and overlays. Radius, chunks, cells,
encoded bytes, and proof time are bounded.

`ExpectedRevisions` turns concurrent edits into a clean conflict and retry.
`EditId` makes submission idempotent.

P materializes overlays and colliders for loaded chunks. Patch facts may be
compacted into a canonical overlay checkpoint after bounded count/byte
thresholds. Compaction preserves revision and semantic state without copying
the world or KB.

### 7.3 Client synchronization

Clients subscribe only to chunks selected by their current world view:

```text
voxel_chunk_snapshot(WorldId, Chunk, Revision, Generator, EncodedOverlay)
voxel_edit_delta(EditId, Height,
                 [{Chunk, FromRevision, ToRevision, EncodedPatch}])
```

The multi-chunk delta is atomic. A client applies it only if every visible chunk
is at its stated `FromRevision`; otherwise it requests snapshots for mismatched
chunks. Reconnect, entering an unloaded region, eviction, and sequence gaps use
the same snapshot path.

The editing client may predict locally, tagged by `EditId`. Prediction is
presentation state only: it is not forwarded and does not alter authoritative
collision. Commit confirms it; rejection/conflict restores authoritative chunk
state.

After commit, a bounded per-world ordered P worker updates overlays and
colliders. A revision is published only after installation in the authoritative
collision world. Failure marks the chunk unhealthy, suppresses its delta, and
rebuilds it from D.

Changing generator version requires an explicit migration or a new world.

## 8. Physics

Physics follows the BBSvx owner/ghost model:

- one logical authority simulates dynamic bodies;
- static bodies and deterministic colliders may be built everywhere;
- non-authorities hold read-only ghosts and interpolate authority frames;
- forces, impulses, joints, and controls route to the current authority;
- every hot command binds an authenticated subject, authority epoch, and current
  committed policy;
- hot commands may mutate P but cannot stage D or carry client goals;
- local engine reads use indexed handles rather than a central server call;
- tick delay is clamped, runaway bodies are bounded, and stale/self/old-epoch
  frames are dropped.

Only semantic state crosses into D: ownership, collection, destruction, locks,
voxel edits, or explicit checkpoints. Movement and collision frames remain hot.

### 8.1 Engine direction

Rapier 3D in Rust is the proven default candidate. BBSvx already implemented a
Rapier NIF with opaque world resources, rigid bodies, joints, voxel colliders,
collision events, and owner/ghost stepping. Quod should reuse the engine and
behavioral lessons, not copy that wrapper blindly.

The physics API remains behind one simulation adapter so integration can change
without changing ontology or authority semantics.

**Decision (Yan, 2026-07-17): the chosen integration is an audited Rustler NIF
using dirty CPU scheduling (or bounded yielding) for expensive calls.** A
supervised native port process is the fallback only if the audit or the
benchmarks below show the NIF is unsafe at target load. Quod's no-NIF stance was
always specific to the QUIC transport, not a project-wide rule; physics is a
legitimate native-code boundary.

The old BBSvx wrapper marks `step_world`, bulk body queries, and voxel-collider
construction as ordinary NIF calls. Those calls can monopolize BEAM schedulers
at non-trivial body/chunk counts and must not be copied unchanged.

Engine selection is benchmark-driven: body count, active contacts, joints,
voxel collider complexity, step p50/p95/p99, state extraction cost, memory per
world, scheduler utilization, crash containment, and multiple-world fairness.
Authority stays server-side; clients may predict and interpolate but do not
become the source of shared simulation truth.

This native physics decision is independent from transport. Quod's pinned
pure-Erlang QUIC fork already exposes RFC 9221 `send_datagram/2`, negotiated
maximum datagram size, bounded drop-oldest receive queues, and datagram
statistics.

## 9. Performance and observability direction

- Scene/GUI queues coalesce superseded updates by stable object ID.
- Slow clients are disconnected and resnapshotted before queues grow unbounded.
- Simulation uses independent bounded datagram queues.
- Datagrams share each peer connection's congestion window and pacing with
  streams. Mixed stream/datagram tests must prove consensus latency remains
  protected by priority and datagram byte-rate limits.
- Visibility uses shared spatial indexes plus compiled per-agent filters.
- Voxel generation, meshing, and collider work is chunked, cached, cancellable,
  and bounded.
- Every metric has user-facing Prometheus help and a matching Grafana panel.

Metrics should cover client view sessions, snapshot size/latency, delta depth,
resnapshot cause, GUI submit latency and failure class, stale/deduplicated GUI
input, pending-interaction age, menu projection/refresh, profile/capability
selection, cue rejection/expiry, frame age/loss, authority epochs, chunk
generation/cache behavior, voxel edit commit-to-client latency, patch
size/cells, revision conflicts, client resync, compaction, and collider
installation.

Voxel edit throughput is a gameplay parameter because edits are consensus
transactions. Client prediction hides local perception but not authoritative
conflict resolution or remote convergence. Before C2, define and measure a
concurrent-editor target: committed edits/s plus p50/p95/p99 latency while
consensus, ACL, client state, and simulation datagrams share the fleet. The
current roughly 15 tx/s observation is a baseline, not an acceptance target.

Possible responsibilities include client streaming, scene indexing, GUI
validation, simulation authority, and voxel generation. These are not module
commitments; concrete modules should be introduced only with implementation.

## 10. Candidate validation milestones

These milestones are intentionally outside the numbered agent/FIPA slices.
The personal lobby in section 11 is the proposed first application for C1; the
full C1 checklist remains broader than that initial application.

### C1 -- client projection and GUI

- Negotiate a versioned protocol and authenticated client view session.
- Deliver an atomic scene snapshot and model create/update/remove deltas for a
  primitive, a content-addressed mesh, and one composite attachment tree.
- Deliver one bounded versioned explosion cue.
- Project one typed GUI tree, retain edits as a local draft, and map one form
  submission to a single declared `goal(DesiredState)` transaction.
- Complete one durable `awaiting_input` interaction through a later correlated
  transaction without retaining a proof or snapshot.
- Project self and target menus, invoke an ontology-owned entry by stable ID,
  and prove that a user-pinned entry grants no extra authority.
- Render the same semantic menu through one immersive capability profile and
  one desktop profile, including icon fallback and non-colour labels.
- Resolve class defaults and world policy for two presentations of one entity;
  preserve entity identity across view switches and diagnose ambiguous matches.
- Edit one avatar component in VR through a local draft and one authorized
  domain submission while another client retains its normal presentation.
- Verify separate presentation/read/edit permissions, stale revisions, policy
  revocation, and direct-goal authorization; denied properties never enter a
  descriptor, and switching views neither commits a draft nor changes collision.
- Test disconnect, sequence gaps, owner failover, and slow clients.

Success means reconnect reconstructs models/GUI without replaying cues; unknown
descriptors fail closed; a client cannot forge identity, alter a signed goal,
or bypass ontology ACLs; drafts do not create transactions; failed input
returns bounded reasons; stale menu entries refresh; queues remain bounded.

### C2 -- hot simulation and editable voxel world

- Generate a visual chunk and server collider without generated-block facts.
- Establish bounded dig/place/explosion desired states through explicit
  transitions with revisioned chunk patches.
- Converge two clients through snapshots and multi-chunk deltas.
- Run one authority and read-only ghosts over epoch/tick datagrams.
- Reassign authority and rebuild from a checkpoint.
- Benchmark Rapier integration at explicit body/contact/joint/chunk counts and
  choose audited dirty NIF versus isolated port from measurements.
- Run a declared number of concurrent diggers/builders and report committed
  edits/s plus p50/p95/p99 convergence latency.

Success means per-frame movement causes no Prolog churn; frame loss converges;
old authorities are rejected; two clients converge under concurrent cross-chunk
edits; stale revisions conflict cleanly; missed deltas resnapshot; replay,
failover, and compaction preserve matching voxel/collider revisions; world load
cannot starve block apply or reliable traffic.

## 11. First application: the personal lobby

**Concept direction:** after login, a user enters a personal lobby described by
ontology state. Personal first, shared spaces later is the selected scope. The
model below is a proposal for refinement, not an implemented world protocol or
a final predicate schema.

### 11.1 Purpose and arrival

The lobby is a persistent place to inspect and operate Quod through meaningful
objects. Its room, devices, placement, presentation choices and saved links are
ontology data. The client applies their class-selected eidolon recipes and
renders the resulting authorized projections and interactions; it does not
hard-code a different screen for every device.

A returning user authenticates with the existing key provider, selects their
stable human-agent identity where necessary, and resolves its configured lobby.
The client obtains a current authorized snapshot and follows scoped changes.
Desktop and immersive clients enter the same lobby with the same domain actions.
Camera, controller poses, selection and unfinished forms remain session state.

Key authentication alone does not create a human agent. Once a user ontology
is actually created, the selected direction is automatic creation of its own
lobby ontology through durable state convergence (section 11.3). The existing
explicit agent-reference selection remains the bootstrap until an enrollment
flow is defined. Login follows the resulting lobby reference or shows its
pending/unavailable state; it must not create another lobby to replace a missing
reply or temporarily unavailable ontology.

The lobby is independent of the node serving the browser. Reconnecting through
another node must resolve the same anchored lobby and recover outstanding
operation outcomes through the existing client journal.

### 11.2 Ownership and references

A shared lobby-class ontology defines the lobby class, its reusable device
classes or class references, and its eidolon associations. Each newly created
user receives a separate personal lobby ontology containing a lobby instance,
its initial device instances, layout and saved references. The user ontology
records the resulting exact lobby reference.

Device classes are Prolog classes, using the existing class-first convention.
For example, the shared vocabulary may declare `isa(prolog_console,
lobby_device)`, while the personal lobby contains
`instance_of(prolog_console, console_1)`. Its founding input instantiates the
initial devices together. Devices share class definitions and eidolon recipes;
there is no separate ledger per device or graphical primitive.

The exact human-agent reference receives explicit lobby read/edit permissions.
Class membership, containment and an editable layout grant no rights over the
nodes, ontologies or agents represented by its devices. A later shared space
will have its own access and collaboration policy rather than making this
private lobby public by default.

Illustrative durable relationships, with schematic reference variables:

```prolog
instance_of(lobby, my_lobby).
lobby_user(my_lobby, HumanAgentRef).
instance_of(prolog_console, console_1).
lobby_device(my_lobby, console_1).
instance_of(node_station, node_station_1).
lobby_device(my_lobby, node_station_1).
device_target(node_station_1, NodeAgentRef).
lobby_agent_link(my_lobby, AgentRef, Label).
```

These examples describe the domain, not access grants or founding input ready to
submit. References to external ontologies and instances bind their exact genesis
anchors. Local instances use local names, never a circular own-genesis hash.
The user's ontology stores the selected lobby reference once provisioned;
the exact profile predicate and enrollment policy remain to be specified.

A device is a lobby entity; the node it represents is a different entity. A
console-shaped representation may include a rendering of that node using its
own eidolon recipe. The output makes both targets explicit, so selecting a
device and acting on its remote subject cannot be confused. The same node may appear in several
lobbies without copying its authoritative state into them.

### 11.3 Durable lobby provisioning and creation notifications

The selected guarantee is a durable requirement: every newly created user must
have a personal lobby. Establish that requirement in the user's founding state,
not in a later live reaction that may never run. Illustrative current-state
terms, using the user's local instance name, are:

```prolog
lobby_provisioning(LocalUser, pending).
% Replaced atomically with the admitted root creation effect:
lobby_provisioning(LocalUser, linked(LobbyRef)).
```

These describe successive states of one domain obligation, not an accumulating
message history. The exact intermediate operation-reference terms and predicate
signatures remain to be specified. The linked state supplies the one authoritative
lobby reference rather than duplicating it in another mutable profile fact. It
means creation was committed, not that the new ontology is currently available.

The intended flow is:

```text
user genesis commits its instance and lobby requirement together
    -> founding state handler reconciles current requirements
    -> one ordinary atomic transaction stages root creation and replaces
       the pending requirement with its prepared exact lobby reference
    -> existing lifecycle owner applies that committed creation effect
    -> the client opens that exact lobby when it becomes available
```

The existing creation predicate binds the prepared genesis anchor before
commit. Its root plan remains effect-only; the user's separate source plan can
record that anchor in the same atomic group. This removes a separate
creation-then-link handoff. An isolated integration experiment has exercised
this exact composition, including consumption of the pending guard and refusal
of a second invocation after known completion. It does not establish automatic
admission recovery or authorize a fresh attempt after an unknown outcome.

The same state handler runs for live changes and startup reconciliation. It
selects affected work through existing projection/runtime mechanisms; it does
not perform creation IO in the ordered projection tier. The chosen executor
uses ordinary signed goals, root creation policy and the existing durable effect
journal. D holds the requirement and resulting reference; P reconstructs work
from that state; the effect owner retains creation custody. These are existing
responsibilities, not new event categories or additional executors.

Root remains the authority for creation permission. Lobby provisioning policy
recognizes the actual authorized user instance, never a namespace naming pattern
or the creator alone. Lobby genesis instantiates devices but does not declare
another human user's provisioning requirement. Founding declarations and the
executor's explicit grants must satisfy the existing runtime/ACL contracts.

Recovery must cover a crash before work starts, around group admission, after
commit but before creation is applied, and after creation. Retain the exact operation and
created identity through the existing custody handoffs. Pending state alone does
not prove that no creation was submitted. Unknown outcomes use the existing
operation-resolution path, not a newly signed create. The guarded FIPA
continuation exception does not implicitly authorize repeating lifecycle effects.
Duplicate observations must not create competing lobbies: a chosen namespace
alone cannot ensure this because concurrent creations can have distinct anchors.
The exact executor admission/correlation handoff remains an implementation
contract to settle; recording the requirement does not solve it by itself.
Recovery must also distinguish process restart from permanent loss of an
executor holding local durable creation custody.

A general `ontology_created(CreationRef, Namespace, GenesisAnchor, CreatorRef)`
occurrence remains useful for live notifications and independent reactions, but
is not the source of provisioning responsibility. This proposed event differs
from the existing local postcondition `ontology_created/2`. Publish it only after
actual creation of the exact identity, not when the controlling request is merely
accepted. Historical birth and current availability/readiness remain distinct.

The existing lifecycle journal's `finish_effect/3` records verified local
completion and releases waiters; namespace-topology pub/sub reports local
availability. Neither currently publishes that committed Prolog occurrence.
Its authorized reporting transaction and completion evidence still need design.
Missing a notification must not lose the lobby requirement, and historical
reactions remain unreplayed. No second reaction wake path for provisioning,
lifecycle broker, generic outbox, periodic scan or root-wide ontology catalogue
is introduced.

### 11.4 Devices and existing paths

| Device | User experience | Authoritative source and action path |
| --- | --- | --- |
| Node station | Inspect a node the user administers, its hosting state and the operations exposed to this user | Exact node identity, its governing policy and runtime observations; existing node action/execution paths |
| Ontology workshop | Draft an ontology from a versioned template, inspect its initial rules and permissions, then create it | Root-owned `create_ontology/3`, existing prepared effect, outcome and namespace lifecycle |
| Prolog console | Select an exact ontology, enter a goal, inspect bindings or submit a change | Existing signed read/execute/cursor APIs and operation journal |
| Agent display | Inspect linked agents, their committed assignments, observed availability and domain-reported activity | Each agent's containing ontology and existing hosting observations |
| World entrance | Inspect and enter a known world once a compatible world is available | An anchored world reference and its entry policy; changing view does not copy the world |

A world template is ordinary ontology founding input using the world vocabulary;
it is not another creation executor. The workshop initially supports one small,
reviewed template plus inspection of the resulting goal. Template provenance,
version, parameters and proposed initial access policy are visible before
submission. Creating an ontology and observing that it is usable are separate
stages of the existing lifecycle. The workshop shows both and never starts a
second creation because the first result is uncertain. Saving a convenient lobby
link is a later domain edit, not evidence of creation and not an atomicity claim
across the post-commit lifecycle effect.

Each device class defines its offered Prolog operations and eidolon recipes;
lenses may supply its data views. For example, the Prolog-console class offers
`prove_goal`, presented as an entry in its target pie menu. Choosing it opens a
focused working interface containing an exact ontology target, a goal editor
and results. The screen expands to fill the desktop client view; in VR it becomes
a large readable panel in front of the user rather than requiring work on a tiny
in-world screen. Closing the focused interface returns to the room without
implicitly submitting a draft or cancelling an already admitted operation.
Focus is personal session state and does not resize the device for other users.

The minimum usable console provides multiline goal entry, variable bindings for
each solution, next-solution and stop controls, explicit acceptance of staged
changes, and clear failure/error or unknown-outcome feedback. Submission binds
those inputs and uses the normal signed proof path. The full signature and
exact action binding remain to be specified; it must not execute arbitrary input
with the lobby service's privileges. Ontology browsing and source editing are
later workstation capabilities using the same authorization and draft/apply
model, not requirements to complete before the first usable goal console.

The console's playing eidolon describes its normal operating presentation,
including access to that focused workspace. Its edition eidolon serves authoring
of the console itself: dimensions, parts, screen placement, materials and exposed
configuration, where permitted. Editing another ontology through the working
console is still normal use of the tool, not selection of the console's edition
eidolon. A class need not provide an edition recipe until it has actual editable
properties. Presentation choice is per view, not a global playing/editing mode.

The visual direction is futuristic, with a simple first realization built from
reusable geometry and GUI components. A recipe can describe a console body as a
box with given dimensions, a screen surface and material/texture references;
the client maps those primitive descriptions to its rendering engine. GUI
components define the functional editor and results independently of that body.
The exact common primitive fields and update identities are an implementation
contract, not extra device-specific behavior for the user to configure.

The console reuses the Explorer console's signing, cursor lifecycle, exact
Accept/Next/Stop semantics and error handling. Shared client logic should be
extracted where needed, not copied into a VR executor. Ordinary forms keep drafts
locally and do not hold a proof while awaiting input. An explicitly opened expert
proof cursor retains its existing bounded lifetime and expiry behavior.

An agent link is a saved reference or a relationship established by application
policy. It is not an ownership or delegation grant. The first list is explicit
and bounded; there is no fleet-wide search or private global agent inventory.
The user signs as their own agent unless an existing valid acting identity is
explicitly selected. Merely selecting a displayed agent does not wield it.

### 11.5 Actions and perceptible activity

Devices expose ontology-authored contextual goals, not all internal predicates
or every `action/3` clause. Prolog rules derive entries from the device, its
target, current domain state and the authenticated user. Pattern unification
binds the target and parameters. Every submitted goal still passes the target's
ordinary policy, independently of whether the UI offered it.

Each representation defines visual and sound behavior for the device's actions,
following section 4.5. The workshop may show a prepared local draft, work in
progress, a completed artifact or a truthful failure. Its animation follows the
actual creation outcome and readiness observations; an elapsed animation is not
proof that an ontology exists. One-shot completion sounds are not replayed after
reconnection. Ongoing activity is reconstructed from its current owner.

Detailed activity/sound elaboration remains deferred while recipes, menus and
GUI are settled. The lobby retains a later physical acceptance example: a door
closing against an obstruction stops halfway, with matching geometry and audio, while
`door_closed(Door)` remains false. This requires the actual simulation bridge;
a scripted obstruction animation cannot count as physics acceptance. The first
lobby can establish device interactions before that bridge is ready.

### 11.6 Current implementation gaps

- The browser now reads a personal lobby or the existing licence lens, reconciles
  a hierarchy of primitive output shapes, and opens the shared proof console
  through an ontology-derived device menu. It still lacks a general subscribed
  view session, governed attachment projection, headset menus and coordinated
  audio. Extend this shared path rather than adding a renderer per device.
- Human-user profiles derive `lobby_reference/1` from their authoritative
  `lobby_provisioning/2` state. Browser signup and signed lobby creation use the
  ordinary lifecycle and operation journal (section 11.9). Fully autonomous
  provisioning without a returning browser and a generic creation notification
  remain gaps from section 11.3; no extra executor or global user registry fills
  them. Explicit agent relations also need ordinary ontology rules.
- Human administration of a physical node needs explicit target-owned grants
  and a supported exact-node invocation contract. Current `quod:node` hosting
  policy admits node principals; a human login does not supply that authority.
  Reuse node execution where applicable and bind the intended node, never infer
  it from the browser endpoint or choose whichever host answered a scope call.
- Root's authored policy restricts mutations to admitted nodes or explicit
  administrator agents. Its ordinary creation action can delegate permission
  to anchored Prolog policies. Activating open signup requires this restriction
  in the actual root history before publishing the signup catalogue entry.
- Committed host assignment and a currently observed live process are different
  facts. The agent display must distinguish assigned, observed running,
  recovering, refused and unavailable/unknown without inventing a universal
  agent-state engine. Domain activity is supplied by the agent's ontology.
- Existing foundation locks on runtime declarations still apply. Any necessary
  system-ontology declaration change needs its normal activation/succession
  plan; updating a `.pl` file does not update a deployed ontology.

Visibility and private observations are authorized before projection. Revoked
access removes affected controls/content through scoped notifications; stale
controls cannot authorize a later command. Subscription ordering, cancellation
and original deadlines remain properties of the shared projection paths. No
per-device polling, copied knowledge base, new broker or duplicate executor is
part of the lobby model.

### 11.7 First acceptance and later expansion

Keep the first implementation as one usable room: a console, an ontology
workshop, an agent display and one authorized node station. Reusable primitives
and spatial panels suffice; desktop and one XR input profile use the same device
semantics. Detailed world authoring and shared presence follow this checkpoint.

Acceptance must demonstrate:

- Creating an authorized user ontology provisions one personal lobby with its
  initial classed devices even when no creation notification is delivered; crashes
  before admission or linking and duplicate observations neither lose the
  obligation nor create competing lobbies, and lobby birth does not recurse.
- Point at an instantiated console, select `prove_goal` through the touchpad pie
  menu, enter a multiline goal in its focused workspace and inspect solutions
  with variable bindings through the existing signed proof/cursor path. Return
  to the lobby without losing or silently submitting the local draft.
- Switch a device between playing and edition eidolon recipes without changing
  its domain identity, permissions or authoritative state.
- Return to the same personal lobby after logout/reconnect, with saved layout
  and links restored and another user's private data excluded.
- Invoke the same permitted operation from a device and the direct console;
  deny the same forbidden operation through both paths.
- Create one ontology through the workshop, show its exact identity and actual
  readiness, and resolve a lost reply without another creation request.
- Follow a linked agent's real host change/recovery without duplicate actors or
  a fabricated running status, including an observation becoming unavailable.
- Reconcile state after a gap or slow client without replaying sounds; preserve
  pending-operation truth through reconnect and remove revoked controls.
- Render and operate the same device model on desktop and in XR. Validate the
  obstructed-door case separately when physical activity is integrated.

Remaining product choices are the initial room's appearance, the first small
world template, which specific node operations deserve controls, and whether
later lobby visits require avatars or can initially be observer viewpoints.
They do not require choosing a different action, identity or transaction model.


### 11.8 Initial lobby and toolkit implementation contract

The first implementation covers the presentation recipe, one private console
and its desktop workspace. It is a foundation for the acceptance in section
11.7, not completion of that broader milestone. The shipped Prolog sources are
founding inputs; adding a source file does not create or upgrade a system
ontology in a running fleet. Browser enrollment and lobby creation are specified
in section 11.9; activating their sources is a separate deployment operation.

`quod_lobby.pl` defines the shared lobby/device classes, class-to-eidolon
associations and console menu. `quod_gui.pl` defines the first composite proof
form using semantic editor, bindings and button roles. `lobby_instance.pl`
defines private instance behaviour and grants invocation only to its explicit
owner. Founding supplies these facts, using exact real anchors:

```prolog
% Personal lobby:
lobby_owner(agent_instance_ref(UserNamespace, UserAnchor, UserInstance)).
instance_of(prolog_console, console).
lobby_vocabulary(LobbyClassNamespace, LobbyClassAnchor).
presentation_vocabulary(PresentationNamespace, PresentationAnchor).
gui_vocabulary(GuiNamespace, GuiAnchor).
% Selected user's ontology (lobby_reference/1 is derived):
lobby_provisioning(me, linked(ontology_ref(PersonalLobbyNamespace, PersonalLobbyAnchor))).
```

The shared lobby vocabulary also has an anchored `presentation_vocabulary/2`
reference. These ontologies are founded with `quod_agent_predicates` so their
ordinary scoped reads can prove `current_ontology_identity/2`. Device subjects
use `depicts(Namespace, Anchor, Entity)`; an unanchored subject from an older
lens remains display-only. Neither a namespace string nor a mesh name grants
authority. All console requests use the user's selected signing identity.

The existing presentation vocabulary supplies pure authoring helpers:

```prolog
model(Parts, Marks).
% Parts are a parent-before-child list of:
part(Id, Shape, Transform, Surface, Label, Subject).
% Shape: group | box(W,H,D) | sphere(D) | plane(W,H) | cylinder(D,H)
% Transform: transform(X,Y,Z,RX,RY,RZ) | relative(ParentId, transform(...))
% Surface: no_surface (groups only) | material(Colour,Finish)
%          | pbr(Colour,Metallic,Roughness,Emission)
align(Shape, Face, TargetShape, TargetFace, Gap, Transform).
```

A recipe is an eidolon; its compiled `mark/7` values are visual occurrences.
Recipes can evaluate arithmetic in dimensions and transforms through Prolog
`is/2`; the resulting descriptors contain bounded whole millimetres/degrees.
PBR factors are integer permille, converted at the rendering edge. Alignment
joins axis-aligned bounding-box anchors in the target's local frame. A positive
gap follows the target face's outward normal; a fractional-millimetre result
fails instead of rounding. Parent ordering excludes cycles, duplicate identities
and dangling references. Groups compose transforms without manufacturing a
visible object. Labels may attach to groups or shapes.

Babylon maps these values to transform nodes, primitive meshes and PBR materials.
Unchanged occurrences retain their rendering resources. Changed geometry retires
its own resources; surviving children are reparented before old parents are
disposed. This client scene tree supplies no server spatial/perception index.
Textures, asset-backed meshes, bones and particles need their later neutral
asset/animation contracts and are not implemented by these helpers.

One React build serves the world at `/` and Explorer at `/explorer/`, sharing
session controls, key providers, signed operation journal and proof console.
`client/` retains reusable protocol/renderer modules; both entry pages and their
shared assets are built by `ui/` into `priv/explorer/`. There is no second console
executor. Result bindings retain full binary bytes, including genesis anchors;
display-only key abbreviations are not suitable for this data boundary. Signed
request text retains its existing exact spelling.

The desktop user can click the model or its accessible device button, select
`prove_goal`, and work in the focused form. Its goal runs in the selected agent's
exact signed origin; an explicit ontology selection uses the existing scoped
proof semantics. Next retains the same proof, Stop discards staged changes and
Accept submits the displayed solution. Closing the panel preserves its draft
and live cursor within that session. Changing identity, actor or target retires
the old console. This is not durable restoration of an interactive cursor after
a browser restart; admitted operation outcomes remain in the existing journal.

The edition recipe currently exposes a distinct structure presentation, not a
model editor. Desktop controls remain usable without WebGL. Optional WebXR scene
entry does not yet supply the round-touchpad menu or a headset proof workspace;
headset acceptance remains outstanding. Projection is an explicit signed snapshot
at entry/refresh, not a subscribed live view. Automatic revocation removal,
continuous updates and missed-delta resynchronization therefore remain part of
the future shared view-session work. A later command still passes ordinary ACLs.

The isolated integration fixture creates real ontology owners, makes actual
signed cross-ontology reads, rejects the wrong anchor and another valid actor,
and restores the same scene from the personal lobby ledger after owner restart.
It does not prove automatic creation, remote-node transfer or fleet activation.


### 11.9 Open signup and browser recovery

`quod:signup` offers an open Prolog creation policy. A new key signs as the derived
`signup(Key)` applicant in that exact ontology, with authority only to create its
profile and inspect its own unfinished enrollment. `signup/3` commits the prepared
human-user identity, temporary receipt and node hosting declaration in one ordinary transaction. The
profile's founding options contain its owner key, pinned lobby class, pending
lobby requirement, chosen `hosting_node/1` and exact signup receipt identity. No separate registration
HTTP command or permanent central human registry is introduced.

`human_user_instance.pl` defines `provision_lobby/1`: the pending requirement,
prepared lobby reference and receiver creation effect form one atomic transition.
The same transaction records the lobby's node hosting declaration and consumes
the signup receipt. `quod_lobby.pl` supplies reviewed
instance source and exact presentation/GUI references as Prolog founding data.
Root proves the full options through the delegated creation policy. No imported
source path is evaluated on whichever node receives a public signup request.

Host selection is explicit Prolog policy: signup supplies `signup_host(NodeRef)`.
The selected node opts in with `ontology_hosting_policy(SignupNs, SignupAnchor)`.
Its `request_ontology_hosting/5` entry binds the supplied requester to the signed
principal; the action proves the anchored foreign policy before calling the
shared `host_ontology/4`. Admission itself remains a strictly local proof.
The enrollment policy permits only the applicant's exact receipted profile or
that profile's linked personal lobby; consuming the receipt ends this permission.
Denied hosting rolls back creation in the same transaction. `discoverable`
publishes the route, while profile and lobby content remain owner-authorized.
No browser endpoint or incidental proof executor selects the durable host.

The normal browser Create account flow executes those two signed actions. Its
existing IndexedDB operation journal atomically replaces the completed signup
record with the lobby request before sending that request. A committed outcome
includes its named bindings, so lost replies recover the exact prepared identity.
The account reference is saved alongside the active browser key and inside its
encrypted export; importing that export recovers the same profile and lobby.
Readiness remains distinct from a committed reference. Unknown operations are
resolved using their original bytes, never resubmitted for proof.

This provides ordinary browser enrollment and recovery of admitted operations.
It does not yet provide autonomous provisioning while the browser stays offline.
A crash between journaling and admission remains subject to the existing strict
unknown-operation rule; absence of a known commit is not permission to create
another identity. The FIPA guarded-continuation exception is not extended to
lifecycle creation by this flow.

The browser discovers system references through the root catalogue, checks its
network identity, and disables the licence view when its lens or licence ontology
is not registered. Registration is a discoverability check, not proof of current
readiness or permission; each actual view still uses an ordinary authorized read.
View changes clear old scene content, and renderer-startup errors are visible
without preventing the semantic console from operating.
