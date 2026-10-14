# Fable review addendum 1: renderer delta-01 against R1 to R9

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-12. Consultative only.
`fable-review.md` is unchanged. Basis: `delta-01/` (eleven files) diffed
against `tree/`. No command, build, test or browser run; the parent's
reported fixture and gate results are not verified or claimed.

## 1. Finding by finding

- **R1 fixed.** `gui_workspace/3` now builds a raw tree and compiles it with
  `gui_tree_schema/2`, so built-in views carry the full contract (`help`,
  `enabled`, defaults) from one declaration (`delta-01/priv/ontologies/quod_gui.pl`).
  `catalogue_selection` is a distinct kind for controller-supplied catalogues;
  standard `selection` requires declared options in both the vocabulary and
  the decoder (`world.js`, `world.test.js` "Missing catalogue"). Erlang tests
  read the new shape.
- **R2 fixed.** Per-kind contracts in `readGuiView` reject misplaced keys;
  tests cover `range` on four wrong kinds. The table matches the vocabulary's
  `gui_attribute/4` rows I checked: form and container get `layout`;
  text_box `required`, `readonly`, `max_bytes`; selection `required`,
  `readonly`, `options`; numeric kinds `required`, `readonly`, `range`,
  `unit`; editor and catalogue_selection `readonly`; button and bindings
  nothing beyond the common three.
- **R3 fixed.** Actions sit in a bounded `ScrollViewer` capped at two rows;
  button labels wrap; the fixture renders 22 buttons, scrolls to the last and
  checks the keyboard stays inside 1440 px.
- **R4 fixed as designed.** A missing or invalid value shows an empty input
  plus a range message with slider and steppers disabled, never an invented
  number; invalid text is passed to the controller as the draft so a later
  submission cannot carry the previous valid number; `change/1` emits only
  when the quantized candidate differs from the current value.
- **R5 fixed.** Real `PointerEvent`s on the canvas drive picking through the
  plane, button press, dial drag and a release outside the plane
  (`workspace-panel.fixture.js` `pointAt`/`pointer`). The parent's note that
  `pointermove.button` must be `-1` is consistent with the DOM spec for
  non-button moves. The rotary is now a `Slider` subclass, so capture, dual
  controller filtering and canvas blur are the base class's; disposal and
  disabling cancel through `_onCanvasBlur`.
- **R6 fixed.** Captions and help use `resizeToFit` with wrapping; inputs get
  `focusedBackground` and `disabledColor`; selections have an opaque surface.
- **R7 fixed.** An unknown current value selects the first option in both
  directions.
- **R8 fixed.** Required and UTF-8 byte feedback on text boxes, numeric
  range feedback on sliders and knobs; the fixture checks the 16-byte
  message and the required message.
- **R9 fixed.** Both controllers memoize the view; the renderer skips
  serialization when the same view object is passed.

## 2. Points to settle

- **Presentation kinds are now admissible in application forms (Medium).**
  `gui_kind(editor)`, `gui_kind(bindings)` and `gui_kind(catalogue_selection)`
  let `gui_compile/5` accept these kinds as non-field leaves in any common
  form (they are excluded from `Inputs`, so the field check passes). A
  generic client would then render an editor that emits edits nobody owns
  and a catalogue selection with no catalogue. Either refuse them in
  `gui_compile/5` for application forms, or state in `quod_gui.pl` and the
  plan that they are controller-owned and a common form containing them is
  invalid, with a test.
- **Private Babylon members (Low).** `RotarySlider` overrides
  `_onPointerDown`, `_updateValueFromPointer`, `_draw` and uses
  `_applyStates`, `_currentMeasure`; the panel calls `_onCanvasBlur` on the
  opacity slider and numerics. These are underscore APIs. Pin the Babylon
  version and add a load-time assertion that the overridden members exist,
  so an upgrade fails loudly rather than silently losing capture cancel.
- **Invalid draft display (Low).** While a draft is invalid or missing the
  slider is set to `min`, so the thumb or dial shows the range start under a
  disabled control. Keeping the last valid position, or hiding the thumb,
  would avoid suggesting a value the model does not hold.
- **Immediate required message (Low).** An empty required text box shows
  "This field is required." before any interaction, which is defensible but
  stronger than the plan's "editable required text may start empty"; showing
  it after the first edit or on blur is the usual choice.

## 3. Checks that passed by reading

Root form compiles with `layout` default; `editor` and `catalogue_selection`
get `readonly` from the added `gui_attribute/4` clause without duplicating
the input row (the `isa` tests are disjoint); `help` defaults to empty and is
skipped; invisible feedback blocks do not take stack space; the selection
`choose` guard still refuses when locked, inactive or read-only; the action
viewport height is reset by the mandatory close button on every rebuild;
numeric cancel runs on hide, disable and dispose; the byte count uses UTF-8
like `max_bytes` on the ontology side.
