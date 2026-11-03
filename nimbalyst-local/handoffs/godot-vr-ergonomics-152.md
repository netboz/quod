# VR ergonomics steering for the active Stage 2 implementation

Yan asked on 2026-10-31 to design the GUI/experience for human ergonomics and
review VR documentation on the web before building it. This steers the existing
Stage2 task in the same sole Sol session; it does not start another ticket,
framework, review, hardware case or implementation writer. Read AGENTS.md and
the current GUI contracts. The coordinator read the primary sources below on
2026-10-31 before issuing this handoff.

## Source findings and their limits

- [Google Android XR: scale and visual design](https://developer.android.com/design/ui/xr/guides/visual-design)
  recommends keeping primary work within roughly 41 degrees of view, checking
  readability at different distances/angles, visibly distinguishing interaction
  states and leaving space between targets. Its dp/dmm conventions are specific
  to that platform; Godot viewport pixels are not Android dp.
- [Microsoft: comfort](https://learn.microsoft.com/en-us/windows/mixed-reality/design/comfort)
  favors frequent work around a neutral head posture, limited neck rotation and
  low sustained arm effort. Persistent UI rigidly following head rotation can
  be uncomfortable. Preserve Quod's stable workspace and explicit recall/move
  controls; do not infer headset wear or introduce head following.
- [Microsoft: typography](https://learn.microsoft.com/en-us/windows/mixed-reality/design/typography)
  expresses text size through visual angle: its comfortably readable example
  is about 0.6–0.75 degrees. That is a useful starting comparison, not a Vive
  certification. Font em size is not actual glyph height, and lens/display
  resolution, weight and contrast matter.
- [Microsoft: buttons](https://learn.microsoft.com/en-us/windows/mixed-reality/design/button)
  gives about 1 degree as a minimum ray/gaze target example at two metres and
  recommends clear interaction feedback and opaque menu backing. This is a
  minimum example from another device family, not an optimal universal target.
- [Meta: hit targets](https://developers.meta.com/vr/design/styles_inputs_hit_targets/)
  stresses generous selectable areas, separation without overlapping hit areas,
  and validation on the actual hardware. Hand-tracking sizes are not direct Vive
  controller requirements. Do not add invisible hit expansion that crosses
  neighboring controls or contradicts the real native GUI target.
- [Meta: ray interaction](https://developers.meta.com/vr/design/raycasting_bp/)
  supports controller-trigger selection with clear pointer/selection feedback,
  avoiding prolonged uncomfortable pointing and tiny densely packed targets.
  Recommendations about guessed shoulder origins, magnetism or hand gestures
  do not authorize changing Quod's canonical pose/picking/input policy.

These are design guidance from other platforms, with different optics and
modalities. They inform our own measurable criteria; screenshots/software
geometry cannot establish Vive comfort or physical readability.

## Apply to the existing shared presentation

1. **Place the work where a person can use it.** Summon/recall from the actual
   tracked reference with an upright panel and discoverable Move/Recenter/Hide.
   Keep important controls near a neutral view and the task's context visible.
   Do not require looking far up/down, locating a panel behind the user, or
   holding arms up during reading. First-tracked-before-wearing remains an
   explicit known limit, not an inferred wear detector or permission to reset
   calibration. User-initiated placement stays under the existing owner.
2. **Design the central task, not a desktop shell.** Show the exact selected
   subject, a small clear set of available representations, the current form
   and its primary action. Place diagnostic identifiers and complete technical
   replies behind the existing detail affordance. Preserve exact identity,
   offers, drafts and original outcomes. Keep Back/Close/Cancel/Recall visible
   where applicable and explain disabled/expired state inside the headset.
3. **Measure angular readability and targeting.** For actual layouts, record
   panel physical dimensions/distance, view angle, actual native glyph/label
   and target rectangles, spacing and clipping. Test default and large text,
   narrow layouts and near/far settings through the same GUI owner. Essential
   controls must remain usable after reflow. Use the platform examples above
   as starting points, never by copying dp values into Godot pixels.
4. **Coordinate distance, scale and text.** Current local controls independently
   allow distance 0.6–4m and font size 16–48. A fixed physical panel can become
   too wide when close or too small when far. Assess those real combinations;
   use the smallest shared presentation correction for any demonstrated gap.
   Do not silently turn a heuristic into a domain budget or remove intentional
   user control. Avoid unexplained automatic panel movement while interacting.
5. **Make selection predictable.** Keep the authored mapping truthful; visible
   hover/selection/pressed/disabled feedback must agree with the action that
   release will take. Provide a short cue in the interface. Allow ordinary
   ray/trigger native controls for main tasks. A direction diagram is useful
   feedback but does not make an eleven-option menu physically validated.
   Do not move a target beneath a held pointer when help/status updates.
6. **Keep interaction effort low.** Prefer short explicit actions and readable
   task steps over sustained pad holds, repeated precise targeting or long
   controller text entry. Preserve existing cancellation, neutral rearm,
   capture/modal/travel fences and one-activation rules. No synthetic body
   assumptions, pose filtering, automatic refocus/login or forced success.

## Concrete current-source calculation

The current spatial viewport is 1200×800 and its one-metre-height panel is
1.5m wide. For a centred flat panel, angle = 2 atan(size/(2 distance)). Python
calculations are retained in the coordinator's
`_build/godot-m4-r2-coordinator-20261029/vr-ergonomics-angular-152.json`.
At the two-metre default the full width is about 41.11 degrees. At the allowed
0.6m setting the same width spans about 102.68 degrees. With a 16px em box at
4m the nominal font-box angle is about 0.286 degrees; actual glyph height still
needs measurement.
These are derived idealized geometry examples, not measured human poses,
actual glyph readability, a diagnosis of Yan's past look or a comfort pass.
They identify distance/text combinations worth checking before declaring a
new layout ergonomic.

Continue the already-authorized Stage2 work. Integrate relevant sizing/reflow/
selection obligations into its existing affected native-Control/renderer tests;
do not start another broad test campaign or rerun unchanged suites. Carry any
unresolved physical comfort point honestly to the next separately authorized
short human journey, with instructions entirely inside the headset. No new
physical case, device/display query, external consultation or global change
is authorized here. Include this source addition in the next normal handoff.
