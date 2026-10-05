# Eidolon mesh support

Imported static meshes use the existing Eidolon description path. The domain
entity, its anchored ontology identity, recipe selection, authorization and
occurrence ID remain Prolog-owned. A GLB supplies only geometry and appearance.
This implementation follows [world.md](world.md)
and [multiwrite-architecture.md](multiwrite-architecture.md).

## Description and placement

`part/6` in [quod_lobby.pl](../priv/ontologies/quod_lobby.pl) feeds
`model/2` in [quod_modelling.pl](../priv/ontologies/quod_modelling.pl), which
produces the shared `mark/7` vocabulary validated by
[quod_rendering.pl](../priv/ontologies/quod_rendering.pl):

```prolog
mark(Id, <<"mesh">>,
     mesh_asset(asset(Digest, <<"model/gltf-binary">>),
                <<"gltf2-static-v1">>, scale(Permille),
                frame(aabb(MinX, MinY, MinZ, MaxX, MaxY, MaxZ),
                      pivot(PX, PY, PZ), front(Front)),
                resources(TransferBytes, GeometryBytes, Vertices, Triangles,
                          Nodes, Materials, ImagePixels)),
     Transform, asset_surfaces, Label, Depicts).
```

The digest is lowercase SHA-256. Bounds and pivot are asset-local integer
millimetres; the GLB's vertices remain in metres. `scale(1000)` is native size.
`Front` is one of `-z`, `+z`, `+x`, `-x`; the client rotates that direction to
Quod's `-z` front, then subtracts the pivot and applies the occurrence scale.
The authored transform and parent composition follow the existing integer-mm,
whole-degree convention. `align/6` uses the declared bounds, pivot and scale
and retains exact integer-mm placement. A mark's label uses those same bounds.
The client recomputes canonical conservative bounds from the verified GLB and
requires the descriptor to match them. Float32 values within four ULP of a
whole millimetre snap to that millimetre; flat axes receive 1 mm padding.
Genuinely half-millimetre centre alignments have no exact whole-mm answer.

`asset_surfaces` preserves the accepted glTF 2 core metallic/roughness materials
and embedded PNG/JPEG textures on every submesh. It does not reinterpret source
material or node names as Quod subjects. The rooted occurrence mark alone owns
`Depicts`; descendants have their imported metadata cleared before picking.
Two placements of one digest have distinct occurrence roots, transforms and
selection identities. A recipe may mix mesh and primitive parts.

The seven resource values are allowances in the authorized descriptor. The
rendering ontology bounds each allowance and the client measures actual GLB
costs before Babylon sees the bytes. Transfer bytes include the complete GLB;
geometry bytes count referenced vertex and index buffer views; image pixels
sum embedded image dimensions. Vertex and triangle counts include each scene
node that references a mesh, so repeated drawing consumes the allowance.
Nodes and materials are checked separately. A value above its allowance
produces a named error. The scaled visual span and reach from its pivot are
also bounded by rendering ontology policy.
These limits are ontology policy, not Erlang or JavaScript constants.

## Static asset profile and ownership

[glb-profile.js](../client/src/glb-profile.js) accepts one selected GLB 2.0
scene with a local BIN chunk, triangle primitives, transform hierarchy, core
PBR materials and embedded PNG/JPEG images. It rejects listed or embedded
extensions, external URIs, animation, skins, morph targets, cameras, unsupported
attributes, sparse/interleaved accessors and malformed references. The profile
is intentionally narrow; an importer must report conversions that drop source
features. The pinned Babylon core and glTF loader versions are declared in
[package.json](../client/package.json).

[render-resources.js](../client/src/render-resources.js) streams from the
public digest-derived asset path, enforces the transfer allowance, verifies the
SHA-256 digest, validates the profile and actual costs, then decodes a shared
`AssetContainer`. [scene.js](../client/src/scene.js) instantiates that template
per occurrence. Stable marks retain their instance and lease across unchanged
and transform-only refreshes. Removal or replacement releases the occurrence;
the final consumer retires the shared template. Late asynchronous results are
checked against the current occurrence and disposed when stale. Embedded images
load under the production CSP's `img-src 'self' data: blob:` policy.

The default lobby console's playing recipe uses the packaged
[console.glb](../assets/GLBs/console.glb), with a bottom pivot. The edition
recipe retains its structural parts. An authored asymmetric fixture is also
packaged for the imported-artifact recipe. Public delivery uses the existing
static asset route. Digest identity is not read authorization:
private assets require a separate authenticated delivery and publication path.
There is no new Erlang scene process, importer call during proof, or NIF.

## Offline import

[import-eidolon.mjs](../client/tools/import-eidolon.mjs) prepares a GLB and a
JSON report outside consensus. It accepts compliant GLB directly and uses
pinned Assimp 6.0 for glTF, FBX, OBJ, STL and polygon PLY. The command records
source and dependency digests, importer/version/build/options, output digest,
bounds, resource costs, core material factors, diagnostics, licence and
provenance. Unitless sources and FBX
require an explicit source metres-per-unit value. External glTF/OBJ dependencies
must be local and present. Unsupported features fail. FBX and OBJ with MTL
require `--accept-material-loss yes` because Assimp's material mapping can
change optical factors. Unsupported material extensions from other sources
also require that choice. Default materials generated for STL or PLY are
reported without claiming source appearance was preserved.

For example:

```sh
node client/tools/import-eidolon.mjs model.fbx --out /tmp/eidolon-import \
  --licence CC0-1.0 --provenance local:model.fbx \
  --source-meters-per-unit 1 --front +x --pivot-mm 100,0,0 \
  --accept-material-loss yes
```

[import-eidolon.integration.mjs](../client/test/import-eidolon.integration.mjs)
checks a binary FBX fixture with asymmetric bounds, hierarchy, two materials
and an embedded image against its authored GLB; it also exercises all listed
source formats and missing dependencies. This establishes the tested static
subset, not lossless conversion of arbitrary FBX features. The fixture's
embedded image is byte-identical after an FBX round trip, while its roughness
factor changes. A larger round trip of the user-supplied `console.glb` likewise
preserves geometry counts, bounds and embedded image bytes but changes
roughness. The default lobby uses a derived GLB with metallic factor zero so
its base-colour texture remains visible under the lobby light. The original
`assets/GLBs/console.glb` remains intact; `assets/GLBs/console.import.json`
records source/output digests, the material edit and provenance. The
`user-provided` licence value is a provenance label, not an independent grant.
The browser check in `ui/test/mesh-browser.browser.mjs` loads both packaged
models with the production image CSP and checks their embedded textures,
separate occurrences, shared template and picking subjects.

Polygon PLY faces are triangulated; the report records discarded polygon
topology metadata. Flat meshes receive a conservative 1 mm layout bound on
their zero-thickness axis so their recipe frame remains well formed.

## Identity and future physics

Keep the domain subject `(namespace, anchor, term)`, recipe identity, asset
digest and visual occurrence ID distinct. An imported node or `extras` field
cannot create a subject, permission, action or interaction binding. Mesh bounds
are visual layout metadata. They do not create a collider or certify physical
shape. A later collider should have its own authorized descriptor and stable
identity attached to the same domain subject and occurrence, with an explicit
visual-to-physical transform. This leaves physics and visual topology free to
differ without transferring authority to imported data.

A live native physics query is a real-world observation. It cannot be used
inside a proof that seals a durable diff. Later observations need an
authenticated producer binding and an ordinary authorized action/transaction
through the existing multi-ontology and reaction framework. Private asset
publication likewise requires governed storage and delivery before any recipe
can safely refer to private bytes.
