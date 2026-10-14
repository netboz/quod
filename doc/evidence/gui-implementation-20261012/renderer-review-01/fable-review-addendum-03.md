# Fable review addendum 3: renderer delta-03, focus ownership on rebuild

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Earlier reports unchanged. Basis: `delta-03/` (three files) against
`delta-02/` and `delta-01/`, plus
`../foundation-validation/spatial-error-audit-01.json`. No command, build,
test or browser run; the parent's MCP and backend results are not claimed.

## 1. The defect and the fix

The retained trace is `AdvancedDynamicTexture._manageFocus` reading
`isFocusInvisible` of an undefined `_lastPickedControl`, reached from a real
pointer move. By reading of Babylon's behaviour: control disposal clears the
texture's last-picked reference but not its focused control, so after a
schema rebuild disposed the focused source editor the texture still held a
focused control while the next move picked nothing, and `_manageFocus`
dereferenced the missing pick. The old browser assertions could not see it
because an exception inside a DOM event listener is reported to the window,
not thrown from `dispatchEvent`.

The fix sets `texture.focusedControl = null` at the start of `rebuild/1`,
before `keyboard.disconnect()` and disposal (`delta-03/client/src/workspace-panel.js`).
That is the right order: the setter blurs the old control while its blur
observers are still attached, so the virtual keyboard drops its reference to
the input before the input is disposed, and `_focusedControl` is null before
any later pick. Correct and minimal.

## 2. Fixture correctness

- `window` listeners for `error` and `unhandledrejection` are attached for
  the whole run and removed in `finally`; the result carries `browserErrors`
  and the shared checks assert it is empty before anything else. Listener
  errors from `dispatchEvent` are reported synchronously, so they are
  captured; the `MessageChannel` drain adds a real task boundary, which is
  what `unhandledrejection` and any Babylon callback scheduled as a task
  need. Sound.
- `sourceRetired` now also requires `texture.focusedControl === null` after
  the rebuild that removed the focused `source` editor. That is the direct
  regression check for this defect.
- Scope of the guard: errors raised inside the fixture's own `await` chain
  still reject the promise as before; errors in Babylon's render loop after
  the last `rendered()` are outside the window since the engine is disposed.
  Both acceptable.

## 3. One behaviour to verify (Medium)

Blurring the focused input now fires the virtual keyboard's blur observer.
By my reading of Babylon's `VirtualKeyboard.connect`, that observer sets the
keyboard invisible; it becomes visible again only when an input is focused.
Before this delta the editor was never blurred on rebuild, so the keyboard
stayed visible across a schema change. Now a rebuild hides it until the human
focuses a field. In production `PrologEditor` rebuilds whenever `selected`
changes (it is in the view memo), so choosing a predicate with the
`‹`/`›` controls would hide the keyboard. The fixture does not detect this:
it focuses `caption` explicitly before `keyboardInsideTexture`.

If the panel's design is a permanent keyboard, as its fixed vertical budget
implies, restore `keyboard.isVisible = true` at the end of `rebuild/1` (or
whenever no input is focused) and add an assertion that the keyboard is
visible immediately after a rebuild with nothing focused. If instead the
keyboard is meant to be focus-driven, the height budget and the hidden-state
reflow of the stack need stating. Either is fine; the fixture should pin the
chosen one.

## 4. Smaller notes (Low)

- A focused input that becomes disabled without a rebuild (lock while
  focused) keeps focus; the virtual keyboard is disabled under lock, but a
  physical keyboard still reaches `processKeyboard` and changes the visible
  text while the edit is ignored. Clearing `focusedControl` when the focused
  control's `isEnabled` turns false in `update/2` would close that.
- `rebuild/1` disposes controls synchronously; today it is only reached from
  React effects, never from inside a Babylon observer callback. A one-line
  guard that defers a rebuild requested during an observer notification
  would make that invariant explicit.
- Restoring focus to the same role when it survives a rebuild would be a
  usability gain, not a correctness need.
