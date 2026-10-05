# Client and world direction

The current browser foundation has key handling, authentication, signed
Prolog goals, retained answer cursors, unresolved-operation resolution and
Explorer. Bundled ontologies define rendering, modelling, material,
environment and lobby vocabulary. Client code can render supported
descriptors and assets. These pieces do not yet make a complete shared
simulation or editable VR world.

The intended world model keeps semantic facts, permissions and meaningful
consequences in ontologies. Scene indexes, meshes, visibility, interpolation
and per-frame physics working state are rebuildable or transient. Physics
measures interactions; ontology rules decide their domain meaning and
durable consequences. Ordinary and immersive clients consume bounded
projections of the same world state.

## Mesh-backed Eidolons

The implemented [mesh contract](eidolon-mesh-support.md) extends the existing
class-selected Eidolon recipe, modelling and `mark/7` rendering path. A mesh
supplies geometry and appearance; the anchored Prolog subject, recipe, asset
digest and view occurrence remain distinct. The default lobby's Prolog console
uses a packaged `console.glb` in its playing view while keeping its existing
subject and actions. The edition view retains its structural recipe.

The first profile admits public, self-contained static GLB with triangle
meshes, transform hierarchies, core PBR materials and embedded PNG/JPEG images.
It rejects animation, skins, morphs, cameras, external resources and extensions
before loading. Prolog policy owns resource allowances; the client verifies the
digest and measured use, shares one decoded template, and gives each placement
its own transform and picking identity. Imported names and metadata cannot
create subjects or permissions. A pinned offline workflow converts FBX, glTF,
OBJ, STL and polygon PLY and records conversion diagnostics and provenance.
Private assets still require authorized byte delivery and publication; a
digest grants no read access.

A later shared world projection may compose scene transforms and index visual
bounds. The physics authority owns transient body motion; visual bounds and
colliders may differ. Motion frames must be filtered through each agent's
authorized view. Physics observations must be authenticated before they enter
ordinary Prolog actions. Current transaction sealing rejects a live physics
query in a proof that makes durable changes. The archived
[consequence direction](outdated/world-consequence-direction.md) still sketches
that live-query path; it is superseded by this sealing constraint.

The complete scene projection, synchronization, physics authority, automatic
lobby provisioning, headset interaction and world editing milestones remain
to be implemented and validated. The archived
[client/world direction](outdated/client-world-direction.md) contains further
proposals, not a claim that those layers are deployed.

The current client lives under `client/` and the shared browser shell under
`ui/`. The server's TLS client endpoint is `src/quod_client.erl`.
