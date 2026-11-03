# Bounded shared presentation correction

The real renderer isolates two ordinary presentation defects. The admitted
controller's shaded material receives no illumination in the original black
scene. The GUI texture is independently stretched onto a fixed-aspect quad.
Neither result establishes the complete cause of Yan's physical distance or
contrast experience.

The [baseline report](presentation-baseline-render01/client-result.json) and
retained four PNGs show zero lit pixels in the original 640×480 raster, zero
with ambient disabled, 1,810 with only neutral ambient illumination, and zero
after restoration. Black background corners, imported material/texture identities
and model counters remain unchanged. The actual before export exits 1 with EOF;
its four failed obligations stay failed in that retained campaign.

The responsible correction is in the existing ScenePanel world environment.
It supplies neutral ambient illumination while preserving the black background,
authored PBR material, verified GLB bytes, admission, MIT notice and resource
owner. No hand tint, unshaded replacement, light domain or engine patch is added.

OpenXRInput now projects GUI dimensions onto its existing one-metre-high quad,
preserving texture aspect. Ray bounds and pixel mapping use that same quad.
The existing source attachment subscribes to actual viewport size changes;
retirement removes that subscription. Any changed pixel layout cancels captures
and disarms gestures. Unchanged notices do not cancel input or set mesh size.
The existing world placement and calibration are unchanged.

The [angular calculation](inputs/angular-size.json) records the tradeoff. At the
case07 1850×496 texture and reference distance of two metres, nominal 16-pixel
text changes from 0.37165×0.92411 degrees to 0.92411×0.92411 degrees. Panel width
changes from 1.5 to 3.72984 metres, spanning about 86 degrees rather than 41.
This is a geometric font-em calculation, not measured glyph ink, readability,
comfortable reach or proof that the physical distance complaint is resolved.
Other window layouts have different dimensions. No unexplained distance constant
or panel-following behavior is introduced.

The [exact final02 qualification](qualification.json) binds 92 supplied inputs,
196 export outputs and five true-zero source-only build commands. Sequential
headed checks pass presentation 15, controller/native GUI 49 and scene 15 on one
exact export, with client/driver/wrapper zero, both streams EOF and no timeout,
reader error or stack capture. Controller input is explicitly injected through
XRServer; actual desktop pointer delivery retains the owned PID/window guard.
These tests establish no new physical gesture or headset readability pass.

The new controller test initially failed an overstrong one-update assertion.
The [bounded diagnostic log](presentation-resize-diagnostic-check01/stdout.log)
records three actual sizes during anchor setup: (2,496), (2,2), (800,800), causing
two meaningful mesh changes. Capture was zero, button released and clicks
unchanged. Fixture anchor setup now precedes the measured press. The same strict
one-update assertion passes for one actual resize; same-aspect pixel resize still
cancels, and twenty unchanged notices produce zero mesh/model work and retain a
valid capture. The temporary trace is absent from final02. Both failed controller
attempts and their exact separate source/export inputs remain retained.

Only two production owners change, +17/−3 lines. Tests change +99/−1, including
the new real-renderer partial; README adds three lines. The [source delta](inputs/source-delta.json)
and [actual previous-source patch](inputs/previous-source-delta.patch) record
every input identity. No specification or relocation changes. Main, Core,
SignedView, signing, preferences, physics and server inputs are unchanged.
Accepted core189 and all 1,432 server inputs/M3b gates are reused without another
server/core campaign. Full M4 remains unaccepted.

Full affected commands and nested exits are in each `client-…/result.json`,
the [build manifests](inputs/client-presentation-final02-manifest.json), and the
separate outer receipts under the physical evidence's `logs` directory. All
heavy stage/dependency/output bytes and raw streams remain under the authorized
task-private `/data` root. Generic pinned archives are referenced, cold restored
and checked; compiled application inputs are never copied into clean builds.

Final payload: DLL `f68794b48b2ae370b2422474e41a8afdf34cda14e11235b3e7b56bf9210ca59f`,
PCK `19ff8edf9912b83a36b71ff70abfdad4887ca7270392d4f2b69cda37de0eea36`,
private clean engine `02310d903099bada10c86cedc90bbc11ef0bec8254d6e607d1a53f6150ab0268`.
This is the ordinary main scene with qualification only behind the explicit
qualification flag; no physical04 observer or temporary resize trace is included.
