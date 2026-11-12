# Phase 3 client gate run 04 stopped on `spaces`

Same check as run 03 (`SpaceChecks.cs`, picking the second created marker),
after the second space was given its own place. So run 03's diagnosis was
incomplete: the two markers did overlap, but the check also clicked before the
camera had re-framed the changed scene. Framing is queued for a later frame
and can be queued again when the closing form resizes the view; the camera
then still stood between the old markers and the new one.

The check is new in this phase; no production code is involved. Tries, each a
single `spaces` journey kept beside this note:

- `phase3-try01`: one-frame wait. Failed (one frame is not always enough).
- `phase3-try02`: diagnostic print of camera, poses and hit. Passed; showed a
  correctly framed camera and the right hit.
- `phase3-try03..05`: `Until(...)`. try03 hung to its deadline: that helper
  re-checks only on app change notices, and re-framing sends none.
- `phase3-try06..10`: re-check the pick each frame, at most 600 frames.
  Five passes out of five.

Run 05 repeats the client gates in full on `phase3-05-tree.diff`. Server gates
(`phase3-server-01-*`) are not repeated: every change since their frozen tree
is in `client/godot/tests/SpaceChecks.cs`.
