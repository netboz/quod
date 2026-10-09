# Failure reasons versus errors: design decisions

Authored by Claude Fable at Yan's request (2026-10-09) after review 02 of the
hot-controls commit. Consultative; the implementation owner checks each
decision against the code. The normative text in section 2 is meant to be
merged into `doc/proofs.md`; this file is the handoff, not the home.

## 1. What already exists and is kept

- The forked erlog carries a bounded `fail_reasons` stack on the proof state.
  `fail_with_reason(Reason)` records one ground, portable, wire-valid term and
  fails. `get_fail_reasons/1` reads the stack. Both are installed for every
  engine (`quod_resource_basis.erl:67`).
- `quod_client_result` renders the stack as `result: fail` with `reasons`.
  A plain failure renders as `result: fail` without reasons.
- A thrown `erlog_error` is a different result class. Its reason is never
  forwarded verbatim: `quod_client_result:valid_public_error/1` is a fixed
  allowlist of atoms and `quod_scope_wire:normalize_public_error/2` turns
  anything else into `{protocol_error, proof_engine}`.
- `quod_predicates` already specifies two classes for external predicates:
  no managed context fails plainly; wrong predicate class for the proof kind
  throws `{context_violation, Functor, Class, Kind}`.
- `quod_prolog.pl` already uses `fail_with_reason(edit_conflict(I))`,
  `duplicate_clause(I)` and `edit_not_representable(I)`.
  `quod_ontology_predicates:fail_reason/2` is the only Erlang helper.

Nothing new is introduced. The decisions below only say when each existing
channel is the right one, and make the helper shared.

## 2. Normative contract

Merged into [the proof contract](../../proofs.md#failure-reasoned-failure-and-error).
The implementation distinguishes uncertain transient release exits from definite
owner refusals: the former remain errors and must not be resubmitted.

## 3. Shared helper

Move `fail_reason/2` from `quod_ontology_predicates` to `quod_predicates`
and export it. Keep the one-line body
(`erlog_int:prove_body([{fail_with_reason, Reason}], St)`). Delete the
private copy. No second helper for errors: call `erlog_int:instantiation_error/1`,
`type_error/3`, `domain_error/3` and `erlog_error/2` directly.

## 4. Classification of the hot-controls sites

`src/predicates/quod_physics_predicates.erl`, line numbers from commit
61ce04b.

| Line | Condition | Class | Term |
|---|---|---|---|
| 47, 104 | action not ground | error | `instantiation_error` |
| 49 | body id not a non-negative integer | error | `type_error(body_id, B)` |
| 49 | proof not read-only | error | `{context_violation, physics_body_state_or_motion_query, query, write_proof}` |
| 49, 104 | scope identity unavailable | reasoned | `{scope_identity_unavailable, W}` |
| 70 | frame from policy has another identity or wrong shape | error | `domain_error(physics_frame, Frame)` |
| 70 | registered handle does not match | error | `domain_error(physics_request_handle, Handle)` |
| 66 to 67, 78, 84 | no installed owner for the world | reasoned | `{physics_world_unavailable, W}` |
| 66 to 67 | owner call exited or timed out | reasoned | `{physics_owner_unavailable, W}` |
| 78, 84 | owner answered `unavailable` for this body or frame | keep as the bound answer `unavailable`, documented | |
| 125 | second transient in one proof | reasoned | `transient_already_staged` |
| 125 | request mode is not control, proof not read-only, write intent not ordinary | error | `{context_violation, physics_control_input, staging, Mode}` |
| 125 | effect fails `valid_transient` | error | `domain_error(transient_effect, Effect)` |
| 127 | no installed owner for the world | reasoned | `{physics_world_unavailable, W}` |
| 127 | signed request expiry absent | error | `{context_violation, physics_control_input, staging, unsigned}` |
| 129 | lease from policy not a positive integer | error | `domain_error(physics_lease, Lease)` |
| 129 | handle or action mismatch | error | `domain_error(physics_request_handle, Handle)` |
| 141, 151 | signature or binding does not match | no solution | |
| 157 | no reaction metadata | no solution, documented no-context case | |

`src/quod_physics.erl`, `handle_current_call({physics_input, ...})` returns
one `{error, transient_unavailable}` for seven conditions. Replace with one
reply per condition, in this check order:

| Condition | Reply |
|---|---|
| projection fence, structure or incarnation changed | `{error, {stale_projection, Structure}}` |
| control not installed or push allowance not installed | `{error, control_not_installed}` |
| registration does not match the current viewer | `{error, stale_registration}` |
| sequence not above the retained one | `{error, {stale_sequence, Retained}}` |
| a discrete input is still pending | `{error, discrete_pending}` |
| lease or request already expired | `{error, expired}` |
| deadline already passed | `{error, expired}` |
| navigation guard not current | `{error, reinstalling}` |

`quod_effect:release_transient/2` forwards definite owner refusals unchanged;
`quod_prolog:finalize_request_result/3` turns them into `{fail,[Reason]}`.
An owner exit or timeout may follow admission. The effect boundary returns
`{unknown,owner_unavailable}` and finalization preserves the error class,
suspending the client without resubmission. This corrects the original
handoff's proposal to treat all caught exits as certain refusals.

`priv/ontologies/quod_physics.pl`, conflicts that are currently plain
failures and must become reasoned:

| Predicate | Condition | Term |
|---|---|---|
| `physics_control_agent/4` | expected epoch or selection stale | `{control_conflict, Epoch}` |
| `physics_control_choice/3` | agent controlled by another principal | `{agent_controlled, Agent}` |
| `physics_agent_configuration/5` | zero or several definitions, viewpoints or bodies | `{ambiguous_agent, Agent}` |
| `physics_checkpoint_body/5` | state already `waiting` | `{checkpoint_pending, D}` |
| `physics_checkpoint_body/5` | custody not replaceable | `{checkpoint_custody_held, D}` |
| `physics_checkpoint_body/5` | no `physics_rest_policy` | `{rest_policy_missing, D}` |
| `physics_checkpoint_body/5` | body not free or revision stale | `{body_not_free, D}` |
| `physics_input_projection/8` | no control configuration for the principal | `{no_control, W}` |
| `physics_motion_read_projection/6` | no query allowances | `{query_allowances_missing, W}` |
| any | `physics_allowances/5` absent | `{allowances_missing, W}` |

Pure permission checks (`can_*`) stay plain failures.

`client/src/simulation.js`, `command()`: branch on `reply.result`.
`ok` returns true. `fail` keeps `current`, passes `reply.reasons` to the
feedback callback and returns false without calling `failed()`. Anything
else, including a thrown error, calls `failed()` as today.

## 5. Audit beyond this commit

Every `erlog_int:fail(St)` under `src/predicates` is classified into the
three classes with the same table format, one row per condition, before any
edit. Known counts at 61ce04b: ten in ask, transaction and agent predicates,
about twelve in `quod_runtime_predicates`, including missing reaction
metadata and operation outcome lookups. Rows in class 1 need no change. The
audit table is the review artefact; the diff must match it.

## 6. Tests

- One test per reasoned failure row above asserts the exact reason through
  the production seam (`quod_client_goal_ingress:submit/2`), reading
  `reasons` from the normalized result, not from the log.
- One test per error row asserts the error class at the seam.
- The owner-side table is covered through `gen_server:call` on the world in
  `quod_physics_tests`, one assertion per reply.
- `client/test/simulation.test.js` gains the three-way branch: `ok`, `fail`
  with reasons keeping the view, error suspending.
- The same-namespace signed control test already planned by the parent
  belongs in this round.

## 7. Out of scope

Changing the public error allowlist, renaming existing reasons in
`quod_prolog.pl`, and any client wording. The reasoned-failure channel is
expressive enough that the allowlist does not need to grow.
