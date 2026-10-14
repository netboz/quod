# Fable review addendum 1: desktop follow-up (followup-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
`fable-review.md` unchanged. Basis: `followup-01/tree` diffed against the
reviewed `tree/` (`GuiForm.tsx`, `gui-form.fixture.tsx`). No command, build or
browser run; the parent's MCP result is not claimed.

- **D1 fixed.** Text and numeric direct-entry inputs now use
  `disabled={!enabled || model.locked}` and `readOnly={field.readonly}`, so a
  read-only value stays focusable and readable; the steppers and the range
  input keep `!editable`, which is right since they are edit affordances;
  selects keep `disabled` for read-only, as HTML has no read-only select,
  and every read-only field gains a "Read only." description reachable
  through `aria-describedby`. `edit` is still gated by `editable`, so a
  change event on a read-only input changes nothing; the fixture proves
  focusability, non-editability and the help text in the description.
- **D2 fixed.** The controller-owned-kind placeholder is plain text.
- **D5 fixed.** The opacity label targets the range by id; the button is
  outside the label.
- **D3 fixed.** New checks: off-grid rotary entry retained with
  `aria-invalid` and a disabled stepper, read-only focus and refusal, help
  described, inherited disabled container blocking a stepper, and
  `unhandledrejection` captured alongside `error`.

Nothing new to raise. The fixture mutates decoded view fields in place,
which is fine because `GuiForm` reads fields on every render without
memoization; if a memo is ever added, the fixture must rebuild the view
object instead.
