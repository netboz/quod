# Fable review addendum 1: delta-01 and the prepared-effect opening candidate

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-12. Consultative only.
Supplements `fable-review.md`, which is left unchanged. Basis: the frozen
`tree/`, `delta-01/` (four files, diffed against `tree/`), and
`../opening-effect-candidate.md`. No command, build or test was run; the
parent's reported 112-test pass is not verified here and is not claimed.
Line numbers refer to `tree/` unless prefixed `delta-01/`.

## 1. Delta-01 against the original findings

Verified by diff:

- `gui_property_value(unit, …)` is now `(atom(Text) -> true ; gui_text(Text))`
  (`delta-01/priv/ontologies/quod_gui.pl:82`). This is the C1 fix. The
  parent's independent reproduction (atom unit, failing continuation) matches
  the mechanism described in C1.
- `term_variables(Control, [])`, ground `DirectClasses`, and `nonvar` checks on
  the field list and each field entry (`delta-01/priv/ontologies/gui_instance.pl:21,
  41-42, 72-79`) close variable-shaped declarations; the three new invalid-form
  cases in the test cover them.
- `max_length` is renamed `max_bytes` with UTF-8 byte tests
  (`delta-01/test/quod_gui_components_tests.erl:57-61`). The name now matches
  what `binary_codes/2` measures.
- The `gui_values` default-values assertion now reads `V1`.

Still open after delta-01 (unchanged from the original report):

- **C2**: `gui_value(text_box, …)` still calls `binary_codes/2` first, so a
  non-binary client value raises instead of failing.
- **C3**: no top-level `_:_` shape guard on `Form`, component ids, `Control`
  or submitted values, and no `no_follow/1` for the slice's own predicates.
- **C4**: `$quod_isa_*` internals and `member_eq/2` remain followable.
- **C5**: unknown attribute keys are still ignored, and
  `have_attribute(text_box, max_bytes, …)` (`delta-01/…/quod_gui.pl:41`) adds a
  fourth entry to the duplicate contract while `unit` and `layout` are still
  missing from it.
- **C6, C7, C8**: unchanged.

## 2. Verified facts about the direct-effect lane

E1. **Effects are per-scope plan material with an empty diff.** A staging
continuation stores `{Action, Desired, Effect, Prepared}` in the scope overlay
(`src/quod_erlog_db_local_prove.erl:276-296`); `validate_plan/2` admits one
effect per plan, executor equal to the plan signer, actor equal to the plan
principal, and `diff_ops =:= 0` (`src/quod_effect.erl:95-103`). A plan with an
effect counts as a writer (`src/quod_dtx.erl:473-474`), so an effect scope plus
one material scope forms an atomic group (`src/quod_prolog.erl:4626-4645`).
The candidate's premise that `seal_admissible/4` is per scope is correct
(`quod_dtx.erl:282-297`); nothing in sealing relates one scope's diff to
another scope's bridges.

E2. **Group effects bind before vote activation.** `finish_reserved_group/5`
reserves the source vote, binds every effect-bearing plan through its scope
session (`bind_group_effect_plans/2`, remote scopes included), then activates;
a bind error cancels the vote and the proof returns that error
(`quod_prolog.erl:5340-5363, 5366-5396`). On the executing node the journal
row is created `group_pending` only if the staged reservation, plan digest,
manifest and admission all match and the executor is that namespace's current
dtx signer (`src/quod_effect_journal.erl:664-725, 1618-1630`).

E3. **Validators and replay never execute effects.** Sealing and attestation
check only shape (`quod_dtx.erl:292, 952`); apply releases rows by height
(`src/quod_runtime.erl:1508-1512`); a node without the private row ignores the
committed descriptor (`quod_effect_journal.erl:993-997`). Group rows resolve
through applied projections and the origin outcome
(`quod_prolog.erl:785-830`).

E4. **Execution is serialized and lifecycle-shaped.** One released row runs at
a time, lowest height first (`quod_effect_journal.erl:1004-1020`).
`execute_row/1` proves the desired goal with `quod_prolog:prove_ro/2` in the
controlling namespace and then checks the hosted genesis anchor
(`:1022-1103`); `quod_ontology:prepared_bytes/1`, `decode_prepared/1` and
`execute_prepared/1` are lifecycle codecs (not in the tree). A `{retry, _}`
result leaves the row `released` and reschedules reconciliation with 1 s to
30 s backoff (`:520-529, 1749-1757`); the next `maybe_start/1` picks the same
lowest row again. `{error, _}` is terminal `operator_error` (`:1129-1144`).

E5. **Custody is policy-bounded and node-wide.** `reserve/1` and
`bind_*` consume root's `effect_custody_limits` count and prepared bytes
(`:303-317, 560-585`); `busy` refuses admission.

E6. **Result class on bind failure.** The group lane returns the bind error
as an error-class result (`quod_prolog.erl:5355-5363`). Only the control lane
maps a definite transient refusal to `{fail, [Reason]}`
(`quod_prolog.erl:4425-4436`).

E7. **Prepared values may flow into other scopes' diffs.** `provision_lobby/1`
binds `CreatedAnchor` from root's prepared creation and asserts it in the
human scope (`priv/ontologies/human_user_instance.pl:36-48`). For lifecycle
the prepared payload is deterministic data computed from committed policy; the
manager mutation happens only after apply.

## 3. Audit of the candidate

### 3.1 Consistency with validators, replay and custody: yes, mechanically

By E1 to E3 a closed `presentation` effect kind with an empty-diff plan in
the receiver node's ontology scope would seal, attest, vote, apply and resolve
exactly like a lifecycle effect, and foreign validators would neither execute
nor need to understand it. Group-pending rows retire on abort through the
existing resolution. This part of the candidate is sound.

### 3.2 Acceptance at proof time is a laundered live query (verified reasoning)

The candidate's step 4 obtains "actual authenticated receiver acceptance" and
"actual acceptance by the selected installed/authorized agent incarnation"
inside the proof, before sealing, and step 5 fails the original proof on
refusal. The veto's stated rationale is that a material diff "rests on
node-local, non-replayable state that no later validation can re-prove"
(`quod_dtx.erl:38-44`). With proof-time acceptance, the question row and HUD
reference commit if and only if a live owner said yes, so those diffs rest on
exactly that kind of state. The per-scope check does not see it only because
the live call was placed in a scope whose own diff is empty. That is the
situation the request calls laundering, and E7 is not a precedent for it:
lifecycle preparation is deterministic data from committed policy, not a live
yes/no from a process.

A query-class bridge invoked in the receiver scope would record a live bridge
there (`quod_erlog_db_local_prove.erl:628-634`), which the effect scope
tolerates (`{[], …}` branch), while the material scopes record nothing. So
the code would admit it; the architecture would not.

### 3.3 Acceptance at bind time is a legitimate admission gate

E2 shows a seam where the content is already sealed and acceptance cannot
influence it: the receiver node's scope session binding its effect before
vote activation. If the receiver view and the responder's hosting are checked
there, a refusal cancels the vote, nothing durable is produced, and the
sealed question/HUD diffs are provably independent of the answer. That is the
same class of gate as `effect_admission/2` returning `not_in_charge`
(`quod_effect_journal.erl:1618-1630`) or `busy`. This satisfies "no connected
human or capable agent means no shared rows" without a live dependency in any
material scope, and "acceptance promises no continued connectivity" holds
because the group proceeds on its own after activation.

Two consequences follow and both are verified gaps:

1. **Result class.** A bind-time refusal is an error today (E6). The settled
   requirement is Prolog failure. The group lane needs the same
   definite-refusal to `{fail, [Reason]}` mapping the control lane already has,
   restricted to refusals reported before activation (after activation the
   outcome is pending or unknown, never fail).
2. **Agent acceptance API.** `agent_request/6` is accepted only from the
   runtime's event runner (`src/quod_runtime.erl:376-391`); there is no
   runtime query for "is responder X hosted at epoch E with key K and has work
   capacity" usable from a scope session. It must be a read of the runtime's
   current hosting and capacity, with capacity thresholds owned by Prolog
   policy, not a queue admission.

### 3.4 After commit the effect has nothing to execute (verified hazard)

The candidate's step 9 executes the effect as "update/notify the view owner
by Question identity". Every durable truth already exists in the ontologies at
that point, and the view owner can observe the committed change through the
existing installed-state notifications and an ordinary HUD read. The journal
run therefore has no external state to establish. Two concrete problems:

- **Head-of-line blocking.** If the presentation handler returns
  `{retry, _}` for a disconnected receiver, the row stays `released` and
  `maybe_start/1` selects it again first by height (E4), stalling every later
  lifecycle effect on that node until the receiver returns or the row is
  retired. A presentation handler must be terminal on first run: `ok` whether
  or not a receiver is connected. Once that is true, the execution is a pure
  no-op with an optional local notification.
- **Lifecycle-specific postcondition.** `execute_row/1` requires a desired-state
  goal provable by `prove_ro/2` in the controlling namespace and a hosted
  genesis anchor (E4). The candidate already lists the handler-dispatch
  refactor; the postcondition for presentation would have to be trivially
  true, which again shows the row carries no obligation.

Net: the candidate uses the effect journal as the carrier for a pre-activation
acceptance gate. The gate itself (3.3) is the valuable part; the journal row,
custody count (E5), serialized execution and reconciliation it brings are cost
without a corresponding recovery need.

### 3.5 Death and loss boundaries under the candidate

| Boundary | Durable state | Original caller result |
| --- | --- | --- |
| Refusal at bind, before activation | none; reserved vote cancelled | should be `fail` with reason; today error (3.3.1) |
| Proof worker dies after bind, before activation | `group_pending` rows on receiver node; dormant vote | caller unknown; rows retire only when `effect_resolution/4` sees an abort or the origin reports `aborted` (`quod_prolog.erl:826-830`). Whether a reserved-but-never-activated vote ever yields that is **unverified** here; the exposure exists for lifecycle today and GUI would make it frequent |
| Activated, reply lost | group pending/committed | `{outcome_unknown, Ref}` resolved from the exact signed bytes: browser journal for human-signed R; for agent-signed R only if the custodied mode is used, since `start_request/5` retains no bytes (`src/quod_agent.erl:95-131`) |
| Committed, receiver gone | question + HUD ref | success already returned; effect runs as no-op; HUD discovers |
| Group aborted by another role | none | caller gets the certified abort; rows retire via resolution |

The agent-signed case deserves a sentence in the plan: without custodied
submission, an agent-originated opening whose reply is lost is resolvable only
by domain idempotency on the question rows, not by operation evidence.

### 3.6 Receiver scope and routing

Routing to the receiver node is the ordinary anchored `::` into that node's
ontology, as `request_ontology_hosting/5` does (`human_user_instance.pl:45-47`);
no broker is needed. What does not exist is any committed fact naming where a
human is connected. The selected scope must come from policy over committed
state (for example the node hosting the human's ontology), and a connection
elsewhere is then an authoritative "absent on the selected scope", which the
plan allows. The view owner must register its verified identity and
incarnation locally so the scope session can find it; `quod_client_simulation`
registers nothing today (`src/quod_client_simulation.erl:69-93`).

## 4. Recommendation

- Keep the single original signed execute and the atomic group with question
  row and HUD reference. Do not put acceptance in the proof.
- If the effect lane is used, specify it as: effect payload prepared from
  committed data only; acceptance performed by the receiver node's scope
  session immediately before `bind_group`, with the caller's remaining
  deadline; definite refusal mapped to Prolog failure before activation;
  handler execution terminal on first run and never `{retry, _}`; no
  acceptance-derived value in any diff.
- Weigh that against a pre-activation acceptance hook in the group lane
  without a journal row. It is new machinery, but it avoids custody
  consumption, serialized execution and reconciliation for an obligation that
  does not exist. Yan's call; both are extensions of the same owner.
- Either way, name the three APIs: receiver registration keyed by human and
  incarnation; a runtime hosting/capacity read usable from a scope session;
  and the replayable operation-reference accessor for question identity.

## 5. Unverified by this addendum

- `quod_atomic:requires_source_role/2`, `quod_scope_session` binding code,
  `quod_dtx_coordinator` vote reservation and cancellation, and
  `quod_ontology` prepared-effect codecs are outside the tree.
- Whether `effect_origin_resolution/1` retires rows for a vote that was
  reserved and never activated.
- The parent's 112-test run and the delta's test outcomes.
