# Quod client and world runtime -- architectural direction

**Status:** NON-NORMATIVE DIRECTION. Revalidate before implementation.

This document records the intended architecture for client projection, GUI,
visual cues, hot simulation, and editable voxel worlds. It is deliberately
separate from `doc/agent-fipa-plan.md`: none of this should expand or delay the
immediate agent/runtime substrate work.

Implementation depends on the agent plan through signed users, immutable
subjects, hosted agents, wielding, post-apply events, runtime reconciliation,
and owner-gated effects. Details here are expected to evolve after those pieces
exist and can be measured.

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
- client-supplied Prolog goals;
- committing generated blocks or per-frame transforms;
- one undifferentiated stream for scene state, GUI, physics, and visual cues.

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

## 2. D, P, and E for worlds

The agent plan's D/P/E categories remain sufficient. Hot simulation is a
specialized P/E profile, not a fourth external-predicate class.

Durable D facts describe:

- world identity, generator type and exact version, and deterministic seed;
- entity identity, model/material references, baseline transform, collision
  shape, and simulation parameters;
- current logical simulation authority and monotonically increasing epoch;
- structured GUI component trees and view subscriptions;
- sparse voxel edits and semantic checkpoints.

Rebuildable P contains:

- shared scene and spatial indexes;
- filtered per-agent subscriptions;
- client model and GUI indexes;
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

## 3. Client envelope families

The internal `ontology_event/7` from the agent plan is not a client protocol.
Client projection derives typed envelopes:

```text
state_snapshot(SubscriptionId, Namespace, Height, State)
state_delta(SubscriptionId, Namespace, Height, TransactionId, Operations)
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
model(EntityId, ContentHash).
transform(EntityId, Transform).
gui_component(ViewId, ComponentId, Kind).
gui_attribute(ViewId, ComponentId, Name, Value).
view_subscription(AgentId, Source, ViewType).
```

The exact vocabulary belongs to future `quod:world` and `quod:client`
ontologies, not hard-coded Erlang dispatch.

Asset references are content-addressed and policy checked. Ontology content
cannot cause clients to fetch arbitrary executable code or untrusted URLs.

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

## 6. GUI input

GUI output is state projection. Input is an authenticated command:

```text
gui_input(InputId, SessionId, AgentId, ViewId, ComponentId,
          Event, Payload, SeenHeight)
```

The server:

1. binds the session to its authenticated user and wielded agent;
2. verifies that the component/event exists in the projected current view;
3. validates the payload against the component schema;
4. maps the event through ontology policy to a ground desired state whose
   declared `action/3` transition is owned by that ontology;
5. applies session, agent, and component rate limits.

The client never supplies a Prolog goal. `SeenHeight` allows stale-interface
rejection or refresh. `InputId` and the exact desired state make retries
explicit and idempotent.

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

The server asks for the ground desired state with `goal/1`; the client never
chooses or invokes `apply_voxel_edit/4`. Authorization reads the authenticated
subject from the engine-owned proof context rather than from an `action/3`
argument. The named transition derives and stages the canonical patch and
revision facts, then records the exact request state. Including the request
identity in that state makes an exact retry idempotent without treating a
different operation that reused `EditId` as success.
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

Metrics should cover subscriptions, snapshot size/latency, delta depth,
resnapshot cause, stale GUI input, cue rejection/expiry, frame age/loss,
authority epochs, chunk generation/cache behavior, voxel edit commit-to-client
latency, patch size/cells, revision conflicts, client resync, compaction, and
collider installation.

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

- Negotiate a versioned protocol and authenticated subscription.
- Deliver an atomic scene snapshot and model create/update/remove deltas.
- Deliver one bounded versioned explosion cue.
- Project one GUI tree and map one button event to a declared
  `goal(DesiredState)`.
- Test disconnect, sequence gaps, owner failover, and slow clients.

Success means reconnect reconstructs models/GUI without replaying cues; unknown
descriptors fail closed; a client cannot forge identity, address undeclared
components, or submit goals; queues remain bounded.

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
