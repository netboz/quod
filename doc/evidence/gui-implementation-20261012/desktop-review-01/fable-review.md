# Fable review: desktop common controls (desktop-review-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: the frozen `tree/` (AGENTS.md identical to the component packet) and
diffs of every shared client file against its last reviewed renderer version
(numeric control and panel against renderer delta-02/04, spatial fixture and
checker against delta-04/03). No command, build, test or browser run; the
parent's client tests, build and MCP results are not claimed.

## 1. Verdict

The desktop adapter keeps the controller as the only owner of drafts,
submissions and action availability, renders the same closed component suite
from the same model, and the extracted helpers are byte-for-byte equivalent
to the inline code they replace. The DOM fixture is deterministic and checks
the right properties. Findings are bounded: read-only fields are rendered as
disabled (D1), the placeholder for controller-owned kinds uses an assertive
role (D2), and the DOM fixture lacks a few parity cases (D3).

## 2. Verified

V1. **Authority and drafts.** `GuiForm` edits only through `model.edit`
gated by `enabled`, `locked` and `readonly` (`ui/src/GuiForm.tsx:32-35`),
invokes only button roles the controller enabled (`:44-45`), and never
submits. Invalid numeric drafts are retained and shown in the direct-entry
input with `aria-invalid`; the slider and dial are hidden and the steppers
disabled while the draft is invalid (`:49-52, 68-82`). The fixture proves a
stepper click cannot replace an invalid draft and that an invocation
snapshot carries the current draft (`ui/test/gui-form.fixture.tsx:54-61`).

V2. **Helper equivalence.** `numericControlRange/1`, `numericDraft/2` and
`textFeedback/2` (`client/src/gui-values.js`) reproduce the previous inline
checks exactly: same guards, same `last`, same grid test, same messages. The
spatial numeric control and panel now call them with the same inputs,
including the `undefined` value path, which `numericDraft/2` maps to `null`
as before.

V3. **Grid parity.** The native range input uses `min`, `max=last` and
`step`, and HTML steps are relative to `min`, so keyboard and pointer
changes land on the ontology grid; steppers add or subtract `step` from the
parsed draft and are disabled at the ends. The dial rotates over the same
±135° sweep as the spatial dial and is `aria-hidden` behind the range input.

V4. **Disabled and locked semantics.** Container state is inherited per
field as in the spatial adapter; buttons combine inheritance with the
controller's `enabled` map; lock disables every input and the fixture
asserts no invocation leaks while locked. Disabled controls stay opaque
(`gui-form.css:7`), targets are at least 44 px, focus is visible, narrow
layout wraps without horizontal overflow.

V5. **Spatial fixture correction.** The release point is now one canvas size
beyond the top-left corner and the fixture asserts, via `scene.pick` with a
mesh predicate, that the release ray misses the panel before dispatching the
up event; the checker requires `outsideMesh`. The up event is dispatched on
the canvas element, so Babylon still receives it and delivers it to the
capturing slider. No production pointer code changed.

## 3. Findings

### D1. Read-only is rendered as disabled (Medium, accessibility)

`editable` folds `field.readonly` into the same `disabled` attribute as
`enabled` and `locked` (`GuiForm.tsx:33, 58, 61, 81`). A read-only value is
then removed from the tab order and announced as unavailable, which is the
wrong semantic for a value the human is meant to read and echo. HTML has
`readOnly` for exactly this: focusable, readable, not editable. Use
`readOnly` for `field.readonly`, `disabled` for `!enabled`, and either for
`locked` (disabled is defensible for a transient busy state). Selections have
no native read-only; keep `disabled` there but add the description "read
only" the plan asks for. The spatial adapter cannot distinguish these, which
is fine; the desktop can and should.

### D2. Placeholder for controller-owned kinds uses `role="alert"` (Low)

`editor`, `bindings` and `catalogue_selection` fall through to
`<p role="alert">` (`:84`). An assertive live region re-announces on every
render and is for urgent interruptions. These kinds never reach `GuiForm`
through a common form (the ontology refuses them), so this is a model error
path; render it as plain text or `role="note"`.

### D3. DOM fixture parity gaps (Low, tests)

Not exercised: a disabled container disabling its children, a read-only
field, keyboard stepping on the range input (ArrowRight by `step` from a
non-zero `min`), an off-grid direct entry on the rotary, help text rendering,
and `unhandledrejection` capture (the spatial fixture records both error
kinds). Each is one or two lines in the existing fixture.

### D4. Submission availability with an invalid draft (Low, controller note)

`enabled.apply` is controller-owned, so `GuiForm` correctly does not decide
it. The future question controller should derive it from the same helpers
so a known-invalid draft cannot be submitted only to fail at the ontology.

### D5. Minor (Low)

- `numericControlRange/1` throws during render on a malformed range; the
  decoder already refuses such views, so only a hand-built model can reach
  it. An error boundary around `GuiForm` would turn that into a visible
  refusal instead of a blank panel.
- The opacity label wraps a button; clicking the label text focuses the
  range, which is fine, but the label's accessible name includes "Opaque".
  Move the button outside the label.

## 4. Not covered

Live question controller, opening, recovery, routing, headset ergonomics and
the backend are outside this packet and this review.
