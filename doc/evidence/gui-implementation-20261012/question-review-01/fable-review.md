# Fable review: shared question transitions (question-review-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: the frozen `tree/` (AGENTS.md identical to the component packet), the
`gui_instance.pl` and `quod_gui.pl` deltas against the last reviewed
renderer versions, and, read live and read-only, the call-chain shape handed
to `can_invoke/4` (`quod_ask.erl:1538-1570, 1700-1726`: the chain is the
caller namespaces with the immediate asker first, the target excluded; a
root proof's chain is its origin). No command, build or test was run; the
parent's gates are not claimed.

## 1. Verdict

The three transitions are authorized by committed rows and the authenticated
principal at every hop, re-validate against the source schema, change all
affected scopes in one transaction, and leave no framework residue. I found
no authority bypass. Two findings matter before the next slice: the
forged-chain tests never reach the overlay guards they are meant to prove
(T1), and a question that can no longer be completed has no authorized
retirement path (R1). The rest are notes.

## 2. Verified transition semantics

Q1. **Submit** (`gui_question.pl:54-66`). Entry requires an awaiting row for
the principal. The body binds the authenticated principal and the original
operation, matches the row with the client's revision so a stale revision
fails, validates in the source ontology under the human's own identity
through `gui_validate_submission/6`, which re-checks principal, policy and
`gui_bind/5` (`gui_instance.pl:189-193`), then replaces the row with
`submitted(Operation, Control, Fields)` and emits one occurrence. The source
scope has no diff, so it is a certified read; the responder is the single
writer.

Q2. **Complete** (`:75-81`, `gui_instance.pl:195-210`). Entry requires a
submitted row whose actor is the principal and whose namespace is the
responder's. `gui_continue/1` in the source re-enters the responder for
`gui_answer/6`, which again requires the row's actor as principal and the
exact `form_ref` of the asking source, re-binds the accepted fields against
the current schema, stages the `gui_application_active/1` guard, runs the
authored continuation, re-enters the responder for `gui_consume/1`, and
retracts the guard. `gui_consume/1` requires the submitted row, the actor,
the staged guard visible in the source scope, stages `gui_retiring/2`,
unlinks the HUD reference through the human's ontology, which calls back
into the responder's `gui_retirement/2`, and finally retracts the row and
the guard. Re-entry into the origin or an already open scope shares that
scope's staged overlay, so the guards are visible where they must be and the
whole thing is one atomic group over source, responder and human. The test
proves rollback when the continuation fails and when the enclosing
transaction fails after all three scopes changed.

Q3. **Cancel** (`:98-107`). Human-only on an awaiting row; same guard and
unlink path; two-scope atomic group.

Q4. **HUD** (`gui_hud.pl`). Discovery is restricted to the human of that
ontology and returns references only. Unlink requires the question's own
namespace as the immediate asker and an existing reference, then defers the
authority decision to the responder's `gui_retirement/2`, which needs the
staged guard plus the right principal for the row's state.

Q5. **Cleanup and recovery.** Both guards are asserted and retracted in the
same transaction and roll back with it. Completion emits no event and
creates no row; the only occurrence is `gui_submitted/2`, which is not a fact
(tested). No `react_on`, `agent_work_goal/5`, queue or counter is added, so
the FIPA opt-in to distinct attempts after unknown is not inherited; a second
`gui_complete/1` after a committed first fails on the absent row.

Q6. **Concurrency and staleness.** Two concurrent submits race on one
awaiting row through ordinary OCC; the test accepts exactly one committed
result. Submit after completion, cancel after submit, complete twice, and a
wrong revision all fail on the row's state.

## 3. Findings

### T1. The forged-chain tests stop at the source and responder ACLs, not at the guards (Medium, tests)

`fail(ActorCtx, scope(AppNs, scope(ResponderNs, {gui_consume, Q})))` fails
because the application admits the actor only for `gui_continue/1` and
`gui_application_active/1` (`gui_instance.pl:184-188`), so the outer
`A::(…, R::…)` goal is refused before the chain or the guard is consulted.
Likewise `scope(ResponderNs, scope(HumanNs, {gui_unlink, …}))` is refused by
the responder's entries, not by the missing `gui_retiring/2`. In production
the responsible actor will normally hold other grants in the application
(its own domain actions), which is exactly when the chain head is legitimate
and only the guard stands between a stray `R::gui_consume(Q)` and a consumed
question. Add a test ontology grant that lets the actor run an arbitrary goal
in the application, call `R::gui_consume(Q)` from it outside
`gui_continue/1`, and assert failure; do the same for `Human::gui_unlink`
from a responder goal outside the retirement path. Also assert after
completion and after cancel that no `gui_retiring/2` or
`gui_application_active/1` row survives.

### R1. A submitted question that cannot complete has no authorized retirement (Medium, contract)

`gui_complete/1` re-runs `gui_bind/5` against the current schema; a schema
change after submission, a continuation that keeps failing, or a withdrawn
policy row leaves the row `submitted` forever. `gui_cancel/1` needs
`awaiting`, and the actor has no cancel. The plan allows failure to stay
visible as unresolved work, but it also requires an authorized domain action
to resolve it. This slice has none. Name the entry now, even if implemented
later: a responder-side retirement that requires the submitted row and the
actor, retires through the same guard and unlink path, and records nothing
else.

### N1. Revision pinned at opening (Low)

The row carries the opening revision; a schema change strands an awaiting
question until the lifecycle slice provides re-ask. Consistent with the plan;
stated here so it is not mistaken for a submission bug.

### N2. Grants are as narrow as the rows allow (Low)

`gui_continue(_)` is admitted for any actor named in some policy row, but
`gui_answer/6` in the responder restricts the effect to that row's actor, so
the breadth is harmless. `gui_validate_submission/6` and
`gui_application_active/1` are pure reads for their principals. The
consumption entry keys on the chain head being the row's source namespace,
which the live chain shape supports.

### N3. Test gaps beyond T1 (Low)

A second human with its own policy row submitting another human's question;
a second responder listed in policy for a different form calling
`gui_continue/1` with this question's reference; a wrong source anchor in
`form_ref`.

## 4. Unverified

`quod_ask.erl` chain construction was read live, not frozen. All gate
results.
