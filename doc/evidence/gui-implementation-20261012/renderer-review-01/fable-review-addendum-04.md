# Fable review addendum 4: renderer delta-04, disabled focus and disposal

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Earlier reports unchanged. Basis: `delta-04/` (two files) against `delta-03/`,
and the plan's keyboard statements in `delta-02/doc/gui-implementation-plan.md`
lines 472-477 and 538-543. No command, build, test or browser run; the
parent's MCP result is not claimed.

## 1. The two changes

- **Disabled focused control.** After the per-field update, `update/2` clears
  `texture.focusedControl` when the focused control is no longer enabled
  (`delta-04/client/src/workspace-panel.js`). This runs while `synchronizing`
  is still true, so the blur cannot be mistaken for an edit, and it covers
  every path that disables without a rebuild: lock on text, editor and
  numeric inputs. Read-only and `enabled` changes already rebuild, and
  rebuild and hide already clear focus. Correct and complete for the panel's
  own state transitions.
- **Disposal.** `dispose/0` now clears focus before `keyboard.disconnect()`
  and `texture.dispose()`, the same order as `rebuild/1`, so the keyboard's
  blur observer still runs and no reference to a disposed input survives.
  Correct.

## 2. Fixture

- The locked check dispatches a real `keydown` on the canvas and then
  requires focus null, editor and keyboard disabled, and editor text equal to
  the model value. Without the fix the focused disabled editor would have
  received the key and its visible text would have diverged; with the fix no
  control processes it. The assertion pair is the right shape: the null focus
  is the property, the unchanged text is the observable consequence.
- `sourceRetired` now also requires the keyboard hidden after the schema
  rebuild, which pins the focus-driven keyboard behaviour.

## 3. Withdrawal

My addendum 3 concern about keyboard permanence is withdrawn. The plan is
explicit that the keyboard is focus-driven and appears only for text and
number entry (lines 476 and 540-541), and the parent states that
`VirtualKeyboard.connect` already hides the keyboard on every connection, so
rebuilds hid it before this series as well. My reading of the blur observer
was right; my inference about the prior behaviour and the design intent was
not. The fixed vertical budget simply reserves space; nothing in the panel
forces a permanent keyboard.

## 4. Remaining note (Low, unchanged)

A rebuild or focus clear requested synchronously from inside a Babylon
observer callback would act on the control whose notification is running.
React's effect scheduling prevents that in production today; a comment or
guard would make the invariant explicit. No action needed for this scope.
