# Executable application forms

Use the existing GUI component classes, schema/binding rules and question
completion transaction for two ordinary applications. Lobby atmosphere edits
existing sky attributes; an independent instrument component replaces its current
configuration. Neither adds an answer archive, client-specific descriptor,
physics dependency, reaction handler or execution service.

The applications compose gui_instance.pl and declare gui_question_policy/3 for
their selected human and responder. The responder composes gui_question.pl;
the human composes gui_hud.pl. The examples own only their controls and domain
consequences. Selections can carry boolean and list values without additional
control kinds. Use composed groups already supported by both renderers.

Verify both through real signed schema/submission/completion owners, including
replacement of existing state, cleanup, stale schema and source rollback. The
test explicitly seeds accepted questions: original live opening is still a
separate unresolved contract, and these tests must not claim to validate it.
No wire, custody or recovery semantics change in this scope.
