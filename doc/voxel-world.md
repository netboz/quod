# Voxel terrain arithmetic

The numerical kernel uses the existing common compiled-predicate interface,
`'$quod_voxel'(Request, Allowances, Result)`, and the existing native physics
library. It reads only its arguments. World definitions, edit permissions,
material identities and allocation policy belong to the composing ontology.
The kernel creates no process, world, actor, transaction or durable geometry.

## Field version 1

The sampling request is
`sample(field_v1(Seed, Spacing, Operators, Material), Origin, Dimensions)`.
`Origin = vector(X,Y,Z)` names integer lattice sample coordinates;
`Dimensions = dimensions(Nx,Ny,Nz)` counts sample sites, not cells. X varies
fastest, then Y, then Z. Coordinates are multiplied by spacing using integer
arithmetic before evaluating the field. Negative noise coordinates use floor
division. Global coordinate hashing consumes the full signed magnitude; it
does not truncate positions to 32 or 64 bits.

`Seed` and operator salts are unsigned 64-bit integers. `Spacing` is an even
unsigned 32-bit millimetre value of at least 256. This is a numerical format
requirement, independent of authored work/allocation limits. Materials are
unsigned 16-bit identifiers supplied by the ontology.

The first operator is `plane(Height)` or `sphere(Centre,Radius)`. Subsequent
operators are `relief(Amplitude,Scale,Salt)`,
`volume(Amplitude,Scale,Salt)`, `carve_sphere(Centre,Radius)`,
`carve_tunnel(Start,End,Radius)`, `clip_box(Min,Max)` and
`material_below(Height,Material)`,
`biome_relief(ClimateScale,ClimateSalt,ReliefScale,ReliefSalt,Bands)` and
`caves(Scale,Salt,Width,RoofDepth)`.
Centres/endpoints and scalar distances are integer millimetres. Relief uses
the X/Z field; volume uses X/Y/Z. Ordered operators act on a signed scalar
field, negative in solid. Carving uses the maximum with the negated brush
field. These values are not a promise of exact Euclidean signed distance.

Biome bands are ordered `biome(Centre,Height,Amplitude,Top,Soil,SoilDepth)`
values. Centres strictly increase within [-65536,65536]. Climate noise blends
height, relief amplitude and soil depth with integer floor interpolation; the
nearest band chooses categorical materials (the lower band wins exact ties).
Outside the bands, the endpoint applies. Top versus soil follows depth below
the authored surface. `caves` carves around a 3D noise zero set while preserving
the requested roof depth. Its width is a fixed-point value from 1 to 65535.
Biome sampling charges one operator plus every band and 16 worst-case hashes
per sample; caves charge one operator and eight hashes. These costs participate
in the same authored sampling allowances.

Value noise uses Q=65536 fixed-point cubic smoothstep and floor-rounded
interpolation. A hash input is the ASCII prefix `quod-voxel-noise-v1`, then
big-endian unsigned 64-bit seed and salt, then each noise-cell coordinate in
X/Y/Z order. A coordinate is a sign byte (0 nonnegative, 1 negative), a
big-endian unsigned 32-bit byte count, then the minimal big-endian unsigned
magnitude (zero is one zero byte). The first big-endian 16 bits of SHA-256
map to `2*N-65535`. Per-batch memoization shares immutable corner values;
it supplies no hidden input or persistent terrain state.

For final scalar D and spacing S, the canonical density byte is
`clamp(2*floor(64*D/S)+1,-127,127)`. Every value is odd and nonzero; an exact
zero of the unquantized recipe becomes positive. This quantizer is part of
the world format, rather than a repair of an already generated mesh. Its
surface can differ from the unquantized recipe. An upgrade must not silently
change existing terrain samples.

The result `samples_v1(DensityBytes,MaterialBytes)` contains one two's-complement
signed density byte and one big-endian unsigned 16-bit material value per site
in separate buffers. Sampling admission is
`sampling_limits(Samples,OperatorEvaluations,HashEvaluations,PackedBytes)`.
The kernel checks the whole batch before output allocation, charging worst-case
hash evaluations even when memoization saves calls. Exhaustion identifies the
resource, required amount and allowance. A malformed request is an error;
there is no fallback field or substituted seed.

## Smooth surface version 1

`surface(Samples,Dimensions,Spacing)` takes
`surface_limits(Cells,Vertices,Triangles)` and returns the existing
`surface(Vertices,Triangles)` vocabulary. Vertices are integer millimetres
relative to the supplied sample origin. Cells have one fewer interval than
the sample count on each axis. The caller combines this exact local origin
with world coordinates; global positions never pass through floating point.
An empty result is valid numerical output, and is distinct from missing data
or proof of empty volume. Both uniformly positive and uniformly negative
fields have no internal surface triangles.

Topology follows the corrected MC33 table/case selection from
[Vega and Abache's MC33 implementation](https://github.com/dvega68/MC33_c_library),
pinned to commit `c479ac71fd2ff9c3cfd29fc6d026c80de95593fd` (5.5).
The attributed table and MIT license accompany the native source. Face tests
use exact integer products. Interior tests compare rational numerators using
signed 64-bit integers without division; the byte-density domain bounds all
intermediate products. Equality uses the pinned case selection's strict
comparison rule. Cells traverse Z/Y/X; each lattice edge gets one vertex
identity on first use. Cell-centre vertices are local to their cell.

An edge crossing is the exact fraction `abs(A)/(abs(A)+abs(B))` from its
lower-coordinate endpoint, rounded to the nearest millimetre with ties toward
the larger global coordinate. The bounded nonzero densities keep crossings
at least two millimetres from endpoints at the minimum spacing. Cell centres
are exact because spacing is even. Triangle winding points out of negative
solid; integer cross products reject degeneracy rather than deleting faces.
This defines a piecewise planar surface approximating the interpolated field,
not an exact curved representation of its zero set.

Use the same canonical triangle positions for rendering and collisions.
Volume classification for physical placement must agree with that quantized
surface, including the distinction between full and empty cells; triangle
contact absence by itself is insufficient evidence of clearance. The
numerical primitive alone does not install or certify physical coverage.

The ordinary common-primitive registration is release-coupled across proof
workers and validators. Unknown/missing native capability must fail explicitly.
The implementation plan remains the contract for world actions, retained
geometry, coverage, GUI composition and streaming; numerical arithmetic alone
does not enable those world features.

## Current patches and chunk inputs

The `chunk_v1(X,Y,Z)` format owns eight sample sites per axis, starting at
`8*(X,Y,Z)`. A cell chunk spans eight intervals and reads nine sites, plus a
one-site gradient halo on each side. `chunk(Field,Chunk,Overrides)` returns
11 cubed samples from `8*Chunk-1`. `chunk_surface(Samples,Spacing)` triangulates
only its eight owned intervals; halo cells never become duplicate surfaces.

`patch_v1(Bytes)` contains sorted records: a big-endian unsigned 16-bit local
site index, signed odd density byte and unsigned 16-bit material identifier.
Indices are `x+8*y+64*z`, strictly increasing and below 512. Missing records
mean the procedural value. Redundant records equal to that value are not
canonical. Restoring the procedural value removes the record; it does not
append an undo instruction.

`edit(Field,Chunk,Before,Brush)` accepts `dig_sphere(Centre,Radius)` or
`paint_sphere(Centre,Radius,Material)`. Digging takes the maximum of the current
density and quantized negated brush field. Its affected sample band extends
one spacing beyond the sphere. Painting uses the closed sphere and changes
only material identity. The result is
`edit_v1(After,DensityChanged,MaterialChanged,Consumers)`. A repeated identical
brush returns the identical patch, false flags and no consumers. Consumers
include the neighboring cell chunks whose surface or gradient halo reads a
changed sample; negative coordinates use floor division throughout.

`brush_chunks(Brush,Spacing)` enumerates owners under `chunk_limits(Maximum)`.
Editing takes `edit_limits(SamplingLimits,PatchBytes)`; halo sampling takes
`chunk_limits(SamplingLimits,PatchBytes)`, charging the supplied patch buffers
in aggregate. These numerical bounds do not replace transaction-envelope
validation or authorize splitting a brush into separate commits.

## Domain composition

The composable source is `priv/ontologies/voxel_world.pl`. Its owner supplies
creation/edit policy, existing physics configuration, initial chunk selection
and `voxel_allowances/2`. There are no default authority grants or allocation
limits. Classification alone allocates nothing. A world is an ordinary instance
of `voxel_world`, with one owned fixed terrain body allocated by the existing
monotonic physics allocator.

Chunk inputs select the current sparse override relation once, then validate
each present neighboring owner. Missing overrides mean procedural samples;
their absence remains an ordinary dependency. This avoids constructing empty
patch records for every neighbor of every generated chunk.

The allocation term is `voxel_limits(Sampling,Surface,Chunks,PatchBytes,GeometryBytes)`.
The last allowance bounds complete QVT1 outputs in aggregate for an authored
validation or resident selection; it is distinct from current patch storage.
Existing physical geometry allowances also apply to the entire installation,
including other bodies. Native installation and resource admission share the
same geometry accounting.

`voxel_create(World,ExpectedRevision,Spec)` creates a definition and validates
initial geometry in the same transaction as allocating that body. The current
specification is `terrain_v1(Extent,smooth,Field)`, where extent is `unbounded`
or `bounded(MinChunk,MaxChunk)` with exclusive upper chunk coordinates. Bounded
fields append the explicit clipping operator, including an outer closed shell.

`voxel_edit_basis/4` reads the current definition and all expected patch
revisions for an authorized brush. `voxel_edit/4` checks that exact basis,
replaces current patches, validates affected geometry, and advances the
existing physical structure/body fence in one ordinary transaction. A failed
validation rolls back the complete edit. No-op edits produce no mutations.
Painting preserves the physical fence. Empty patches retain their revision;
subtractive digging preserves checkpoints belonging to unchanged other bodies.

`voxel_lifecycle_basis/3` supplies the definition and all current patch
revisions for regeneration/removal. `voxel_regenerate/4` and `voxel_remove/3`
require explicit management policy and an otherwise empty physical world.
Occupants leave using existing withdrawal actions. Regeneration refuses any
existing patches; a new world preserves the edited landscape. Removal clears
patches atomically. Both reuse shared body replacement/removal consequences.
Removal retains a monotonic world revision; recreation uses the existing body
allocator. An obsolete basis, ambiguous patch state or failed geometry
validation refuses the entire transaction.

`voxel_world_gui.pl` composes the existing form/question/responder lifecycle.
Its immutable meadow, highlands and badlands presets compile to an explicit
field definition. The form exposes seed, detail, extent, bounded radius, biome
size, height and cave openness. Its continuation includes the exact world and
patch revisions, so an intervening dig invalidates submission. The application
supplies its GUI vocabulary, question policy and explicit actor ACLs; the world
belongs to the unique human named by that question policy.

`voxel_world_view.pl` composes with `space_view.pl`: the derived `terrain(World)`
subject is an ordinary space member whose class-selected Eidolon produces a
body-bound terrain part through the common modelling vocabulary. Authored
`voxel_presentation(World,Id,Palette,ViewDistance,Resources)` supplies appearance
and view policy. `voxel_set_view/3` compares the exact previous setting and
validates the replacement through the rendering vocabulary without revising
physical geometry. The excavation and viewing-distance forms use the same
question/responder lifecycle; see [application forms](gui-examples.md).

The lobby library creates owned smooth worlds through this composition. Its
creation transaction freezes catalogue-selected grass and ground textures into
the palette and creates an independently editable sky instance using the
existing environment Eidolon. Geometry, physics and terrain edits do not own
these appearance assets. Cubic integration is deferred.

The existing physics resource worker selects initial resident chunks from the
same verified snapshot as the ordinary bodies. `quod_voxel:prepare/5` consumes
the current field, chunk and overrides plus an optional retained artifact.
Equal input digests reuse the immutable native handle and complete payload;
they still check current output allowances, without sampling or triangulation.
The runtime retains these artifacts in its existing physical-world selection.
Failed materialization preserves and suspends the current owner and exposes the
specific failure through the ordinary resource diagnostics. A later valid
selection resumes the same run.

Mechanical demand uses the same selector. Missing coverage produces inclusive
chunk boxes for every current body plus the requested placement, motion sweep
or camera-clearance region. The existing runtime accepts notices only from its
current owner, run and structure, and fences selection against superseded
demand. Prolog selects initial coverage only until a consumer supplies its
regions, then admits their union under its resident chunk allowance. Startup
chunks do not remain permanent pins. Native installation rechecks coverage; retained ranges never
certify clearance by themselves. Unchanged or duplicate demand starts no work.
Chunk loading does not author a fact or create a durable body.

An input whose pure collision query encounters missing terrain remains pending
in the existing owner, with its original expiry and registration. The owner
cancels stepping until installation, prepares the normal collision index, then
processes the input. Disconnect and canonical invalidation retain their usual
cancellation rules. No retry timer discovers readiness, and elapsed waiting
time adds no catch-up motion.
The pending input retains its canonical query coverage as a mechanical
consumer until consumption or cancellation. The collision-index preparation
step cannot evict that coverage before the query runs. An expired discrete
input reports expiry and does not perform its requested movement.
Removing the viewer cancels its pending query coverage. The owner rechecks
native coverage once at a consumer or installed navigation-guard change;
the refreshed sample carries the installed structure even when bodies sleep.
Unfinished insertion and stale navigation sources keep their original waits. An unchanged collider selection
cannot leave a cancelled query as the world's only reason to stay paused.

## Retained native geometry

`voxel_prepare/5` on the existing native library builds immutable chunk data,
its cell/triangle index, optional Rapier surface and complete render payload.
Its opaque resource handle is local consumer storage, never a durable identity.
The final argument supplies zero or one retained artifact. Equal consumed
density and spacing share the original immutable cell index, mesh and Rapier
shape while rebuilding only the material-bearing payload. Current vertex,
triangle and byte allowances still apply; no triangulation-cell work is charged
when collision data is reused. Empty and full chunks retain their volume
classification even with no collider.
The native terrain geometry installs those constituent colliders under one
fixed body. Residency changes preserve that body's identity; authored revision
changes retain unchanged constituent colliders.

The `QVT1` payload uses a 16-byte header (magic, unsigned 32-bit spacing,
triangle count, shared vertex count) followed by 38 bytes per triangle: nine unsigned
32-bit local millimetre coordinates and one unsigned 16-bit material identity,
all big endian. The profile uses flat face shading. The nearest-to-surface
negative corner chooses a cell's material, with coordinate-order ties.
Packing requires `8*Spacing` to fit unsigned 32 bits. Eight-cubed MC33 cells
have at most 6,144 triangles, so the complete payload is at most 233,488 bytes
before transport encoding. This format bound is separate from authored byte
allowances and the complete socket-message limit.

Placement queries require resident coverage of the whole queried body, an
air point in each connected solid part, and the existing triangle-penetration
checks. Point classification uses segment parity anchored at known lattice
corners and adaptive exact orientation signs against the quantized triangles.
Unresolved boundary/coplanar cases are unavailable, never inferred air.

Before integration, dynamic-body demand conservatively includes Rapier's
existing post-solver speed bound for the whole timestep and a sphere enclosing
every orientation about the centre of mass, including an off-centre body's origin. The same envelope
is checked against the active coordinate window before integration. The owner
can shift its local frame and retry the unperformed step; an envelope that
cannot fit remains unavailable without altering motion or incarnation.
Controlled movement already uses
the existing translation/rotation sweeps. New geometry and authored pose changes
are admitted against whole-body surface penetration before integration, using
the solver's numerical contact tolerance. Retained bodies are checked against
new or changed oriented faces; exact unchanged faces remain under the solver
even when their chunk collider is rebuilt. The comparison keeps the last
integrated surface as its baseline until a step succeeds, so a blocked edit
cannot certify its own geometry through another edit. New bodies and authored
pose changes still check the complete surface. The solver's correction target
is not a hard penetration limit on later steps. Interior-point classification
still runs before every active step.
Signed placement queries retain their separately authored tolerance.

Missing coverage waits for concrete required chunks. Known obstruction reports
`terrain_occupied(Body,Terrain)`; ambiguous classification/contact reports
`terrain_unavailable(Body)`. These block integration while retaining the native
world and its motion, without emitting an empty coverage demand. An unchanged
selection does no installation work; a governed body or terrain correction
rechecks admission in the same incarnation. Fatal native errors keep their
ordinary retirement semantics. Coverage installation and corrective selection
changes wake work through the existing owner lifecycle, without a retry timer.
An unchanged checkpoint insertion that is already waiting retains its previous
terrain demand explicitly; it does not emit an empty replacement request.

## Authorized terrain rendering

A common `terrain` mark uses
`terrain_geometry(<<"qvt1">>,Palette,view_distance(Distance,Prefetch,Retention),resources(Transfer,Geometry,Vertices,Triangles,Chunks))`,
`terrain_surfaces`, an anchored subject and an ordinary body/revision pose.
The palette contains ordered `material(Id,Surface)` entries using the same
`surface(Colour,Metallic,Roughness,Emission,Textures)` contract as ordinary
marks. Both share one PBR binding implementation and the existing verified
texture leases. Dominant-face planar texture coordinates cover floors, walls
and overhangs. Their phase is derived from exact canonical coordinates, so
negative chunk boundaries and local frame rebases preserve texture placement.
The renderer allocates 108 bytes of vertex/index buffers per triangle.
The current surface profile has flat face normals and categorical material
boundaries; planar projection can leave seams where the dominant axis changes. The signed mark
selects the terrain body and allocation; the current installed simulation,
its retained source guard and the exact view registration bind its immutable
chunk outputs. Marks and descriptor proofs contain no generated triangle list.

The existing signed view shares one delivery credit between physical frames
and terrain resources. A bounded manifest names current chunks, canonical
origins, content digests and measured costs. The browser discards obsolete
leases and requests only missing indices. The owner delivers those indices in
ordered content batches that each fit the existing encoded view-message limit.
The manifest's Prolog transfer and geometry allowances still bound the whole
window. The shared terrain serializer also measures the envelope and rejects
an oversized manifest or individual chunk before delivering the manifest.
The browser verifies each requested prefix and all digests before installing
new bytes, then acknowledges its last index after rendering. Only the final
batch carries completion; a fully retained window receives one empty final
batch. Early completion and acknowledgements for another batch release no
credit. There is no network round trip per chunk. A fresh physical frame alternates with resources on that
same credit between acknowledgements; each outstanding delivery retains that
credit until its own acknowledgement.
Watch/reference and manifest tokens make stale acknowledgements harmless.
Replacement and expiration use the same view lifecycle. No public asset route
or durable generated-blob service is involved.

The browser resource owner validates QVT1 framing, coordinates, winding,
nondegeneracy, materials, measured allocation and digest before constructing
an ordinary model template. Terrain occurrences lease and instantiate those
models through the existing scene reconciler. Verified content becomes visible
when installed; requesting a new window does not hide retained geometry.
Navigation waits for the complete current manifest while its physical camera
binding and held input remain intact. An uninterrupted, unexpired authorization
renewal keeps verified terrain visible only when the physical fence and full
terrain marks, including resource allowances, are unchanged. Invalidation or a
changed binding hides the old terrain until the new manifest confirms it.
Equal content retains its model; removed chunks release instances and leases.
The authenticated view connection accepts monotonic `terrain_interest` messages
bound to its exact view digest, watch and absolute expiry. Their centres are
canonical decimal integer millimetres. Distance, prefetch and retention come
from the signed mark, never the request. The owner selects the distance plus
prefetch box, retaining already-resident chunks within the larger retention
box. Before numerical generation, it checks the signed chunk allowance and
whether the proposed visual regions, current body poses and physical terrain
consumers fit one admissible local frame. This permits ordinary rebasing at
arbitrary absolute coordinates. An incoherent request is refused for that
viewer without invalidating the shared world. Malformed terrain bindings also
return an explicit refusal. Visual and physical consumers share materialization; delivery includes only that
view's regions, while distant bodies retain their collision support.

Camera movement requests another window after crossing the prefetch margin;
there is no readiness polling. Common linear fog ends at the authored distance.
Sky panoramas use the existing environment marks and verified texture leases,
follow the viewer through their authored parent transforms, render before
foreground geometry without writing depth, and remain outside terrain fog.
Their unlit surface applies authored brightness once. The camera retains its ordinary far plane so the panorama is not
clipped by the terrain viewing distance. Fog takes the authored atmosphere tint
and brightness when present. Manifests carry the acknowledged interest sequence.
An older manifest or a checksum finishing after camera movement releases only
its own delivery credit and cannot mark the newer window ready. Viewer
disappearance reclaims its regions through the existing owner notification;
body and tracked-eye clearance requirements remain. Mere exploration writes no
domain state. Current patches reconstruct an edited chunk after eviction or
runtime restart.

Within each admitted selection, nearby chunk shells are prepared and delivered
first; direction of travel breaks ties before distance within that shell.
The current view owner derives this direction from successive accepted camera
centres. Integer comparisons preserve ordering at large canonical coordinates.
This is an ordering of the existing admitted set, not extra demand or a second
worker. Physical installation keeps canonical chunk order, and visual readiness
still requires the complete current manifest. Changed priority alone does not
restart generation when the required regions are unchanged.

## Exact world coordinates and local frames

Authored positions and terrain addresses are arbitrary-size integer millimetres.
The shared coordinate adapter subtracts the exact world origin before converting
to native metres. The existing coordinate allowance bounds the complete active
window and local geometry, rather than the world's distance from zero. The
origin aligns to every installed terrain chunk lattice. An active set that
cannot fit its allowance remains unavailable; it is not silently truncated.

The existing native installation accepts the origin delta with its body
selection. It validates the complete change before moving retained bodies,
colliders and the query index. Reframing preserves body/joint handles, velocity,
motor state, world incarnation and control registration. Retained authored
insertion poses remain identity inputs, never a reason to reset live movement.
Absolute movement inputs stay canonical until execution, including queued
commands created before a shift.

Physical socket frames use schema 2, `space: local`, metre/second values,
decimal-string `origin_mm` and `origin_seq`. Origin changes can publish without
advancing simulation time. Acknowledgements bind both tick and origin sequence,
so an old frame cannot release the new frame's credit. Terrain manifests retain
canonical origins; the browser subtracts with BigInt before converting local
positions. Reframing moves retained visual instances and observer cameras.
Governed live-query results carry `local_metres_seconds(vector(X,Y,Z))` with the
same origin; signed rest checkpoints retain exact canonical millimetres.

Checkpoint restoration waits through the existing coverage lifecycle when its
destination is missing. It does not publish a baseline as the restored pose or
retire the simulation because terrain has not arrived. Current solid overlap
still rejects recovery. A saved zero velocity without current supporting contact
wakes normal integration, allowing an object whose support was dug away to fall.
An unchanged installed checkpoint never restores or rebuilds its body again.

## Local geometry preview

`scripts/voxel-preview.escript` generates a bounded inspection fixture through
the production sampling, editing and native preparation paths.
`client/tools/voxel-preview.html` displays the verified fixture through ordinary
render resources and scene reconciliation, with orbit views, wireframe and an
excavation comparison. It does not create or edit a live ontology.

Serve `client` with Vite, using `../priv/explorer` as its public directory and
excluding `**/_build/**` from filesystem watching. This exposes the existing
content-addressed texture assets to the preview. The two unmodified Babylon
playground JPEG samples and their notices originate in
`ui/public/assets/textures/`. The ordinary UI build copies them unchanged into
`priv/explorer/assets/textures/`; `babylon-samples.md` records provenance and
`SOURCES.json` records each asset's own license and digest.
