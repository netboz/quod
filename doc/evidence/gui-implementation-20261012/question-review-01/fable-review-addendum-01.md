# Fable review addendum 1: question follow-up (followup-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
`fable-review.md` unchanged. Basis: `followup-01/tree` diffed against the
reviewed `tree/` (`gui_question.pl`, `quod_gui_question_tests.erl`). No
command or test run; the parent's gate is not claimed.

## 1. The view projection

`gui_question_view/4` is a pure read of the authoritative row: entry grant
and body both bind the row to the authenticated principal, nothing is
copied, `no_follow` is declared. The accepted fields inside a `submitted/3`
state are returned only to the human who supplied them, and the source
reference and revision are exactly what a HUD needs to fetch the ordinary
component view under its own identity. Correct and minimal. The transition
rules are otherwise unchanged.

## 2. Tests against the earlier findings

- **T1 closed.** `SourceHelperGrant` lets the actor run `R::gui_consume(Q)`
  from a goal admitted in the application, so the chain head is the
  legitimate source and the responder's consumption entry passes; the call
  still fails because `gui_application_active/1` is not staged, and the test
  asserts the row and HUD reference survive. `HudHelperGrant` does the same
  for `Human::gui_unlink` from a responder goal, failing on the missing
  `gui_retiring/2`. `assert_no_guards/3` checks both guard relations are
  empty after completion and after cancel. These now exercise the guards,
  not the ACLs.
- **N3 closed.** A second human with its own policy row cannot submit this
  question; a second responder with another policy row cannot continue it;
  a row whose source anchor is wrong cannot be submitted but can still be
  cancelled, which is the right asymmetry since cancel never consults the
  source.
- **View coverage.** Readable before and after submit with the exact state,
  unreadable after completion, refused for the other human, and an unchanged
  repeated HUD or view read performs no history, projection or file I/O.
- **Submit versus cancel race** resolves to exactly one committed outcome
  and the follow-up branch handles either winner.

## 3. Still open

**R1** from the original report is unchanged: a `submitted` question whose
completion keeps failing has no authorized retirement path. This follow-up
did not claim it; it should be named before the lifecycle slice.
