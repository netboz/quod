# Phase 3 client gate run 05 stopped on `gui`

Second occurrence today of the `fresh` phase timeout in `ExportChecks.Mouse`
(`ExportLifecycle.cs:58`); run 02 was the first. Run 02's note called it a
known intermittent step without a cause. That was not good enough: the six
most recent gate runs before today show no such timeout.

Reproduced with a diagnostic print on timeout (`phase3-guitry01..15`, the last
seven each after a clean export; 14 passes, then `guitry15` failed):

    pushed=(256, -181) rectNow=(16, -205),(480, 48) window=(0,0),(472,656) hovered=none

The checkbox was scrolled out of the form viewport when the press was pushed.
The helper calls `ScrollContainer.EnsureControlVisible`, waits one frame and
presses; the scroll sometimes lands later. The keyboard step just before
leaves focus on a field at the bottom of the form, so the checkbox at the top
is off screen until the scroll happens.

This is a race in the existing test helper, in the form panel. It does not
involve the scene, marks or space ontology changed by this plan. Whether
today's changes shifted frame timing enough to expose it more often is not
established.

Fix (test helper only): repeat the scroll request and re-check each frame, at
most 600 frames, until the control's centre is inside the visible viewport,
then press. The diagnostic print is removed.

Run 06 repeats the client gates in full on `phase3-06-tree.diff`.
