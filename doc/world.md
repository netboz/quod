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

## Mesh-backed Eidolons (planned)

The [mesh proposal](outdated/eidolon-mesh-support.md) extends the existing
class-selected Eidolon recipe, modelling and `mark/7` rendering path; mesh
rendering is not implemented. A mesh supplies geometry and appearance, not the
depicted entity or its authority. Keep the entity reference, recipe reference,
asset digest and view occurrence ID distinct. Start with a public, packaged,
validated, self-contained static GLB: one selected scene with triangle meshes,
transform hierarchies and approved PBR materials and embedded images. Animation,
skins, morphs, cameras, lights, external resources and unapproved extensions
need later declared capabilities. Imported submeshes inherit the occurrence's
authorized subject for picking; file metadata cannot create one.

Convert FBX and other authoring formats into that defined runtime profile with
a pinned toolchain. Record source and output digests, importer version and
options, validation profile, diagnostics and licence provenance. Conversion
stays outside consensus; accepted metadata and coupled appearance consequences
use the existing atomic transaction path. Prolog policy owns asset budgets;
runtime and browser checks enforce actual transfer, decode and rendering costs.
Asset acceptance checks profile conformance, materials and browser Content
Security Policy behavior. The browser verifies bytes and retains shared decoded
resources while occurrences use them. An unchanged or transform-only refresh
must not fetch or decode the same asset again. Private assets would require
authorized byte delivery: a digest grants no read access.

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
