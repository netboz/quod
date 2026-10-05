# Static model fixtures

`make_asymmetric.py` authors `asymmetric.glb`, `texture.png` and the expected
SHA-256. It defines an off-centre model with a translated child, two triangle
submeshes, two core PBR materials, an embedded PNG and untrusted node `extras`.
The browser fixture loads it beneath rotated occurrence parents; the scene
test uses a stub template to verify the same transform and identity path.
Run it only when deliberately updating the fixture and its expectations.

`asymmetric.fbx` is a binary FBX 7.5 file exported from the authored GLB with
Assimp 6.0 (`assimp export asymmetric.glb asymmetric.fbx -ffbx`). It exercises
the real FBX parser/converter, hierarchy, geometry, material count and texture
retention. The integration test compares its output bounds and measured costs
with the source. The conversion requires explicit acceptance of dropped
material extensions; it does not assert lossless fidelity for arbitrary FBX shaders.

`asymmetric.obj` and `asymmetric.mtl` are source fixtures for local dependency
resolution and material/texture conversion. STL, polygon PLY and glTF fixtures
are exported into a temporary directory by the import integration test.
