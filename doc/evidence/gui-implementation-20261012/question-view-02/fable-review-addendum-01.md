# Fable review addendum 01: followup01 (interaction discriminant)

Reviewer: Claude Fable 5.1, 2026-10-13. Consultative; source reading only.
Basis: `followup01/manifest.json` and its four files, diffed against the
question-view-02 base tree; `assessment.md`. No command or test was run.

## Verdict

R1 is resolved. The delta is three lines of decoder, one type line, four
test assertions and the plan text. Nothing else changed.

## Checked

- `interaction` is derived after every structural check. An atom state can
  only be `awaiting` at that point, since any other atom already failed the
  `submitted/3` shape test, so `state.type === 'atom'` is a safe test for
  awaiting. Revision equality is compared on the base64url digests, which
  are the same bytes under one encoding.
- `submitted` wins regardless of revision equality, which matches the
  backend: a submitted row cannot be submitted again whatever the schema.
- Tests cover all four combinations: awaiting with matching and mismatched
  revisions, submitted with matching and mismatched revisions.
- The type declares the three literals; no consumer needs to re-derive them.
- O1 disposition accepted: the plan now states `gui_question_view/4` is the
  metadata read for HUD status when the source cannot supply a form and
  that it never licenses a cached form or a submission. That is the owner
  statement the first report asked for.

## Nothing further required

O2 and O3 dispositions are reasonable and need no follow-up.
