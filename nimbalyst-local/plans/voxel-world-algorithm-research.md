# Voxel world algorithms: research and selection

Research date: 2026-10-16. This is an algorithm survey for the [Quod design](voxel-world-generation-ontology.md), not a performance measurement. Recommendations below are engineering judgments from the cited sources and Quod's current implementation.

## Separate four choices

A voxel is a volume sample, not necessarily a cube drawn on screen. Four independent decisions matter:

1. **Representation:** occupied cells/materials, or a sampled signed scalar field plus materials.
2. **Generation:** noise, geological layers, cave operators, climate and authored structures.
3. **Surface extraction:** cubic face meshing, Marching Cubes, Surface Nets or Dual Contouring.
4. **Storage and residency:** dense blocks, sparse chunks, octrees/VDB, and which derived blocks a consumer retains.

“Modifiable” is an ownership/editing contract, not a meshing algorithm. A procedural base becomes editable by composing it with current committed sample overrides; selecting a static mesh algorithm alone does not provide durability or digging. Voxel Tools' maintainers describe separate generators and meshers and distinguish block/material channels from signed fields. [Generator documentation](https://voxel-tools.readthedocs.io/en/latest/generators/)

## Representation and storage comparison

| Approach | Strength | Limitation for this request | Selection |
| --- | --- | --- | --- |
| Heightfield, including fractal heightmaps | Compact, good continental and mountain structure | One height per horizontal location cannot represent general caves, roofs or overhangs | Use as one input to a volume, not the world representation |
| Occupancy/material cells | Exact cubic editing, straightforward material identity | Stair steps; smooth shape information is absent | Cubic interpretation of the common volume |
| Signed scalar field + material samples | Smooth surfaces, boolean carving, caves and overhangs | More samples; quantization and material boundaries need explicit rules | Recommended common model |
| Dense whole-world array | Simple indexing | Memory grows with volume even in untouched regions | Reject as durable primary state |
| Sparse regular chunks + procedural base | Local edits and rebuilds; simple ownership and seams | Needs halos and explicit finite residency policy | Recommended first storage structure |
| Adaptive octree / sparse voxel DAG | Spatial compression and multiresolution access | More complex dynamic edits, neighborhood traversal and seams; DAG sharing complicates mutation | Defer until measured need |
| OpenVDB | Mature sparse hierarchical volume processing, uniform tiles and level-set tools | Adds a substantial library/data model; not Quod's authority or recovery system | Reference design; do not introduce as a second world owner |

The limitations of heightfields and the possibilities of 3D density functions are illustrated by NVIDIA's original terrain chapter. OpenVDB documents its hierarchy, tiles, background values and index/world transform separation. Neither source establishes that its implementation is the fastest option for Quod. [NVIDIA terrain chapter](https://developer.nvidia.com/gpugems/gpugems3/part-i-geometry/chapter-1-generating-complex-procedural-terrains-using-gpu), [OpenVDB overview](https://www.openvdb.org/documentation/doxygen/overview.html)

Use the term **signed density field** in the specification. Noise, blending and arbitrary edits generally do not preserve an exact signed-distance function. Sign and zero crossings are sufficient for meshing; distance-based sphere tracing would require additional guarantees. [Voxel Tools' signed-field explanation](https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/)

## Surface extraction comparison

| Algorithm | Suitable output | Useful properties | Cost/risk | Quod recommendation |
| --- | --- | --- | --- | --- |
| Exposed cubic faces + greedy merging | Exact axis-aligned blocks | Merge compatible coplanar faces; preserve material boundaries | T-junctions, normals and face compatibility require tests; not globally optimal | Cubic profile |
| Original 256-case Marching Cubes | Smooth sampled surfaces | Local, well understood | Ambiguous configurations can produce inconsistent topology | Do not select the naive table |
| MC33 with corrected interior tests | Smooth sampled surfaces | Resolves face/interior ambiguity against the sampled interpolant | Historical implementations have errors; quantization still needs validation | Recommended initial smooth profile, uniform resolution |
| Marching Tetrahedra | Smooth sampled surfaces | Small local case set | More triangles and directional subdivision effects | Alternative, not a parallel production fallback |
| Surface Nets | Smooth / soft low-poly surfaces | Simple dual construction and attractive mesh size | Thin features, cell connectivity and vertex positioning need care | Considered; not initial selection |
| Dual Contouring | Sharp features and authored hard surfaces | Hermite intersections/normals and QEF placement preserve features | QEF conditioning, topology and adaptive seams add work | Defer; sharp construction can remain ordinary entities |
| Transvoxel | Smooth terrain across adjacent LODs | Transition cells connect 2:1 sample resolutions | Requires compatible regular-cell topology and strict boundary rules | Revisit for large streamed worlds; not a drop-in MC33 add-on |
| Direct raymarching | Procedural rendering | Can avoid a render mesh | Does not supply the existing Rapier surface collider or mesh picking contract | Not the shared terrain path |

Sources supporting these distinctions:

- Greedy meshing merges exposed quads within compatible slices; it does not guarantee a minimum polygon mesh. Our material/lighting compatibility keys must be part of the merge rule. [Original author article](https://0fps.net/2012/06/30/meshing-in-a-minecraft-game/)
- Lewiner et al. describe an implementation of Chernyaev's MC33. Later work by Vega, Abache and Coll identifies interior-test errors in that implementation and defects in a subsequent correction, and supplies a corrected treatment. Use the latter's cases as required regression material, including 10.1 and 13.5, rotations and sign complements. An algorithm label is not a correctness certificate. Topological reasoning concerns the sampled interpolant; it does not prove that a below-resolution tunnel survives sampling or millimetre quantization. [Lewiner publication](https://thomas.lewiner.org/pub/marching_cubes_jgt.html), [Vega et al., JCGT 2019](https://jcgt.org/published/0008/03/01/paper.pdf), [author's current MIT-licensed C implementation](https://github.com/dvega68/MC33_c_library)
- The original Dual Contouring paper places vertices from edge intersections/normals using quadratic error functions and supports adaptive contouring. [Ju, Losasso, Schaefer and Warren, 2002](https://people.eecs.berkeley.edu/~jrs/meshpapers/JuLosassoSchaeferWarren.pdf)
- Original constrained elastic Surface Nets adjust nodes subject to their surface-cell constraints. A simple non-iterative Surface Nets implementation is a distinct variant, not that original relaxation algorithm. [Gibson, MERL TR99-24](https://www.merl.com/publications/TR99-24), [implementation author's comparison](https://0fps.net/2012/07/12/smooth-voxel-terrain-part-2/)
- Transvoxel fills boundaries between meshes sampled at a factor of two using transition cells and local sample data. Combining it with a different regular-cell topology requires compatibility evidence. [Algorithm author's description and tables](https://transvoxel.org/)

**Selection:** one common volume, editing model and material vocabulary; smooth and cubic are intentional surface profiles, each with one mesher. They are not two domain engines. Prioritize the smooth profile unless Yan chooses otherwise. Make surface interpretation explicit and stable for a world; changing it is a physical regeneration, not a shader toggle.

## Terrain generation

### Noise families and composition

- **Gradient noise / improved Perlin:** useful smooth low-frequency structure; axis artifacts and octave cost require attention.
- **Simplex/OpenSimplex families:** alternative sampling geometry; useful for isotropic-looking 3D fields. They do not by themselves create geology or connected caves.
- **fBm:** weighted octaves at increasing frequencies. Good hills and multiscale variation; excessive octaves mostly add cost or aliasing below voxel spacing.
- **Ridged transforms:** fold noise to emphasize crests and mountain chains.
- **Domain warping:** perturb coordinates before sampling to reduce regular-looking contours.
- **Cellular/Worley fields:** useful region boundaries, pillars, fractured terrain and mineral patterns.

FastNoiseLite documents these operations and offers a portable implementation under MIT. It is a candidate numerical dependency, not a source of policy. Portability and a seed do **not** establish bit-identical floating-point results across every compiler/architecture. Pin versions and numerical semantics or use a specified integer/fixed-point implementation before outputs enter sealed terrain state. No dependency is selected solely from its benchmark claims. [Upstream repository](https://github.com/Auburn/FastNoiseLite), [upstream parameter documentation](https://github.com/Auburn/FastNoiseLite/wiki/Documentation), [original improved-noise implementation discussion](https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-26-implementing-improved-perlin-noise)

Recommended base: low-frequency continentalness + biome-blended height parameters + ridged mountains/domain warp, lifted into `D(x,y,z) = y - H(x,z)`, then composed with genuinely 3D overhang, arch and cave operators. Flat, terraced and island envelopes are parameters/recipes. Generation uses absolute integer coordinates and stable per-feature salts; chunk visitation order must not consume a shared PRNG.

After inspecting BBSvx, select its **integer hash/value-noise approach** as the initial numerical basis, generalized to 3D and parameterized fBm/ridged composition and domain warp. Its existing implementation uses Squirrel3 hashing, scale-1024 fixed-point arithmetic and cubic smoothstep. Those are useful concrete starting points, not proof that its existing 2D generator already provides the desired caves. Fix rounding, full-coordinate mixing and numerical vectors in Quod's versioned format; do not wrap an unbounded coordinate identity silently to 32 bits. FastNoiseLite remains a reference/candidate if an alternative is justified; it is not an installed dependency or parallel generator.

### Caves

| Technique | Character | Boundary/connectivity issue | Use |
| --- | --- | --- | --- |
| Thresholded 3D noise | Caverns and porous formations | No guarantee of entrances, traversable diameter or one connected network | Optional cavern layer |
| Intersecting noise bands / warped tubes | Worm-like tunnels | Need explicit depth, thickness, termination and halo support | Recommended procedural tunnel layer |
| Authored tunnel graph + capsule/sphere carvers | Controlled connectivity and deliberate entrances | Graph generation needs bounded work and cross-chunk ownership | Small optional guaranteed route through an authored world |
| Cellular automata | Organic cave rooms | Iterative neighborhood dependence; chunk edges need fixed iterations and sufficient halos | Research alternative, not initial core |

Voxel Tools demonstrates subtractive noise worms, vertical perturbation and low-frequency modulation for dead ends. This shows an approach, not a proof of cave connectivity. Quod should expose connected routes as an explicit additional requirement rather than claim that a noise threshold guarantees them. [Maintainer's cave construction](https://voxel-tools.readthedocs.io/en/latest/procedural_generation/)

### Biomes and underground ecology

Use independent climate fields (temperature, moisture, continentalness, elevation), stable biome IDs and authored weights/eligibility. Blend continuous terrain parameters before sampling the surface; choose discrete material IDs deterministically. Surface color alone is not a biome implementation. Underground biomes add depth/geology and cave context, so a warm coastal surface can sit above limestone caverns or a deep basalt layer.

Luanti's public biome schema uses temperature/humidity points with a Voronoi interpretation and vertical ranges/blending. Quod can build on that idea without importing Luanti's resource caps or node model. [Luanti biome definitions](https://api.luanti.org/definition-tables/#biome-definition)

### What to keep separate

Hydraulic/thermal erosion introduces nonlocal/iterative work; an erosion-looking ridged preset is not an erosion simulation. Water surfaces, flowing liquids, falling unsupported terrain and weather are independent behaviors needing their own existing-domain composition. Wave Function Collapse is useful for local adjacency constraints on tiles or structures, not a replacement for the continuous geological field; contradiction handling and bounded search would be additional policy. [Original WFC project](https://github.com/mxgmn/WaveFunctionCollapse)

## Performance and implementation conclusions

1. Avoid a Prolog fact, renderer mark, Erlang process or rigid body per voxel. Use regular chunks, packed current overrides and one retained derived surface per participating nonempty chunk.
2. Keep untouched terrain procedural. Keep current overrides rather than replaying edit operations to answer ordinary queries. Historical edits remain in the existing ledger.
3. Generate/mesh only new or changed chunk dependencies. A boundary edit includes the exact neighboring halo consumers. An unchanged refresh must perform zero generation, triangulation, native replacement and storage writes/syncs.
4. A pure native batch kernel is reasonable to evaluate. Existing physics already uses Rust/Rustler; C/C++ is also permissible if it wins a measured case. Do not create simultaneous Erlang and NIF production fallbacks.
5. Long native CPU work belongs on dirty CPU schedulers or bounded resumable calls; dirty scheduling alone does not make an unbounded job cancellable. Preserve the proof/resource worker's absolute deadline and charge work before allocation. [Erlang NIF documentation](https://www.erlang.org/doc/apps/erts/erl_nif.html)
6. Support Yan's requested **bounded and unbounded** modes through the same field and owners. Establish the shared kernel on bounded fixtures first, then deliver movement-driven unbounded residency in the same planned feature. “Infinite” procedural coordinates do not mean an infinite collider set is resident. View-distance streaming does not inherently require mixed-resolution LOD; start at uniform resolution, then evaluate Transvoxel only if measurements justify changing that decision.

For scale intuition only: a `16³` sample block with two 16-bit channels occupies `16,384` raw bytes; `32³` occupies `131,072`. These are illustrative codec choices, not population/budget limits or measured costs. Halos, material palettes, native shapes, mesh buffers and multiple consumers add to them. The final codec and chunk dimensions require the implementation spike.

## Research boundaries

No benchmark, production code, dependency installation, deployment or live world mutation was performed for this survey. Yan accepted the shared geometry/residency extension scope described in the plan; implementation has not started. Current physics supports uniform gravity and a single local authorized view profile; this research does not turn spherical planets or remote multi-viewer physics into existing capabilities.

## BBSvx source review and lessons

Yan explicitly requested inspection of the sibling BBSvx repository. The following findings come from source reading on 2026-10-16; none of its demos/benchmarks was run, and comments about timings are not imported as Quod evidence.

| BBSvx source | Useful design | Quod treatment |
| --- | --- | --- |
| [Voxel ontology](/home/yan/src/bbsvx/priv/ontologies/bbsvx_voxel.pl) | Seeded Squirrel3 hash, fixed-point value noise/fBm, strata, surface biomes and ore selection | Adapt pure numerical ideas; parameterize the authored constants, extend to genuine 3D density and climate/depth biomes |
| [Greedy mesher](/home/yan/src/bbsvx/priv/ontiris/src/voxel/GreedyMesher.ts) | Padded chunk input; six directional sweeps; material/AO-aware merges; winding rules | Reuse algorithm and fixture obligations in the one cubic mesher, under Quod's canonical coordinates/material vocabulary |
| [Chunk manager](/home/yan/src/bbsvx/priv/ontiris/src/voxel/ChunkManager.ts) | Dirty chunks, generation-tagged stale-result rejection, removal of empty meshes | Retain these lifecycle invariants inside Quod's existing resource/view owners; do not import a second client world inventory |
| [Chunk loader](/home/yan/src/bbsvx/priv/ontiris/src/voxel/ChunkLoader.ts) | Near-first spiral priority, distinct load/unload radii, reset epoch and cancellation | Keep prioritization, hysteresis and stale-result invariants; drive work from movement/owner notices rather than its interval/retry loop |
| [Mesher tests](/home/yan/src/bbsvx/priv/ontiris/test/GreedyMesher.test.ts) | Empty chunk, normal/winding, merging and mixed materials | Port the still-valid obligations, add real-owner seams, caves, atomic edits and streaming safety |
| [WASM tests](/home/yan/src/bbsvx/priv/ontiris/test/terrain-wasm-benchmark.test.ts) | Explicit numerical consistency/negative-coordinate concerns | Use deterministic vectors for Quod's one kernel; do not infer cross-engine equivalence from comments/test names |

BBSvx's [terrain generator](/home/yan/src/bbsvx/priv/ontiris/src/voxel/TerrainGenerator.ts) loads a patched subset of ontology source into client SWI-Prolog/WASM. Its [voxel predicates](/home/yan/src/bbsvx/src/ontologies/bbsvx_voxel_predicates.erl) retain a deprecated block-assertion path alongside a collider-only path. The current column generator emits the surface and three subsurface layers; this is not a complete cave-capable volume. The inspected loader renders local generation before requesting server colliders, and disables collider requests after a non-abort failure. A timeout cannot establish that a predicate is absent. Those mechanisms do not meet Quod's current authority, exact-operation or unavailable-geometry rules and should not be ported.

Other necessary adaptations: BBSvx's inspected chunk manager ignores the namespace argument in its block setters and treats clearing as single-namespace; palette IDs are assigned in discovery order. Quod keys every consumer result by anchored world identity and canonical material ID. BBSvx's coordinate hashes mask the combined position to 32 bits; Quod must specify large-coordinate behavior. The [configuration observer](/home/yan/src/bbsvx/priv/ontiris/src/voxel/VoxelConfigObserver.ts) ignores retractions and updates seed from generic attributes; Quod uses its complete verified revision/dependency lifecycle. No BBSvx file was modified.

For bounded-world aggregation later, retain exact world identity, local integer lattice/frame, immutable recipe version and explicit bounds now. Joining patches still needs authored seam/overlap rules, authorization at every owner, and one chosen simulation authority for shared contacts. Existing space membership alone does not supply coordinate stitching or shared physics.
