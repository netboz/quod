---
archivedPlan:
  planStatus:
    planId: plan-voxel-world-generation-ontology
    title: Voxel world generation ontology
    status: in-progress
    planType: system-design
    priority: medium
    owner: yan
    stakeholders: []
    tags: [ontology, voxel-world, gui, physics]
    created: "2026-10-16"
    updated: "2026-10-16T17:20:10.773803+00:00"
    progress: 80
---

# Voxel world generation ontology

## Objective and scope

Create varied, persistent, editable voxel terrain as an ordinary Quod domain: hills, islands, plateaus, arches, underground caves and climate/geology-driven biomes. Users configure worlds through the existing GUI and dig through authorized actions. Terrain participates in existing collision, ontology recovery, transactions, rendering and reaction lifecycles.

Implementation is authorized by Yan’s subsequent request. Commit, deployment and live-state mutation retain their separate authority requirements. The selected scope includes both smooth and cubic terrain, with smooth first, and **both bounded worlds and unbounded worlds generated to view distance as the player moves**. Aggregation of different users' bounded worlds into a patchwork is a later feature. Yan accepted the necessary generated-geometry, streamed-collision and moving-view/local-coordinate extensions inside the existing owners, as specified below.

Recommended design: chunked bounded/unbounded worlds; smooth terrain first and a cubic profile using the same volume/editing model; seeded procedural base plus current sample overrides; MC33 with corrected interior tests and greedy cubic meshing; fixed terrain surfaces through existing Rapier ownership. Reuse BBSvx's deterministic integer hash/value-noise design and chunk-lifecycle lessons. Detailed alternatives, primary sources and the BBSvx source audit are in the [algorithm research](voxel-world-algorithm-research.md).

Cubic integration is deferred at Yan's request pending inspection of his Minecraft
PBR texture packs. Block geometry is generated from the shared volume; those
packs are potential appearance assets, not the terrain generator. The isolated
cubic mesher prototype is retained only in historical evidence, outside the
production native module. Smooth terrain uses the common surface/PBR contract
and verified texture owner. Babylon grass/ground samples are available in the
local geometry preview; Minecraft pack interpretation remains deferred until
the actual assets are inspected.

## 1. Existing implementation and reuse obligations

Read the repository [working agreement](../../AGENTS.md), [multiwrite contract](../../doc/multiwrite-architecture.md), [world authority contract](../../doc/world.md), [spaces](../../doc/spaces.md), [native physics profile](../../doc/physics-native.md) and [GUI examples](../../doc/gui-examples.md) before implementation.

| Need | Existing owner/seam | Required reuse |
| --- | --- | --- |
| Classes, instances, domain policy | [common predicates](../../priv/ontologies/common_predicates.pl), [space bundle](../../priv/ontologies/space.pl) | Class-first `instance_of/2`, authored inheritance, exact anchored identity |
| Governed edits | [proof contract](../../doc/proofs.md), [physics definition transitions](../../priv/ontologies/quod_physics.pl) | Signed goals, normal ACLs, staged reads, savepoints, sealed ordinary/atomic transactions |
| GUI forms | [GUI vocabulary](../../priv/ontologies/quod_gui.pl), [form composition](../../priv/ontologies/gui_instance.pl) | Existing schema, field binding, question/responder/HUD completion and stale-form guards |
| Physical structure and collisions | [physics ontology](../../priv/ontologies/quod_physics.pl), [physics owner](../../src/quod_physics.erl), [native geometry](../../native/quod_physics/src/geometry.rs) | Fixed `surface(Vertices,Triangles)`, existing run/structure/body fences, motion and gravity |
| Projection and readiness | [runtime](../../src/quod_runtime.erl), [resource dependencies](../../src/quod_resource_basis.erl) | Existing `physics_worlds`, retained verified sources, scoped installed notices, absolute deadlines |
| Visual appearance and selection | [space view](../../priv/ontologies/space_view.pl), [rendering vocabulary](../../priv/ontologies/quod_rendering.pl), [scene adapter](../../client/src/scene.js) | Eidolon → model → mark; anchored `depicts`; existing signed view invalidation |
| Retained client resources | [render resources](../../client/src/render-resources.js) | Consumer leases, stable occurrences, stale asynchronous result disposal |

Verified constraints: fixed triangle surfaces already support slopes and holes; moving triangle-mesh solids do not. Body IDs are allocated monotonically. Geometry/body revisions install together. Current physical observations use a conservative whole-world structure fence and per-predicate OCC. Live native queries cannot authorize a durable terrain edit. The currently documented physical view profile is one local authorized view; general streamed multi-viewer worlds are not already delivered.

No existing voxel generator or terrain ontology was found in production source. The project-knowledge MCP index returned no relevant chunks; repository source is the basis of this integration map. Tracker search found no existing open voxel item; this plan does not create a duplicate tracker record.

## 2. Domain model and naming

`voxel_world` is a useful implementation-facing class name. Show **Terrain world** in the GUI. Keep world types and world instances distinct:

```prolog
isa(voxel_world, physical_space).
isa(bounded_voxel_world, voxel_world).
isa(unbounded_voxel_world, voxel_world).
isa(archipelago_world, voxel_world).
isa(cavern_world, voxel_world).
instance_of(archipelago_world, emerald_reach).
```

An instance is one world. Subclasses describe reusable world kinds, not one subclass per generated world. Existing multiple inheritance can combine bounded/unbounded mode and a terrain family. Exactly one extent mode must be selected. A world may extend without authored horizontal bounds while retaining an authored vertical envelope; the spec must say so rather than imply an infinitely deep resident volume. Existing multiple inheritance can express an editable or protected world policy without making those names runtime flags that bypass ACLs. Class membership alone enables neither simulation nor editing.

Implement a composable domain bundle, following `space.pl` and the existing GUI applications. Do not automatically found a new system ontology or require one ontology per world/chunk, or a new terrain process. Simulated worlds keep the current adapter's dedicated physics actor and retained simulation resource per enabled world; chunks introduce no processes. A shared catalog may later publish anchored recipe/biome definitions through ordinary ontology composition. Concrete worlds initially share their owning ontology with their terrain state and physics structure; foreign admitted entities continue through existing anchored live-definition transactions.

Proposed semantic relations (design names, not installed API):

```prolog
voxel_world_definition(World, Revision, VersionedSpec).
voxel_chunk_override(World, ChunkCoordinate, Revision, CanonicalCurrentPatch).
voxel_terrain_binding(World, BodyId, PhysicalRevision). % derived from existing physics binding
voxel_material(MaterialId, Properties).
voxel_biome(BiomeId, ClimateAndGeologyRules, TerrainParameters, MaterialPalette).
```

`VersionedSpec` contains explicit seed, generation/schema version, lattice origin/spacing, extent mode and any bounds/boundary behavior, surface profile, ordered generation recipe and exact biome/material references. The terrain binding relates identities; it stores no second density field or independently editable collider. Streamed chunks are immutable pieces of that terrain's derived shape, not newly founded entities or durable bodies on each visit. Revisions cannot be reused after removal/recreation. Current patches replace prior values instead of accumulating an operation list. Derived membership/attributes must read these relations, not duplicate them as editable GUI state.

The terrain binding is a query over the existing physical body assignment/definition, not another stored body revision. Edit requests also bind the current terrain physical revision; removing an override and later returning to an absent patch cannot make an old request current again. Changed patch tags use monotonic committed revisions, not a counter restarted when a patch reappears.

Reusable generator/biome definitions are pinned by exact anchored identity and immutable version/digest. Changing a catalog's current recommendation does not mutate existing terrain. A world can instead explicitly instantiate editable recipe parameters in its own specification; that is authored world configuration. Do not silently follow a moving foreign definition, fetch old ledger prefixes per query, or treat missing pinned content as a default biome.

## 3. Canonical field, chunks and deterministic generation

The authoritative terrain is **versioned procedural specification + current overrides** in Prolog. For a sample coordinate, an override wins; otherwise the exact generator version computes the value. The native layer receives those inputs and explicit work/resource allowances. It has no authority to choose a biome, accept an edit, change a seed or invent unloaded terrain.

Use a signed quantized density and discrete material identity at globally addressed sample sites. Smooth surfaces use the zero isosurface of the specified interpolant. Cubic surfaces use the sign at a sample site to occupy its centered cell; shared cell boundaries are halfway between sites. Document that these are distinct shape interpretations of the same sample domain. A cubic cell is not an exact rendering of every smooth feature.

Regular chunks own half-open ranges of sample sites. Shared samples have exactly one owner. Meshing reads neighbors as immutable halos; an edit includes every chunk whose geometry or normals depend on those samples. Chunk size and numerical packing are format choices, not hidden Erlang budgets. Empty/full regions can use uniform values, and unchanged procedural regions need no durable per-sample facts.

World boundaries are part of the recipe: an open sky and a protected basal/side envelope are a reasonable initial safe preset. Other authored worlds may deliberately expose edges or voids. Generate their actual visible/collision boundary consistently; never invent an invisible wall solely in client navigation or interpret an unavailable neighbor as air.

Specify canonical byte order, sample traversal order, signed arithmetic/rounding, overflow behavior, zero-sign handling, interpolation, ambiguity tie-breaks, triangle ordering/winding and material assignment. Negative coordinates use mathematical floor division, not truncation toward zero. Feature seeds derive from the world seed, absolute coordinates and named salts; never from chunk load order, wall time, node identity or `proof_draw/3`.

Pin the kernel version to each world. A library upgrade cannot silently regenerate an existing world differently. The initial numerical spike must choose one reproducible fixed-point/integer implementation or establish an equally explicit deterministic alternative. Stock floating-point noise portability is insufficient evidence for canonical terrain. Unsupported versions fail visibly; an upgrade is an authorized world change.

The recommended initial noise algorithm reuses BBSvx's seeded integer hash/value-noise approach, generalized to 3D and combined as parameterized fBm/ridged fields and low-frequency domain warp. Its Squirrel3/fixed-point/smoothstep implementation supplies a concrete starting point. The spike fixes full-coordinate hashing, interpolation, precision and vectors; it does not silently inherit 32-bit coordinate wrapping, hardcoded octave budgets or biome thresholds. Cellular fields are a later recipe operator when a concrete preset needs them, not a required second generator.

Pipeline:

1. Compute low-frequency continentalness, climate and authored envelopes.
2. Blend continuous biome terrain parameters; sample base heights, ridged mountains, terraces and optional domain warp.
3. Lift height structure into a volume, then add genuine 3D formations and cave subtraction.
4. Choose rock strata, soil depth and discrete surface/underground materials.
5. Apply current overrides, including digging; obtain the chunk's current density/material samples.
6. Extract the selected surface profile and canonical geometry; attach material groups as appearance data.

With negative density inside solid, subtract a brush field `B` using `max(D,-B)`; fill uses `min(D,B)`. These expressions define field composition, not a claim that the result remains an exact distance field. Minimum feature size, finite precision and brush quantization are visible constraints.

## 4. Generation variety, caves and biomes

World recipes are compositions of data-selected operators implemented by one numerical kernel. The domain owns their order and parameters; this is not an embedded script interpreter or a new graphical programming system.

Offer an initial curated palette:

- **Emerald Reach:** humid archipelago, terraces, limestone arches and connected authored entrance-to-cavern route.
- **Ochre Steps:** dry mesas, alternating sediment bands, ravines and sparse deep caverns.
- **Basalt Choir:** dark ridges, pillar fields and large underground chambers; glowing minerals are appearance, not a lava simulation.
- **Frost Lanterns:** alpine ridges and blue-white underground material bands.
- **Hollow Garden:** mostly underground, broad chambers and supporting columns with a few surface openings.

These are proposed combinations for acceptance fixtures and later presets, not five new engines or promises of vegetation/water simulation. Plants, buildings and ordinary rocks remain existing domain entities with their own Eidolons/colliders when placed.

Biome rules use temperature, moisture, elevation, continentalness and depth/geology. Blend terrain parameters across transition widths before density evaluation. Resolve categorical materials with stable rules/tie-breaks; never average numeric material IDs. Biome IDs remain stable across label changes. Underground ecology is explicit, not copied automatically from the surface biome. Painting an override does not overwrite the climate model.

Caves combine warped tunnel fields with a cavern field, bounded depth bands and roof/floor thickness constraints. Noise alone gives no entrance/connectivity guarantee. Where a navigable route is requested, compose explicit capsule/sphere carvers along a bounded authored graph and validate its clearance at the chosen lattice/mesh resolution. A hidden, disconnected cavity is allowed unless the world policy requires reachability.

## 5. Accepted shared capability extensions

The existing renderer's mesh payload is a verified static GLB fetched from a packaged public digest route. It cannot currently display newly generated arbitrary triangle geometry. Generating public GLBs for every edit would require a publication/storage lifecycle that does not exist in the current terrain domain. One box per voxel would multiply marks/colliders and still not supply smooth terrain.

The existing physics path accepts explicit shape terms; it does not currently retain a compact procedural-field materialization by chunk input identity or distinguish a known procedural solid from incomplete resident collision coverage. Recomputing every terrain mesh whenever `physics_projection/2` reruns would violate the repeated-operation invariant. The signed world-view socket currently accepts opening/acknowledgement, not movement-scoped terrain interest updates. These are concrete gaps for unbounded worlds, not existing capabilities hidden behind configuration.

The accepted design scope includes these extensions to the existing owners:

1. **Pure numerical primitive:** deterministic batch sampling/patching/meshing over ground, explicit inputs. Use the existing pure compiled-predicate mechanism described by [common primitives](../../src/predicates/quod_common_primitives.erl), rather than misclassifying the computation as a live governed query or adding a seal exception. The primitive neither reads a hidden KB nor performs I/O. Prolog owns ACLs, operator choices and budgets. Native acceleration is an implementation option within this one primitive, not a second fallback engine.
2. **Generated surface materialization in existing owners:** a versioned immutable geometry description, identified by canonical input/output digests and exact chunk dependencies, which the existing physics and visual consumers materialize and retain. Rendering adds a renderer-neutral generated-triangle payload under the common mark/model contract, validated alongside existing geometry. Physics extends its current fixed-shape adapter to retain the constituent chunk surfaces of one procedural terrain body. Reuse existing resource worker, render leases and client occurrences; do not add a terrain supervisor, message broker, blob publication service or parallel scene executor.
3. **Shared structural-edit factoring where needed:** ordinary voxel actions call the existing physical-edit validation, identity allocation, fence advancement, checkpoint invalidation and receiver consequence logic. Current definition-edit functions retract authored geometry facts; derived voxel geometry cannot pretend to be such a fact. Extract the common physical transition once and make both ordinary geometry edits and source-derived changes use it. Do not duplicate those guarantees in a voxel-only transaction path.
4. **Movement-driven coverage inside those owners:** extend the existing authorized view/control connection with bounded interest updates; extend the retained physics owner with explicit complete/incomplete terrain coverage and safe movement/observation checks. There is no signed domain write just because a camera visits another procedural chunk. Local-origin projection frames are needed once an active window moves beyond the existing rendering/physics coordinate envelope; their version and origin must be carried coherently through native poses, view frames and observation conversion. Section 9 defines the accepted design contract; this remains implementation work rather than existing machinery.

The first implementation spike must pin the smallest descriptor schema and retained-consumer boundary. The semantic requirements above are fixed; exact function names and packing are not. Each descriptor binds the world definition, chunk overrides/halo revisions, surface/kernel versions, appearance inputs and measured resource requirements. It cannot use a native handle as durable identity or refer to an unpublished blob as if it were available.

For example, the proposed terrain shape can name a versioned world definition by anchored reference/digest; selected materialization carries its exact sample inputs to the existing numerical worker, and the existing view carries resulting canonical vertices/triangles/material groups. This is data flowing through present owners. Creation validates the recipe schema, numerical/work envelope and initial resident chunks; it cannot prevalidate an infinite world. Each later chunk is validated before becoming visible/physically ready, and a failure produces a reasoned unavailable region rather than substituted geometry. The shared validation must distinguish an authored generated shape from an already materialized explicit surface.

The signed mark carries a bounded generated-surface descriptor: anchored world/recipe identity, exact chunk/halo dependencies, kernel/profile version and input digest. `physics_projection/2` and signed scene selection enumerate descriptors; they do not sample or triangulate terrain. Retained numerical work runs through the existing resource worker and consumers. Any pure primitive callable from Prolog must also be classified by its exact immutable implementation in `quod_resource_basis:pure_native/3`, so an unknown native dependency does not force selection after every commit.

The existing authorized view socket delivers retained triangle results as a generated-resource message bound to the current view, descriptor/input identity and output digest. This is the accepted generated-geometry extension of that owner. Each resource message is complete and bounded; choose the chunk format/packing so its worst-case encoded geometry fits, rather than fragmenting signed-goal replies or adding a generic result-stream protocol. Retain buffers through existing render-resource leases and decode them under the common mark kind; the browser runs no terrain generator. Missing bytes keep an occurrence pending, and stale/unauthorized results cannot install. The sender retains bounded outstanding work under view credit, expiry and cancellation; a slow browser cannot accumulate an unbounded mailbox.

The current socket reply limit is 512 KiB in [client limits](../../include/quod_client_goal_limits.hrl); signed proof answers and descriptor lists have their own limits. Verify complete encoded sizes, not raw vertex bytes. Keep transport bounds distinct from authored view/allocation policy; if an existing configurable cap blocks ordinary work, correct its ownership at the existing seam rather than silently raising it. Material groups use common surface/material semantics with one rooted chunk occurrence and anchored subject. A digest alone supplies neither bytes nor read permission; no public asset upload route is implied.

In practical terms: **today** a scene can ask for a box or an already available GLB, and a physical world can install its full explicit body geometry. **With this extension** the same scene can ask for a generated terrain surface; the same physics owner retains the needed chunk surfaces and reports when they are installed. Walking moves that retained window through the implicit world. Digging still uses the existing signed action and atomic transaction. The new capability is geometry plus residency support, not a new transaction engine or a replacement physics engine.

## 6. Actions, transactions and editing

Proposed domain actions: create a world, revise its generation specification, dig a bounded brush, fill/paint a bounded brush, and remove a world. Each accepts the exact expected current definition and affected chunk revisions. Give ordinary `action/3`/`goal/1` compositions the authoritative implementation; GUI continuations call them.

Creation composes the existing optional physics configuration, hosted-actor custody/preparation and initialization. A prepared key or committed definition is not an installed simulation. Show the existing disabled/recovering/ready/unavailable distinction; activation and first placement follow their current exact-operation lifecycle. No voxel-specific bootstrap process or key authority is needed.

A dig transition follows the existing proof lane:

1. Authenticate the ordinary signed action and exact world identity. Prove world edit policy, protected regions, brush limits and expected definition/chunk dependencies.
2. Compute changed sample ownership and halo consumers. An edit in untouched terrain compares the generator definition plus the **absence** of its override, captured through normal reads.
3. The pure primitive computes current replacement patches and canonical output validation/costs. Validate all affected geometry, aggregate policy and the chosen extent-mode rules before sealing. Invalid output rolls back the whole action.
4. In the same transaction, replace affected current patches, update the terrain's effective shape definition, advance existing world/body fences and apply the checkpoint rule in section 7. Any material yield/inventory consequence, if later enabled, belongs in this same ordinary multi-ontology transaction.
5. Commit through the existing one-writer lane or atomic group. Runtime and signed-view dependencies install the delta; ordinary reactions may announce the committed change. Historical reactions are not the materializer.

One brush crossing a chunk or ontology boundary is one transition. Do not split it into independently committed chunk edits, add terrain acknowledgements, or retry a fresh write after timeout. Retain and resolve the exact original operation. A batch too large for policy fails with the actual exceeded resource; it does not silently shrink the brush.

Size the initial chunk/patch codec and brush policy against the whole encoded replacement diff, reads and transaction wrappers, including previously accumulated overrides. Current [proof limits](../../include/quod_proof_limits.hrl) include a 128 KiB plan envelope and 224 KiB atomic body; [ingress limits](../../include/quod_ingress_limits.hrl) bound a canonical transaction at 256 KiB. These are existing protocol bounds, not a claim that a raw 256 KiB patch fits. Measure all applicable envelopes and report the actual failure. Halo consumers require geometry invalidation/validation, not duplicate durable sample patches. No resource-policy setting grants permission to exceed the protocol or split an atomic brush.

A repeat that changes no values is a no-op: no new patch/body/structure revision and no physical reinstall. Concurrent edits use the actual existing per-predicate OCC; spatial revisions do not imply row-level concurrency. Initially one winning edit may invalidate another unrelated same-ontology edit. Report that limitation and measure it rather than promise lock-free digging.

Changing seed, spacing, bounds or generation parameters on an edited world must not silently erase or reinterpret overrides. Initial default: refuse incompatible regeneration while overrides exist; offer a separately authorized **new world instance** with the requested recipe. A later explicit rebase/reset operation would need its own semantics and user decision. Appearance-only palette edits preserve physical revisions when shape/physics inputs are unchanged.

## 7. Collision and physical safety

Use one ordinary fixed **terrain body** per world, allocated through the existing monotonic body allocator. Its procedural shape is made from retained chunk triangle surfaces in the native adapter. Keep semantic chunk coordinates, terrain body ID, native subcollider handles, visual occurrences and geometry digests distinct. This makes a chunk visit/unload a materialization change, not a new durable body creation/removal. Use the same shape model for bounded and unbounded worlds. A real authored terrain deletion/recreation retires and reallocates its body normally; native handles never become durable names.

An empty chunk has no constituent surface, not an invalid empty triangle mesh. Preserve the logical fixed terrain body while its resident surface set is empty; the native extension must handle that valid case without fabricating geometry. Adding/removing constituent coverage changes no authored structure by itself. A **dig or other actual field edit** changes the existing world structure and terrain body revision in the same transaction. Readiness of a cache must not be confused with either domain membership or a structure edit.

Extend the existing native installation algorithm to distinguish terrain body identity, authored revision and retained constituent shapes. A dig advances the body revision as required by the shared contract while replacing only changed chunk shapes; it must not make the current whole-row comparison destroy all terrain colliders. Residency changes use this same owned installation mechanism with unchanged authored revision. Preserve unrelated live bodies and charge aggregate retained parts, vertices, triangles and chunk metadata through the existing geometry/allocation policy. Contact work remains budgeted per native collider pair, including chunk-boundary fan-out; semantic observations map handles to body identities without hiding the work charged.

Initially derive collision and visible surface positions from the same canonical triangulation at one physical resolution, with explicit unit conversion to existing integer millimetres. Rendering may split vertices for normals/materials without changing positions. Do not infer collision from a GLB bounding box, approximate a cave with a convex hull, or add a grid-based movement controller. Existing controlled-agent motion, gravity, pushes and motion queries remain the collision path.

Use MC33 with the corrected interior tests discussed in the research survey, including the Vega et al. case 10.1/13.5 regressions, rotations and sign complements; do not adopt an older Lewiner implementation unchanged. Algorithm-level topology guarantees do not automatically survive integer-mm rounding. Validate degeneracy, winding, shared face topology, material seams and quantization for every candidate changed chunk. Reject unsupported thin/degenerate output atomically rather than delete arbitrary triangles and claim a watertight result. Boundary fixtures must include negative coordinates, zero samples, diagonal caves and corners shared by multiple chunks.

The numerical spike must establish a usable admitted parameter domain before this mesher is selected for implementation. Define canonical shared-vertex quantization and welding; test near-node crossings, three distinct collinear vertices and topology changes caused by merging. Dropping triangles with repeated indices alone is insufficient evidence. Prove the admitted cases or use deterministic pre-commit rejection of unsupported edits; measure rejection on representative procedural regions and revise the numerical design if ordinary terrain fails. Streaming cannot prove every future chunk in an unbounded world: an invalid result remains explicitly unavailable and is rejected before native installation, preserving the last safe state. Never send invalid geometry to the current native failure path or claim that only resource refusal can fail.

Coverage distinguishes known empty, known solid, mixed with installed surfaces, and unavailable. A fully solid chunk can contain no triangles. Creation, admission, repositioning, teleport landing and checkpoint restoration must establish clearance of the whole body against the canonical occupied volume, using the same deterministic field and existing placement/coverage owner. Testing only the body's centre or absence of triangle contacts is insufficient. Use conservative refusal when clearance cannot be established within policy; retain ordinary triangle sweeps and the existing movement engine.

The native owner installs all affected collider changes at the existing step boundary before publishing the new structure revision. The client must not present an opening as physically usable until its matching installed structure and required coverage are available. An old rendered surface may remain visibly stale or the view can enter recovering; it must not remain interactively authoritative. Missing geometry, policy or sources makes the affected operation/world unavailable, never empty traversable space. A terrain-body revision change is conservatively world-wide in the current profile; retain unaffected immutable chunk surfaces even though commands/observations must rebind the new world fence.

Digging removes terrain, so a grounded agent can fall using existing gravity; install changes already wake grounded mechanics. Filling/regeneration can embed bodies. Initial ordinary edit policy permits subtractive digging and material paint; addition/major regeneration is performed in an explicitly quiescent editing world unless an existing authenticated physical-observation action can establish the required clearance. A read-only client collision query cannot justify the durable edit. No invented authoritative live overlap check is introduced by this plan.

A subtractive dig preserves committed checkpoints of unchanged free bodies; the world fence invalidates pending old observations. Recovery still checks complete terrain coverage and volume clearance at the saved pose, then wakes mechanics so a body with removed support falls normally. A checkpoint is not a promise of continuing support. Changes to a body's own definition retain the existing checkpoint-removal/cancellation rule. Fill/regeneration requires a quiescent world with no admitted non-terrain bodies or pending physical activities in the initial policy; do not infer quiescence from a momentarily sleeping simulation.

Caves do not collapse automatically. Unsupported voxel collapse, granular material and fluid dynamics are distinct physics features. Uniform gravity supports flat/finite terrain; a spherical visual world would not establish planetary gravity.

## 8. Existing GUI composition

Use the shared desktop/spatial form tree, not a voxel-specific frontend. Proposed sections:

| Existing controls | World fields |
| --- | --- |
| Text box, number input, selection | Name, seed, recipe, surface profile, bounded/unbounded mode, applicable bounds, spacing |
| Tabs, groups, sliders with numeric entry | Continental scale, relief, ridge strength, terrace amount, warp strength |
| Toggle, sliders, number inputs | Caves enabled, tunnel width/depth, cavern amount, roof thickness |
| Table/selection, ordinary per-biome detail form | Enabled biome IDs, climate centers, transition widths, strata/palette |
| Selection, number inputs | Dig shape, dimensions, edit permissions and protected region choices |
| Number input/slider, status | Authored view distance and current coverage/loading state, within authorized policy |
| Status/help and submit button | Current world state and Create/Apply action |

All ranges/options are authored Prolog contracts. Use integral UI units/permille where appropriate. Do not expose raw NIF choices, thread counts or compiler details to a world creator. Advanced resource policy remains ordinary authorized policy, distinct from creative sliders.

`gui_form/3` binds the complete submitted values to an authored continuation; `gui_initial/3` derives current values; `gui_validation_context/2` binds relevant world/recipe revisions. The existing schema token alone does not substitute for the domain action's expected revisions. Reuse `gui_open/2`, question completion and HUD consumption. Failed completion preserves submitted work through the existing lifecycle.

The initial form uses **Apply** to request a governed configuration transition. Local sliders remain a draft until submission. A continuous live terrain preview and pointer-drag sculpting are not capabilities of the current form contract; do not add callbacks or a transient terrain protocol under the name of GUI reuse. Initial digging can use an ordinary form with center/radius and, where the existing selection path supplies it, a selected terrain location. A future spatial brush must demonstrate and request the missing picking/intent capability.

A custom screen mockup is unnecessary for this first composition: every proposed control and its desktop/spatial layout behavior already has a shared implementation. The architecture diagram below illustrates the ownership decisions instead.

## 9. Retention, budgets and recovery

Retain materialized sample/mesh results for the actual existing physics or view consumer lifetime. Key reuse by exact immutable chunk inputs, including halo and algorithm versions, rather than only by the last global world revision. No owner process per chunk; no global mutable terrain inventory. Consumers may share verified immutable results without sharing authority.

Resource selection may enumerate descriptions under the current predicate dependency granularity; it must not regenerate unchanged chunks. A material-only edit may rebuild appearance without rebuilding an unchanged collider. An unrelated GUI submission/checkpoint must perform zero sampling, meshing, body replacement and disk writes/syncs attributable to terrain. A real edit rebuilds only its exact dependency closure; old results arriving after cancellation/removal are discarded under owner-incarnation and revision guards.

Current signed views refresh when a dependency's durable height advances, and physical invalidation can suspend controls until the new selection installs. A dig can therefore renew every affected viewer's signed read even when most geometry is retained. Measure proof/refresh cost and control interruption as well as chunk work; this plan promises no fine-grained view refresh or row-level OCC optimization.

Prolog supplies work and allocation policy: sample evaluations, changed/retained chunks, patch bytes, meshing output, active bodies/vertices/triangles, view bytes/marks, concurrent work and cumulative world/node allocation. Reuse existing body/geometry/render/actor/effect custody allowances. Any missing configurable budget ownership must be corrected at its existing owner when it blocks ordinary terrain; never raise an Erlang constant, exploit chunking to evade it or introduce a second admission authority. Policy admission must account for worst-case output and aggregate retained consumers, not just a per-chunk request.

Ontology recovery restores the current specification and patches. Explicit simulation/view recreation may regenerate their materialization once; unchanged checks reuse it. No ordinary request scans the ledger to replay digs or repairs missing state. The physics run uses existing host/key/generation activation and compatible entity checkpoints. Rebuilding terrain does not replay contact/dig reactions. Missing native support or an unsupported pinned generation version remains a visible unavailable state.

Bounded and unbounded worlds use this same lifecycle. A small bounded fixture establishes correctness; unbounded movement-driven residency is included in the requested feature. Bounded worlds can pin their entire finite region when policy admits it, or use the same residency mechanism for a larger bounded region. Bounds are authored world semantics, not Erlang resource ceilings. Mixed-resolution distance LOD is optional later work, not a prerequisite for streaming at one resolution.

### 9.1. Unbounded view-distance generation

The world exists as a coordinate-addressable procedural definition plus committed edits; it does not have to store or generate every untouched chunk. The current view authorizes an interest window, not a second world or a request to commit explored terrain.

1. **Movement changes demand.** The existing camera/control/view lifecycle reports crossing a chunk-interest boundary or changing the authorized viewing range. The existing server view owner validates identity, session, current definition and view-distance/resource policy. Camera position is a presentation hint, never proof that an actor physically moved or authority to load arbitrary private data. No interval polls for readiness.
2. **Cover the visible range.** Select all chunks that could contribute within the declared far distance/vertical envelope, with conservative terrain bounds, plus an authored prefetch margin. A radius around the viewpoint can avoid holes on a quick turn. Prioritize near terrain and travel direction; distinguish visual completion from physical coverage. Clip/fog beyond the requested/installed visual horizon consistently; do not silently shorten the user's chosen range to hide failed generation. If the requested range cannot be met, show loading/refusal and keep movement safe.
3. **Retain and apply a delta.** The existing bounded resource work computes only missing/changed immutable chunks. Subscribe before snapshot, retain the exact input/owner-incarnation fence, cancel superseded demand and discard stale completions. Equal demand does no work. A larger retention/unload margin prevents edge thrashing; demand changes and worker completion notices drive scheduling. These are algorithms in the current owners, not a new durable chunk queue or a second executor.
4. **Physical coverage is broader than the camera.** The physics owner pins terrain needed by every active body, its next-step/swept motion, constraints, hot controls and pending authenticated physical observation. A crate remains supported after its viewer leaves. The active collision set is the union of those consumers' needs, bounded by Prolog policy; it is not simply the last camera's render set. Insufficient capacity explicitly refuses new admission/work or makes the relevant operation unavailable; eviction never removes support from a still-live consumer.
5. **Unknown is unavailable.** Before stepping/moving/querying, the owner establishes complete collision coverage of the relevant sweep/support envelope for the current terrain revision. It pauses affected stepping/input, or the conservative whole simulation if required by the current adapter, until installation finishes. It never traverses an unloaded chunk as empty space or certifies “clear”/negative contact from missing terrain. A signed physical sample is emitted only with valid complete coverage for its inspected region. Existing run/world/body fences still validate durable consequences; cache residency cannot bypass them.
6. **One terrain identity, local native pieces.** Chunk subcolliders are retained under the one fixed terrain body. Loading a cache does not change the world definition/body revision, create a durable body ID, or write an explored-chunk ledger. A field edit advances the ordinary structure/body fence; changed overlapping resident pieces install coherently before ready resumes. A stale proof about empty space still loses to a concurrent dig/regeneration through the existing conservative world fence.
7. **Eviction is consumer lifecycle.** Release render chunks outside the retained view window; release physical pieces only after every physical/query consumer releases its pin. Current overrides remain durable in their ontology. A later revisit may regenerate an evicted procedural result as an explicit new materialization, not an unchanged-read repair. Unchanged active consumers retain their results; recovery does not parse edit history.
8. **Coordinates remain explicit.** Address samples/chunks by canonical signed integer coordinates, including beyond JavaScript's safe integer range. Move small local integer-mm frames with the active window, converting only local values to native/Babylon floats. Rebase all affected native bodies/terrain, camera projections and coherent pose frames at a step boundary; preserve domain identity, world position, velocity and authored revisions. Tag local-origin projection frames so clients discard interpolation across an origin change. Convert samples/checkpoints through the exact origin before existing signed validation. A pose must never be reinterpreted under a new origin. Concurrent distant consumers beyond one simulation's representable active envelope require an explicit policy refusal; this plan does not distribute one simulation across nodes.

**Coverage gate.** Before a mechanical step, conservatively bound every non-fixed body's occupied/swept region, including angular motion, gravity, allowed impulses, constraint motion and collision response under the admitted numerical envelope. Include pending drive/teleport paths and landing/drop searches, placement/restore regions and outstanding query sweeps, with the required skin and halo. A velocity-only endpoint bound is insufficient if response or constraints can leave it; refine bounded steps or refuse when the conservative bound cannot be established. Every intersecting cell needs a current materialized classification and every required surface needs installation. Outside-envelope behavior comes from authored boundaries, not missing data. Cancel the existing step timer on a gap; request missing immutable results through the resource owner and resume on scoped installed notices. Do not extend input/sample/view expiry, consume an uncertain command twice, or accumulate catch-up motion. Initial broad-phase preparation/first stepping must also be coverage-gated; no step into unknown terrain may be used merely to make queries ready.

**Coordinate contract.** Split exact canonical domain positions from bounded native-local coordinates in the shared body, placement/control, observation and checkpoint validators. Existing `physics_valid_body/6`, absolute-input checks and rest-sample validation currently use absolute coordinates; `quod_physics:physical_vector/1` converts them directly to floats. Update those seams together. A run owns an exact integer origin plus an origin sequence; canonical positions cross JavaScript as exact integer encodings, and conversion subtracts the origin before floating-point arithmetic. Shape dimensions and local displacements keep their own allowances. Keep the terrain's exact lattice anchor distinct from its transient native body/chunk transforms.

Every local pose/placement command binds the origin sequence under which it was expressed, or carries an exact absolute target; late commands are converted with that exact origin or refused. Signed samples freeze the coherent origin and canonicalized measured positions before signing. Checkpoints retain canonical positions, independent of whichever origin recovery selects. The client frame schema, interpolation fence and control encoding change together; schema 1 in [simulation.js](../../client/src/simulation.js) and the current [movement encoder](../../client/src/locomotion.js) do not provide this today. Translate retained native bodies, joints and collision structures coherently without reinstalling their authored baselines or restarting the run. Preserve velocity, identity, activity, command sequence and deadlines. If the prototype cannot meet that live-rebase contract, stop and present the concrete limitation before substituting restart/restore semantics.

The native coverage rules, shape retention and local-frame extension are the largest correctness portion of the feature. Prototype them through the real existing physics/view owners before adding scale. No claim of seamless arbitrary-speed travel or a particular view distance is made without measurement. A finite admitted active set and finite machine encoding remain necessary even when the generated world has no authored horizontal boundary.

### 9.2. Later patchwork of users' bounded worlds

Preserve the prerequisites now: anchored world identity, explicit bounds, named local lattice/frame, immutable generation version, existing source edit authorization and separate visual/physical membership. Do not merge histories or copy each user's KB into an aggregate owner.

A later aggregate space can reference bounded worlds/patches through existing `entity_ref` and space membership, and admit their geometry into one chosen simulation authority. It must author patch placement, seam continuity or deliberate boundaries, overlap priority, allowed cross-patch digging and source/destination permissions. A cross-patch brush with related consequences remains one existing atomic multi-ontology transaction. Shared contacts require one compatible physical simulation; side-by-side visual placement alone supplies neither physical transfer nor distributed collision. This feature is intentionally deferred by Yan's direction.

### 9.3. Future user-owned flying lobby

A user should later be able to instantiate/spawn their own flying lobby into any generated voxel world and operate the world's authorized controls from that lobby. The lobby remains a separately owned domain entity with its existing GUI and anchored identity; the voxel world remains the owner of its terrain and world policy. Compose admission and physical placement through existing space/physics transitions. World controls presented in the lobby invoke the same governed world actions; spawning a lobby does not create another world-control engine or transfer world ownership.

Preserve the relevant terrain assumptions now: residency and visible-range selection work from elevated/moving viewpoints as well as ground-level ones, and terrain coordinates are independent of a visiting lobby's local frame. Terrain collision remains compatible with separately admitted entities. The lobby's flight mechanics, moving compound geometry, interior frames, spawning UI and cross-world travel are later integration work, outside the voxel-world implementation slices and acceptance milestone. This context does not broaden the current feature into a flying-lobby implementation.

[Terrain authority and derived geometry](voxel-world-architecture.excalidraw "width=1100 height=720")

## 10. Implementation sequence

1. **Numerical/format spike:** adapt the inspected BBSvx numerical/meshing ideas, pin field semantics and reproducible generation, select one implementation per surface profile, validate integer-mm topology, and measure small bounded fixtures. Freeze the minimal generated-geometry schema and pure predicate boundary before integrating it. If that needs a broader path than section 5, ask Yan before continuing.
2. **Shared geometry integration:** extend common mark validation/decoding, bounded resource delivery and retained render resources; materialize constituent fixed surfaces under one terrain body in the existing physics resource; factor the existing structural update once. Include the coverage/volume-clearance gate now, initially with fully resident bounded fixtures. Prove a non-lobby inclined surface with a passable tunnel before building presets.
3. **Domain lifecycle and atomic digging:** compose worlds, chunks, policy and actions. Cover creation, no-op, revisions, empty chunks, cross-boundary digging, removal and current-state recovery through real owners.
4. **Biomes and caves:** add parameterized climate/geology and generation operators through the shared kernel. Use the curated worlds as behavior fixtures, including a deliberately connected route and an allowed disconnected cavity.
5. **Unbounded residency:** extend existing authorized view interest, physics coverage and local-origin frames; prove movement-driven generation, safe missing support, retained unrelated bodies, cancellation and revisit behavior at one resolution. A bounded demo alone does not complete Yan's requested world feature.
6. **GUI and end-to-end acceptance:** compose existing forms and signed actions. Verify bounded/unbounded selection, stale forms, exact operation resolution, collision/visual revision coordination and persistence after restart. Deliver both surface profiles with smooth validated first; aggregate patchworlds remain later scope.

This order is not permission to publish incomplete voxel worlds or invent separate transitions for related receiver consequences. Each slice uses the existing transaction and release rules. Implementation, commit, deployment, refounding and data wipe require their applicable authority.

The selected common-primitive route is release-coupled: [committed projection initialization](../../src/quod_committed_projection.erl) loads `quod_common_primitives` in the shared base. Deploy compatible proof workers, validators and physics/view consumers through the existing release procedure. A separately founded predicate module would instead require its founded-capability procedure; do not confuse these installation paths. Composing Prolog source is not permission to inject native code into a live history, alter an immutable founding manifest, or load BBSvx source into a client engine. Scope approval remains separate from permission to implement or deploy.

## 11. Acceptance and evidence

- Two independently named non-lobby worlds coexist with distinct seeds and policy. An instance/subclass query follows existing class-first semantics. Classification without enablement allocates no simulation.
- Deterministic vectors compare canonical sample/patch/geometry digests across supported builds, nodes, request order and restart. Numerical edge/ambiguity/quantization cases have exact fixtures. All audited inputs and outputs are versioned.
- Smooth terrain includes an overhang and traversable cave; cubic terrain, if selected, has exact block boundaries. Surface, underside and seam collisions use the real native owner. A dig opens the intended tunnel while its surrounding rim remains solid.
- A brush crossing faces/edges/corners changes all necessary owners atomically. Failure in any receiver or policy leaves every patch, collider binding, checkpoint and GUI consequence unchanged. Unauthorized/protected edits fail normally; malformed numerical inputs report errors.
- A fully emptied chunk removes only its constituent collision/visual surface correctly; loading/unloading/reappearing chunks preserve the logical terrain-body identity. A deleted/recreated terrain never reuses its retired body ID. Appearance edits preserve physical geometry/fences when appropriate.
- Concurrent stale edits and stale submitted forms cannot overwrite intervening work. An uncertain original request is resolved, never resubmitted under a new ID.
- Seed/bounds/spacing edits cannot silently erase or reinterpret digging. A named new world preserves the old world's current state.
- Instrument sampling, triangulation, native install/build counts and filesystem writes/syncs through real production owners. First creation may do work; an unchanged refresh/reconciliation and an unrelated GUI/checkpoint operation must show zero terrain work. An actual boundary edit affects only the declared dependency closure. Report mailbox, CPU, native and I/O time separately; no timing-only proof or sleeps.
- Restart ontology/runtime/native/view consumers and verify current digs/biomes restore, native runs get their proper fresh fences, stale callbacks are harmless and historical reactions do not replay. Pending exact operations retain the ordinary recovery obligation.
- In an unbounded world, crossing an interest boundary generates only missing chunks to the declared visual horizon, retains overlapping chunks and performs no domain writes for mere exploration. Turning/revisiting, abrupt direction changes, teleports and late completions cannot install stale terrain. Current edits survive eviction/revisit.
- A camera leaving does not remove terrain supporting another live body. A paused/missing generator cannot cause falling through unknown terrain or a false clear motion/contact observation. Test coverage gaps with real controlled motion, gravity and authenticated consequence seams; synchronize on installation/processing evidence, not sleeps.
- Cross local-origin rebases at large positive/negative coordinates and above JavaScript's exact integer range. Preserve identity, checkpoint coordinates, live motion and collision; discard frames carrying stale origin tags. Exercise active-window resource refusal without misreporting it as a world boundary.
- Refuse placement/restore inside uniform solid and mixed terrain, including a body whose centre is empty but whose volume intersects rock. Dig away checkpointed support, restart, and verify retained placement plus ordinary falling. Gap waits preserve original leases and do not create catch-up steps.
- Measure signed-view refreshes, control suspension, encoded descriptor/resource/transaction sizes and collider-pair fan-out per dig. Verify zero meshing during descriptor proof refresh, retained unchanged native pieces across a terrain revision, and bounded output under a stalled viewer. Test delayed teleport commands and signed samples across an origin shift.
- Bounded worlds expose the local frame/bounds metadata needed for later aggregation. Two owners' worlds can be referenced independently without namespace collisions, implicit history merging or premature claims of cross-world physics.
- Measure actual bytes, peak memory, samples, triangles and edit/install time for flat ground, high-noise worst-case surfaces, thin tunnels, material boundaries and repeated digging. Set creative resolution/scope targets with Yan after these results; do not invent a throughput claim.
- At the applicable implementation/release boundary run the repository's standing clean sequential gates, retaining full logs and true child exits. This planning-only change does not warrant running production release gates.

The smooth core passes the full frozen `clean-gates-04` campaign, including 4,052 EUnit and 148 Common Test cases, native/client checks, static analysis and release assembly. The exact validated browser output is packaged locally and the terrain preview is available. Numerical formats and domain actions are documented in [voxel terrain arithmetic](../../doc/voxel-world.md). Labeled experiments, failures, corrections and full receipts remain under `doc/evidence/voxel-world-20261016/`. The [implementation acceptance checkpoint](../../doc/evidence/voxel-world-20261016/implementation-acceptance.md) records evidence and remaining scope, including the normal browser's world-entry integration, fuller biome editing and terrain-specific distributed measurements. The broader plan remains in progress; no commit, deployment or live-world creation is implied.

The next user-facing milestone is specified in [Create and enter terrain worlds](voxel-world-lobby-entry.md): a console workspace using the existing GUI, signed space selection and physical setup lifecycle. It includes the necessary shared-extension approval boundary and preserves the flying-lobby deferral.
