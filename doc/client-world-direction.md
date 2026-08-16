# Quod client and world runtime -- architectural direction

**Status:** the browser key, login, signed local and multi-ontology goals,
cursor, unresolved-operation journal, user-home, and Explorer-console
foundation is implemented in the working tree. The world, agent, presentation,
and simulation sections remain non-normative direction and must be revalidated
before their implementation.

This document records the intended architecture for client projection,
renderer-neutral model ontologies, GUI, client profiles, visual cues, hot
simulation, and editable voxel worlds. It is deliberately separate from
`doc/agent-fipa-plan.md`: none of this should expand or delay the immediate
agent/runtime substrate work.

The presentation-ontology, asynchronous-GUI, contextual-action-menu, client
profile, and semantic-theme directions below were revalidated with Yan on
2026-08-10. Predicate, module, and wire names remain illustrative until their
implementation slices are reviewed.

The signed-client work now supplies the base user identity and signed goal path
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
- current logical simulation authority and monotonically increasing epoch;
- structured GUI component trees, durable pending interactions, private
  user-owned menu entries and preferences, and client view sessions;
- sparse voxel edits and semantic checkpoints.

Rebuildable P contains:

- shared scene and spatial indexes;
- filtered per-agent client view sessions;
- client model and GUI indexes;
- projected contextual menus, session device capabilities, and unsubmitted GUI
  drafts;
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
signed-goal API for reads, writes, cursors, and the ordinary
`create_user_home.` root goal. The interactive Explorer console uses that same
login and API; the standalone Explorer listener is read-only. The same signed
request and user principal now cross remote and nested ontology scopes through
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

Illustrative durable vocabulary:

```prolog
world(WorldId, WorldClass, GeneratorVersion, Seed).
scene_entity(EntityId, WorldId).
model(EntityId, ModelDescriptor).
transform(EntityId, Transform).
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

Creating a model instance or GUI widget is the idempotent client result of
applying projected state, not a one-shot reaction. Stable entity/component IDs
drive create, update, and remove.

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
`- input:     text_box, number_box, checkbox, select, slider, button
```

The standard ontology defines roles, value and event schemas, containment, and
accessibility meaning. Domain ontologies instantiate or derive these concepts;
they do not each require a separate consensus namespace. Rendering adapters may
map the same semantic roles to spatial panels, a flat desktop UI, speech, or
native accessibility facilities.

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
- goals the user has pinned in a private user-owned ontology associated with
  the avatar;
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
authority. Arbitrary menu and profile data belongs in a private user-owned
ontology, not the platform `quod:user` identity/routing ontology.

The XR adapter supplies stereo cameras, head/controller poses, spatial panels,
and an XR frame budget. The desktop adapter supplies a conventional camera,
mouse/keyboard or gamepad controls, and screen-space panels. Both consume the
same scene and GUI projections.

The default VR profile uses two related radial menus:

- the self context presents avatar, limb, equipment, and user-pinned goals;
- the target context follows the pointing ray and combines target-provided
  goals with avatar/tool goals applicable to that target.

The hand assignment is configurable. A Vive touchpad maps naturally to a pie
gesture; a Quest 3 controller can use a thumbstick or button to open, tilt to
select, and trigger/click to confirm; hand tracking can use a palm menu and
pinch. A desktop profile presents the same entries through a toolbar, shortcut,
right-click, or radial mouse menu. This is one semantic menu with different
input adapters, not separate VR and desktop domain logic.

### 6.5 Icons and semantic themes

Presentation metadata belongs primarily to the requested goal/desired state,
because several transitions may reach that state and the actual transition is
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
