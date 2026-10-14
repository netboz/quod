# Authenticated selected-question form projection

Read frozen AGENTS.md. Source-only review; no commands/tests/production edits.
Review gui_form_projection/4 and gui_question_form/2, the readGuiQuestion and
readGuiQuestionForm client additions, and their production-seam coverage.
Save concise fable-review.md here. Prior lifecycle/component code is context.

The exact assigned human reads the question and anchored source form under
ordinary ACL. The source checks current policy; one gui_definition compilation
supplies revision, component tree and initial values, without returning the
continuation. Stored opened revision stays distinct from current schema revision.
Accepted state is returned as data and is not reinterpreted against a changed
schema. Common controls use the existing portable component decoder.

Backend gate02: 3 tests, zero failures, true exit 0 (40.234s). Gate01 retained:
a stale /tmp fixture from an earlier failed VM collided with unique_integer;
fixtures now use random suffixes; old directory and logs preserved. Client02:
15 files passing, true exit 0. Earlier decoder fixture failure logs preserved;
empty binary fixture corrected to actual wire grammar. UI build01 log reports
successful build; the tool response with child status was lost at compaction,
so no true exit claim is made for that invocation. No headset validation.

Verify authority, scope/anchor, projection consistency, malformed reply rejection
and whether submitted/stale states can be mistaken for editable current state.
This delta does not implement opening or automatic completion.
