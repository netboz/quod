# Fable review: common component renderer (renderer-review-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-12. Consultative only.
Basis: the frozen `tree/` of this packet (manifest files), `tree/AGENTS.md`
(identical to the component packet's), and the component-review delta-03 for
ontology diffs. No command, build, test, browser or headset run was performed;
the parent's reported browser and MCP results are not verified or claimed
here. Line numbers refer to `tree/`.

## 1. Summary

The decoder is strict where it matters and the renderer's state inheritance,
integer grid and schema replacement are correct by reading. The findings are
bounded and concrete:

- **R1** built-in workspace descriptors are hand-assembled by
  `gui_workspace_fields/2` and bypass the vocabulary contract, so the decoder
  must stay more lenient than `quod:gui` (no `options` on a selection, no
  defaults); this is a second descriptor producer.
- **R2** the decoder accepts kind-inappropriate properties, so "unsupported
  descriptor" is not yet an exact refusal.
- **R3** the fixed vertical budget leaves no room for more than three action
  rows; the keyboard falls off the texture at 22 buttons.
- **R4** a numeric control shows `undefined` when the controller omits a
  value, and emits an edit on every slider move even when unchanged.
- **R5** the pointer lifecycle test drives observables directly; real pick,
  capture and drag-release outside the dial are unverified.
- **R6 to R9** clipping of long labels and help, selection wrap from an
  unknown value, no inline feedback for off-grid or over-length input, and
  per-render view serialization.

Nothing here touches callback authority: roles only select controller
functions the controller itself whitelists, and the built-in forms refuse any
role or kind outside their expected map.

## 2. Verified facts

F1. **Decoder contract** (`client/src/world.js:89-157`). One `component/4`
root of kind `form`; every component needs a non-empty label; roles are
`renderTerm(id)` and unique across the tree; children only under `form` or
`container`; properties are a closed set with duplicate keys refused; numeric
`range` must be safe integers with `step > 0` and safe span; options must be
a non-empty list with unique rendered ids; unknown kinds and properties throw.
`client/test/world.test.js:54-82` covers the malformed cases listed in the
request, including `setting(X)`, zero step, unsafe span, float step, duplicate
option, duplicate property, unknown property, flag `maybe`, leaf with children
and non-form root.

F2. **Built-in forms are role-gated** (`world.js:159-188`). `formLabels/2`
requires exactly the expected role-to-kind map and nothing else;
`proofForm` and `codeForm` are the only consumers;
`test/world.test.js:29-52` proves an extra `execute_javascript` button and a
kind swap are refused. Controllers map roles to their own functions and
ignore anything else (`ui/src/Console.tsx:59-60`, `ui/src/PrologEditor.tsx:169-178, 207-209`).

F3. **Nested disabled and read-only** (`client/src/workspace-panel.js:132-134,
169, 185, 202, 236, 265-279`). `active` is inherited down containers and
combined with each control's own `enabled`; buttons additionally need the
controller's `enabled[role]`; inputs, numerics and selections need
`!locked && active && !readonly`. This matches `gui_tree_active/2` on the
ontology side.

F4. **Integer grid** (`client/src/numeric-control.js:11-14, 22-24, 62-69,
75-80`). `last = min + floor((max-min)/step)*step`; slider runs continuous
from `min` to `last` and every candidate is quantized relative to `min`,
avoiding Babylon's zero-relative step; direct entry accepts only
`^-?\d+$`, safe, within `[min, last]` and on the grid; plus and minus step
by `step` and are disabled at the ends. The fixture's expected values
(`7`, clamp to `11`, `8` ignored, knob `20`, `15`) follow from this code.

F5. **Schema replacement** (`workspace-panel.js:128-131, 247-250`). The view
is re-serialized on every update and rebuilt only when it changes; rebuild
disconnects the keyboard, disposes all content and action controls and
re-registers fields. Live catalogues (`choices`) are not part of the
signature, so catalogue updates do not rebuild. The fixture checks retired
controls and keyboard reconnection (`workspace-panel.fixture.js:76-104, 124`).

F6. **Opacity is background-only** (`workspace-panel.js:22-23, 63-67`); the
fixture asserts control alpha stays 1 (`:73-74`).

F7. **Ontology side.** `gui_view/2` now builds `component(workspace, form,
[property(label, Title)], Children)` through `gui_workspace/3` and
`gui_workspace_fields/2` with `=..` over the authored field terms
(`priv/ontologies/quod_gui.pl:174-200`); `choice` and `input` aliases are
gone; both helpers are `no_follow`. `test/quod_lobby_tests.erl:292-295,
609-612` read the new shape. `gui_instance.pl` is identical to delta-03.

F8. **Migration.** `Console.tsx:52-61` derives its fields from the
`proofForm` labels with fixed kinds; `PrologEditor.tsx:184-211` passes the
descriptor fields through and replaces `source` with client-local layout,
clause, head, body and card-button controls, or with a `bindings` display
when not editable. Those client-added roles never pass `formLabels/2` and
never reach an ontology.

## 3. Findings

### R1. Two descriptor producers; built-in views bypass the contract (Medium)

`gui_workspace_fields/2` emits `component(Id, Kind, [property(label, L)], [])`
for every built-in field (`quod_gui.pl:198-200`). It never runs
`gui_component_schema/4`, so built-in selections carry no `options`,
no component carries `enabled`, `help` or `readonly`, and `editor` and
`bindings` are kinds that `gui_kind/1` does not know (`quod_gui.pl:71-77`).
The decoder therefore cannot require `options` on a `selection`
(`world.js:134-147` only validates when present), and `readGuiView` accepts a
descriptor the vocabulary would refuse. The parent states this is interim
until the producer/controller replacement; AGENTS.md asks that the
replacement retire the old path in the same scope. Until then the decoder's
leniency is a portability gap for application forms: a selection without
options renders with no choices and no error (`workspace-panel.js:224-225`).

**Proposed.** Either compile the built-in views through `gui_tree_schema/2`
with explicit `options` catalogues marked as controller-supplied, or make the
decoder require `options` for `selection` unless the caller declares a live
catalogue for that role, and document `editor` and `bindings` as built-in-only
kinds. Add the "selection without options" case to `world.test.js`.

### R2. Kind-inappropriate properties are accepted (Medium)

`readGuiView` validates each property's value but not its applicability:
`range` and `unit` on a text box, `layout` on a leaf, `readonly`, `required`
and `max_bytes` on a container or button all decode (`world.js:107-147`).
The vocabulary never emits them, but the plan makes the receiver's
acceptance of "a supported descriptor" an authoritative refusal, and that
needs an exact rule. The renderer then silently ignores them.

**Proposed.** A per-kind allowed-key table in the decoder, mirroring
`gui_attribute/4`, and tests for one misplaced key per kind.

### R3. Vertical budget overflows at four action rows (Medium)

Fixed heights: title 56, scope 54, appearance 70, viewport 650, keyboard six
rows of 48 plus padding, actions `70 × rows` (`workspace-panel.js:42-98,
114-126`). Seven buttons fit a row (`floor(1200/165)`), so three rows reach
about 1400 of 1440 px and a fourth row pushes the keyboard off the texture.
The ontology has no button budget, and the fixture's largest form has ten
buttons (two rows, `workspace-panel.browser.mjs:55`). Long button labels at
24 px in 165 px (`Check saved outcome`) are also clipped by Babylon.

**Proposed.** Place the action rows inside the scroll viewport or give them
their own bounded viewer, and let `action/3` size buttons by text; test a
form with 22 buttons for texture bounds as the fixture already does for ten.

### R4. Numeric control with a missing value shows `undefined` and edits on no change (Medium)

`numeric.update(next.values[role], …)` passes `undefined` through
(`workspace-panel.js:270`); `Number(undefined)` is `NaN`, the input shows
`undefined`, and the thumb sits at `NaN` (`numeric-control.js:87-101`).
Text and selection fields default to `''` (`:272`). Separately,
`change/1` calls `edit(String(quantize(candidate)))` on every slider
`onValueChanged`, including the echo when the controller writes the same
value back, so a drag emits many identical edits per frame
(`numeric-control.js:23-25, 68`).

**Proposed.** Default a missing numeric value to `min` and disable the
control until the controller supplies one; in `change/1` skip when the
quantized candidate equals the current value.

### R5. Pointer lifecycle is exercised by direct observable calls (Low, evidence)

The fixture notifies `onPointerDown/Move/Up` observables with synthetic
coordinates and clicks buttons by `onPointerClickObservable.notifyObservers`
(`workspace-panel.fixture.js:41, 163-167`). That verifies the control logic,
not Babylon's pick through the plane, pointer capture, drag that leaves the
dial, or release outside it. `dial.onPointerUpObservable` relies on Babylon
delivering the up event to the capturing control; I did not verify that in
the Babylon version in use. The MCP run adds real rendering, not real input
routing. State this limitation beside the browser evidence.

### R6. Long labels and help are clipped (Low)

Captions are 36 px without wrapping and help is 48 px with wrapping
(`workspace-panel.js:172-181`); container headings are 40 px (`:140-142`).
Two-line help or a long label is cut. Row cells at 600 px halve the width.
Plan section 8 asks for legible text and visible states.

### R7. Selection wrap from an unknown current value (Low)

With `findIndex` returning `-1`, `next` goes to the first option but
`previous` goes to the second-to-last (`workspace-panel.js:226-227`).
Start both directions from the first option when the current value is not
in the catalogue.

### R8. No inline feedback for refused direct entry or over-length text (Low)

Off-grid numbers are silently ignored and restored on blur
(`numeric-control.js:75-83`); `max_bytes` and `required` are decoded but
unused (`world.js:119-128`, renderer). The ontology enforces them at
submission, which is correct for authority, but plan section 8 and the
accepted P3-1 disposition ask for inline field feedback. A visible refusal
state on the number input and a byte counter on text boxes would satisfy it
without moving validation to the client.

### R9. View serialization per render (Low)

Both controllers call `setWorkspace` from an effect without dependencies
(`Console.tsx:51-62`, `PrologEditor.tsx:183-211`), so every render
serializes the whole view (`workspace-panel.js:249`). Cheap today; a
32-field form with options lists makes it a per-keystroke cost. Memoize the
view object in the controllers or hash once per view change.

## 4. Checks that passed by reading

- Row layout: columns are `min(children, floor(width/560))`, so a row at
  1200 px gives two 600 px cells and a nested row inside a 600 px cell
  collapses to one column; the widest numeric row (minus, slider at
  `max(64, width-410)`, plus, 170 px input) fits a 600 px cell. No clipping
  path found for the layouts the vocabulary can produce.
- Rotary mapping and indicator rotation agree (`numeric-control.js:43-57, 99`);
  the centre dead zone and angle unwrapping prevent jumps.
- Locking: `keyboard.isEnabled = !locked`, inputs and selections disabled
  under lock, numeric drag cancelled when disabled (`numeric-control.js:91`).
- Rebuild while a control is focused: `focusedControl` is cleared only on
  hide; after a rebuild the disposed control's observables are cleared
  (fixture asserts). Whether Babylon clears `focusedControl` on dispose I did
  not verify; the fixture refocuses explicitly.
- Dispose retires the mesh and observers; the fixture's `hasObservers`
  check is the right public predicate for pending compaction.
- Option values are rendered Prolog text and round-trip through the
  controller's `values` map unchanged; parameterized ids such as
  `setting(2)` work as roles and Babylon control names.

## 5. Not covered by this packet

Question opening, HUD, lifecycle, a desktop DOM adapter, headset ergonomics
and the backend descriptor gate are outside this slice and this review. Test
gaps worth adding now: a disabled container containing a button, a nested
`form` child, a read-only text box, a three-child row, help text present,
unit on a slider caption, a numeric role with no value, a selection whose
current value is not in the catalogue, and the four-row action case.
