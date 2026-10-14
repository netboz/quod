# Shared question transitions: bounded implementation scope

Read AGENTS.md. Review the frozen tree and manifest. No commands, tests or
production edits. Save fable-review.md here. Requested independent implementation
review of ordinary signed ontology submission, cancellation and completion.

The gui_instance schema/bind foundation is already reviewed; its only new block
is gui_question_policy entry grants, gui_validate_submission and gui_continue.
New gui_question.pl stores one awaiting/submitted row, reads authenticated
principal and original operation, validates fields in the source ontology, emits
an event, and supports atomic completion/cancel. gui_hud.pl stores references
only and returns authenticated discovery. Ephemeral ordinary overlay guards
protect helper consumption/unlink against forged call chains: they must be staged
within the actual continuation/retirement proof, are retracted before success,
and roll back on failure. Check authority, reentry, cleanup and wrapper grants.

No gui_open, live receiver acceptance or automatic agent_work_goal/react_on
installation is in this slice. Accepted rows are EXPLICIT TEST FIXTURES, not a
substitute for live acceptance. gui_complete is the canonical signed completion
entry; automatic invocation must await an exact-uncertainty contract through the
existing agent-work owner. Existing FIPA opts into distinct attempts after unknown
outcomes in fipa_request.pl; GUI must not inherit that policy. No private queue,
engine, pending-state mirror or retry loop is added.

Current gate05 passed the complete signed transition sequence and rollback after
all three scopes changed. Gate06 adds narrow helper/refusal checks, HUD discovery,
question class reflection and concurrent submissions, plus component regression.
Gate04 failed only the test's final binding-name assertion (anonymous variables
shifted V0 to V4); changed the count query to exact accepted values. Full logs
retained. Do not claim these parent gates as reviewer executions.
