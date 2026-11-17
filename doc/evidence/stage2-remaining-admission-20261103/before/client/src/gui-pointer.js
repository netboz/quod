import { Vector2 } from '@babylonjs/core/Maths/math.vector.js'

// Babylon 9.18 has no public cancel-without-click for mesh GUI controls.
// Its force-up helper clicks. Keep this narrow adapter seam in one place;
// release real controls (including sliders) without changing their drafts.
export function cancelGuiPointer(texture, pointerId) {
  const control = texture._lastControlDown[pointerId] ?? texture._capturingControl[pointerId]
  if (control) control._onPointerUp(control, Vector2.Zero(), pointerId, 0, false, null)
  delete texture._lastControlDown[pointerId]
  delete texture._capturingControl[pointerId]
  texture._capturedPointerIds.delete(pointerId)
  const over = texture._lastControlOver[pointerId]
  if (over) over._onPointerOut(over, null, true)
  delete texture._lastControlOver[pointerId]
}
