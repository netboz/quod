# Fable review addendum 3: native preparation, Prolog failure, and the provisional-view effect

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-12. Consultative only.
Earlier reports are unchanged. Added inputs for this addendum, read live at
the parent's request: `src/quod_ontology.erl` (944 lines) and
`src/predicates/quod_ontology_predicates.erl` (309 lines). The parent will
freeze them. All other citations are to `tree/`. No command, build or test
was run.

## 1. Correction 1: lifecycle preparation is native, not deterministic data

Addendum 1 (E7 and section 3.2) said lifecycle preparation is "deterministic
data computed from committed policy" and that the manager mutation is the
only native step. That is wrong. Verified in the live sources:

N1. `prepare_create/3` reads the node's root storage from application
environment (`quod_ontology.erl:467-470, 904-916`), builds the namespace
config, opens the local ledger store read-only to learn whether a ledger
exists and which anchor it carries (`existing_ledger/2`, `:918-944`), and
either resumes with the persisted anchor or calls
`quod_simplex:prepare_genesis/3` for fresh bytes (`:480-506`).
`prepare_join/3` does the same ledger read and refuses `genesis_mismatch` on
native state (`:519-553`).

N2. `prepare_and_stage_action/6` maps operational preparation errors to
reasoned Prolog failure inside the proof (`quod_ontology_predicates.erl:124-137,
214-232`): `already_hosted`, `root_unavailable`, `start_failed`,
`genesis_mismatch` via `start_failed`. Argument and descriptor errors use the
error channel. Alternatives, cuts and candidate rollback therefore work
around a refused preparation, and the archived ruling confirms savepoints
cover prepared effects (`doc/outdated/multiwrite-architecture.md:296-301`).

N3. The prepared anchor is bound into the caller's variable before staging
(`quod_ontology_predicates.erl:139-151`), and `provision_lobby/1` commits it in
the human scope's diff (`priv/ontologies/human_user_instance.pl:41-44`). A
value derived from native state does enter another scope's material diff
today, by design.

N4. The executor is the scope's own signer (`:170-173`), the private payload
is the exact config and prepared genesis entry (`quod_ontology.erl:636-642`),
and the public descriptor commits to the action and payload digests
(`:614-632`). Execution later re-reads nothing from the caller and verifies
its desired state and target anchor (`tree/src/quod_effect_journal.erl:1022-1103`).

Consequence: the conclusion in addendum 1 section 3.2, that proof-time
acceptance is a laundered live query *because* it differs from lifecycle
preparation, is withdrawn. The existing owner already performs non-replayable
native checks inside a proof whose refusal fails the proof and whose result
gates and feeds material diffs in other scopes. The per-scope veto was never
the thing distinguishing that from a live query, and I should not have leaned
on it.

## 2. What distinguishes native preparation from a live query (from code)

Derived from N1 to N4 and from the veto text (`tree/src/quod_dtx.erl:33-44`):

- **P1. The native reads produce the effect's own private payload**, retained
  immutably and committed by digest in the public descriptor. They are not
  asserted or returned as facts about the world.
- **P2. The only proof-visible outputs are success, a reasoned refusal that
  means "this executor cannot perform the effect", and the effect's own target
  identity.** Lifecycle returns the anchor the effect will produce or resume,
  nothing else.
- **P3. The executor is the scope signer on the node that will execute**, and
  `effect_admission/2` re-checks that at bind (`quod_effect_journal.erl:1618-1630`).
- **P4. Execution is idempotent by desired state and re-verifies the target**;
  a value committed from preparation is checked again at execution
  (`desired_target_state/1`), so a stale preparation becomes a terminal
  operator error, never silently wrong content.
- **P5. Validators and replay need only the descriptor shape**; nodes without
  the private row ignore the committed descriptor.
- **P6. Rollback discards the staged effect with the candidate savepoint**,
  and the preparation leaves no durable trace until bind.

A live query, by contrast, returns a world observation that the proof turns
into content or into a branch whose committed facts claim that observation
was true, with nothing re-verifying it at execution. `peer_ready/1`, physics
samples and an unavailable operation outcome are that shape, which is why the
veto records them.

## 3. Correction 2: bind-time acceptance is not settled Prolog failure

Addendum 1 section 3.3 preferred acceptance in the receiver node's scope
session before `bind_group`. The parent is right that this cannot satisfy the
settled requirement. `finish_reserved_group/5` runs after the proof worker has
sealed its selected solution (`tree/src/quod_prolog.erl:5340-5363`); the
proof's choice points are gone. A refusal there can only be an API-level
outcome. It cannot make `(gui_open(F, Q) -> A ; B)` take `B`, cannot be
handled by `transaction/1` or an action candidate, and cannot be a
`fail_with_reason/1` the application branches on. Mapping it to `{fail, _}`
would be a relabelled error. That preference is withdrawn.

The only seam in the existing owner where a refusal is Prolog failure is
proof-time preparation (N2). The two corrections therefore point the same
way: acceptance belongs in the staging continuation of a declared action, as
`'$quod_stage_ontology'/3` is for lifecycle, and must look like preparation
under P1 to P6, not like a query.

## 4. Audit of the provisional-view presentation effect

The candidate as refined: client acceptance of the exact descriptor allocates
a provisional view, hidden before commit; the effect's private payload names
that exact view incarnation; ordered release activates it; release is
idempotent by `Q`; a gone incarnation is terminal `expired`, never a wait;
later presentation is owned by ontology HUD discovery. Against section 2:

- **P1 holds.** The incarnation reference, descriptor, revision and `Q` are
  an immutable private payload; the public descriptor carries
  `present(Q, FormRef, Revision)` and the digests. Nothing from the acceptance
  needs to be, or may be, a fact.
- **P2 holds if the continuation returns nothing but success or refusal.**
  `Q` comes from the original request identity, not from the acceptance.
  Refusals (`no_receiver`, `unsupported_descriptor`, `receiver_refused`,
  `receiver_unavailable`) are executor-side infeasibility in exactly the sense
  of `already_hosted` or `root_unavailable`, and must use `fail_reason/2`,
  with `receiver_unavailable` distinguished from absence as the plan requires.
  Any acceptance-derived value (incarnation id, time) entering a diff would
  break P2 and must be rejected by review.
- **P3 holds** when the staging continuation runs in the receiver node's
  ontology scope, reached by anchored `::` as `request_ontology_hosting/5` is
  today (`human_user_instance.pl:45-47`), with that scope's signer as executor.
- **P4 holds with two definitions.** Desired state is "view incarnation `I`
  for `Q` is active or expired". Execution checks the exact incarnation:
  present, activate; gone, terminal `expired`. Both are `applied` for the
  journal; neither is `{retry, _}`. This is where it departs from lifecycle,
  where `absent` after execution is `postcondition_failed`. The closed handler
  dispatch the candidate already lists must encode that difference; the
  current `execute_row/1` cannot express it (`quod_effect_journal.erl:1022-1103`).
- **P5 holds** unchanged.
- **P6 holds on the node side**; on the client side the provisional view is
  state the browser holds without a journal row. It must expire on its own at
  the original request's `not_after_ms` unless activated, because a refused
  or aborted group never executes the row and nothing else will tell the
  browser. A late activation after that expiry is the `expired` branch.

Two differences from lifecycle preparation that must be stated, not hidden:

- **D1. Preparation round-trips to a remote party.** Lifecycle reads local
  files and environment; this acceptance crosses the WebSocket to the browser
  and back inside the proof's deadline. Proofs already do network I/O for
  `::`, and the worker is not a state owner, so the architecture permits it,
  but the view owner must answer within the caller's remaining budget and a
  lost reply is a refusal (`receiver_unavailable`), never a wait.
- **D2. Feasibility is transient.** A ledger directory stays; a connection
  does not. Hence P4's `expired` branch and P6's client-side expiry. The
  settled text already accepts this: acceptance promises no later
  connectivity.

**Agent acceptance does not fit this effect.** The responsible agent's
capability concerns the responder ontology, whose scope carries the question
row, a material diff. A live hosting or capacity read there is a query-class
bridge in a material scope and is vetoed on its own terms, correctly. The
receiver-node effect cannot carry it either, since it is not that effect's
feasibility. What satisfies "no capable authorized responsible agent means
failure" without a live read is committed state: `agent_hosted/4`, active
key, installed shared behaviour and the responder's policy grant, all proven
in the responder scope by ordinary Prolog. Live queue capacity is then a
property of the later submission and work selection, not of opening. If Yan
requires live capacity at opening, that is a new requirement on the veto and
should be decided explicitly, not implied.

**Verdict.** With P2's no-return discipline, P4's terminal `expired`, P6's
client-side expiry and committed-fact agent capability, the provisional-view
effect is a legitimate prepared external action under the standing
direct-effect contract, on the same footing as `join_ontology`. It is not a
redundant notification: it activates one exact hidden incarnation and
nothing else, and it holds no second inventory, queue or completion table.

## 5. Contracts the existing owners must gain (concrete, not yet existing)

1. **Staging continuation for presentation** in the receiver node's ontology,
   registered as a staging predicate like `'$quod_stage_ontology'/3`
   (`quod_ontology_predicates.erl:44-57, 100-185`), entered only through
   `run_declared_action/2` with the opaque handle, returning only success or
   `fail_reason/2`, staging with `put_prepared_effect/5`.
2. **Receiver registration and acceptance call.** The authenticated view owner
   registers `{client_view, Human, Incarnation}` after its verified signed
   open; the continuation finds it by committed receiver-scope policy, sends
   the exact descriptor and revision, and awaits accept, refuse or timeout
   within the remaining proof budget. The browser allocates the hidden
   provisional view keyed by `Q` with expiry `not_after_ms`.
3. **Closed effect kind `present`** in `quod_effect` with executor and actor
   checks unchanged, and the handler dispatch extraction in the journal so
   `execute_row/1` can return `applied` for both activation and `expired`.
4. **Replayable operation-reference accessor** so `Q` is the original signed
   operation identity (plan section 6).
5. **Agent capability as committed facts** in the responder scope, with the
   policy predicate named in shared behaviour.

## 6. Boundaries under this shape

| Boundary | State | Original caller |
| --- | --- | --- |
| No receiver on selected scope, unsupported descriptor, receiver refuses | nothing staged beyond the candidate savepoint | Prolog failure with reason; alternatives run |
| Receiver reply lost or over budget during preparation | provisional view may exist in the browser, expires at `not_after_ms` | Prolog failure `receiver_unavailable`, distinct from absence |
| Proof dies after preparation, before seal | same | nothing signed resolves; browser view expires |
| Sealed and bound, worker dies before activation | `group_pending` rows on receiver node | unknown; rows retire when resolution sees abort, same exposure as lifecycle (`quod_prolog.erl:826-830`, unverified for a never-activated vote) |
| Group aborted | rows retired, no execution | certified abort; browser view expires |
| Committed, incarnation present | row executes, view activated | certified success already returned |
| Committed, incarnation gone | row terminal `expired` | success; HUD discovery presents later |
| Committed, reply to caller lost | as above | unknown with original operation identity; browser journal, or agent custodied mode, resolves it |

## 7. Unresolved

- Whether `quod_simplex:prepare_genesis/3` performs any step beyond local
  reads (not read here).
- Whether live agent capacity is required at opening (section 4).
- Whether a never-activated reserved vote always resolves its
  `group_pending` rows.
- All test outcomes.
