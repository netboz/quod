# Scene shadows and desktop navigation

The actual Quod window showed coarse shadow edges and flat shading under the
lobby roof. Offline reproduction uses the same packaged ground, roof and
console GLBs through the production validator, resource owner and scene.

The main defect was constant-color ambient illumination: within a cast shadow,
curved surfaces became uniformly colored and lost their visible shape. A
procedural sky now supplies directional diffuse fill and reflections while the
ontology-projected panorama remains the visible backdrop. Directional shadows
use a 30 m range, blended cascades and high-quality filtering on a 4096 atlas;
16-bit depth is retained. Filmic exposure remains 0.7 and sun energy remains 0.9.
No geometry, authored material or server state was altered.

Sky meshes no longer cast shadows. The isolated sky-on/off comparison did not
change the reproduced defect, so this is an explicit backdrop invariant, not
the claimed cause. The shadow filtering choice follows
[Godot's lighting guidance](https://docs.godotengine.org/en/4.5/tutorials/3d/lights_and_shadows.html#shadow-filter-mode)
for visible dithering on sparsely textured surfaces.

[Before](lobby-final-01/before.png)

[After](lobby-final-01/after.png)

[After moving the camera](lobby-final-01/after-moved.png)

## Verification

The [GPU rendering check](lobby-final-01/run/output.log) passes and reports a
luminance range of 0.05323 over a fixed, sloped roof patch in shadow, versus 0.0
with the previous uniform fill. This is a pixel-based regression check for the
lost surface shape, not a headset qualification or subjective quality score.
The check also verifies that an unchanged scene retains nodes and decoded GLBs.

The reusable desktop camera replaces the previous input code in main. Physical
WASD (ZQSD on AZERTY) or arrows move the observer; R/F changes height, Shift
increases speed, right mouse captures/releases look, wheel steps forward/back,
and Tab/Esc opens/closes the menu. Help stays visible in the scene. This is free
observer movement, with no collision simulation or server-owned body movement.
XR controller locomotion remains unimplemented; existing tracking is unchanged.

[Navigation checks](final-client-01/navigation/output.log) verify forward and
vertical movement, normalized diagonal speed, arrow/modifier input, pitch limits,
and cancellation/release on menu opening, focus loss and disconnect. Entry
screens block navigation, closing a menu does not resume stale held keys, and
navigation sends no network requests.

The complete [sequential client gates](final-client-01/) pass formatting, seven
Rust tests, native/browser contracts, nine browser test files, strict Clippy,
build, viewer/resource tests, navigation, local TLS import/recovery/onboarding,
Linux export and exported startup. Physical XR and its previously recorded
shutdown diagnostics remain outside this acceptance.

## Provenance

All attempts are retained. `lobby-01` used the wrong owner for the shadow atlas
setting and hit its deadline; the corrected RenderingServer call passes in
`lobby-02`. `import-01`, `navigation-01` and `lobby-03` retain an input-event type
inference error; an explicit Key annotation resolves it. `lobby-05` retains an
incorrect reflection enum name; the locally generated API supplied the corrected
name used by `lobby-06` and the final check. No failed run was overwritten.
The other captures isolate sky casting, map range/precision, filtering and fill.

Conceptual-thinking MCP checked the diagnosis plan and observer/domain boundary;
knowledge-graph memory supplied and retained the client constraints and results.
[Source/export hashes](source-manifest.json) freeze the delivered implementation.
Production delta: **+104 / −17 lines, net +87**, excluding tests/tooling/docs.
Growth adds the reusable desktop camera and focus handling, on-screen help and
lighting setup while removing the old main-script camera input. No Quod server
code, configuration, ontology, asset or persisted state was changed by this work.
