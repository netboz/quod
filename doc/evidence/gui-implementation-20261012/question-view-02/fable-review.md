# Fable review: authenticated selected-question form projection (question-view-02)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `candidate.md`, `manifest.json`, the frozen `tree/` (AGENTS.md read),
diffed against the prior frozen copies in question-review-01/followup-01,
renderer-review-01, savepoint-review-01/implementation-01 and
component-review-01. No command, test or production edit was run. The gate,
client and build logs in the packet were read, not reproduced; their contents
match the candidate's statements, including the missing build exit.

## 1. Verdict

The projection is sound as authority and as data. One required contract
change before any renderer consumes it, two optional cleanups, no blocker.

## 2. Authority and scope (verified)

- Entry: `gui_question_entry(gui_question_form(Q, _), Human, _)` admits only
  the human named in the committed row, in any state
  (`gui_question.pl:41-42`). The body re-reads the row under
  `current_principal(Human)` (`:68-70`), so the entry and the body agree.
- Source hop: the row's `form_ref(Ns, Anchor, Form)` is followed with the
  exact anchor bound inside the ask (`:72-74`). The source entry
  `gui_submission_entry(gui_form_projection(Form, Human, Actor, _), Human)`
  requires `gui_question_policy(Form, Human, Actor)` (`gui_instance.pl:189-190`)
  and the body requires `current_principal(Human)` again (`:203-204`). A
  responder ontology therefore cannot pivot the read to another human: the
  human in the row must be the signing principal at the source, and the actor
  it presents is derived from its own identity (`gui_question_actor/2`), not
  from the row. This mirrors the submit path's `gui_validate_submission/6`.
- Current policy is checked at read time, not at opening. The test retracts
  the policy and shows the read fails even though the human holds a broad
  `can_invoke` grant in the application (`quod_gui_question_tests.erl:98-104`),
  which confirms the body, not only the entry, enforces it.
- Vocabulary hop: `gui_initial_values/4` reaches the vocabulary through the
  same `gui_initial_projection/3` grant the submit path already uses
  (`quod_gui.pl:34`); nothing new is granted there.
- The continuation is discarded at `submit(Control, _)` (`gui_instance.pl:205`);
  only the control identity leaves the ontology. `gui_compile/5` still
  forbids editor, bindings and catalogue kinds in a question form, so the
  client's five-kind restriction can only fire on a malformed reply.

## 3. Projection consistency (verified)

- One compilation: `gui_definition/5` runs `once(gui_compile/5)`; revision,
  tree, fields and control come from that single call, initial values from
  one vocabulary projection over those fields. The revision digest covers the
  tree, so the test's `help` attribute change moves the revision while the
  values token and defaults stay fixed (`tests:105-111`).
- Opened versus current: the row revision and `form_view` revision are
  distinct positions in the reply, and the client keeps them distinct
  (`world.js:220-221`). The accepted `submitted/3` state is returned verbatim;
  the client only checks its shape and never decodes accepted fields against
  the current schema (`world.js:211-217`). Correct.

## 4. Required

R1. **Editability is not a discriminant in the decoded result.** The decoder
returns `view`, `values` and `submit` for every state, with `state` as a raw
term and the two revisions as separate strings. Two cases look editable to a
consumer that reads `view` and `values` but not `state`:

- a `submitted` question, whose row cannot be submitted again
  (`gui_question_entry(gui_submit(...))` requires `awaiting`);
- an `awaiting` question whose source schema changed. `gui_submit/4` unifies
  the supplied revision with the row's opened revision, and
  `gui_validate_submission` then requires `gui_definition` to produce that
  same revision (`gui_instance.pl:151`). A stale question therefore cannot be
  submitted with either revision; it can only be cancelled. The projection is
  computed against the current schema, so rendering it as a form invites an
  answer that will always be refused as a proof failure.

Make the decoded result say which of the three it is: current and awaiting,
stale awaiting (cancel only), or submitted (accepted data only). Computing it
in `readGuiQuestionForm` from `state` and revision equality is a few lines and
keeps both renderers from re-deriving it. The server shape need not change.

## 5. Optional

O1. `gui_question_view/4` now has no client caller in any frozen tree; its
only readers are the tests. It differs from the form read in one property:
it still answers after the source policy is withdrawn or the source form no
longer compiles, when `gui_question_form/2` fails outright and the HUD would
have no state to show for a submitted question. Either document it as that
state-only fallback and have the client use it on form-read failure, or
retire it. Keeping two reads without a stated owner for each is what AGENTS
asks to avoid.

O2. `gui_form_projection/4` repeats the two lines of `gui_values/3` to avoid
a second compilation. A shared helper taking the compiled tree and fields
would remove the duplication without recompiling.

O3. The client test fixture is hand-written; no fixture is taken from a real
reply. Digest handling of escaped bytes is covered elsewhere, so this is a
coupling risk, not a defect.

## 6. Malformed reply rejection (verified)

`requireProjection` rejects variables and partial lists over the whole term.
Arity, functor, digest length, root identity versus `form_ref` form, control
present as a button, unknown or duplicate field identities, missing fields,
non-text text, selection outside options, non-integer or unsafe numbers, and
an unknown state atom all throw; the test enumerates each. Invalid UTF-8 in a
text default throws through the fatal decoder.

## 7. Scope note

The `catalogue_selection` rename in `codeForm` and the per-kind property
contract table in `readGuiView` arrived in this tree alongside the question
decoder. They align the client with the vocabulary's existing kinds and were
not reviewed further here.
