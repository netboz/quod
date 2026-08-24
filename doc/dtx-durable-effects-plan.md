# Durable effects in multi-ontology transactions

**Status:** implemented in the current working tree; not committed or deployed.
Protocol, custody, recovery, signed-agent lifecycle, browser, and distributed
tests are green. Full EUnit is green at 1,326 tests; the complete distributed
ask suite is green at 15 tests; compile, xref, Dialyzer, client/UI builds, and
diff-check are green. Independent review is complete; the coordinated clean
re-found remains pending.

The former group-wide `effect_requires_single_participant` rejection is gone.
The separate rule forbidding a D diff and direct effect in the **same plan**
remains as `effect_requires_empty_diff`.

This plan extends the existing DTX protocol and the existing node-wide effect
journal. It does not add a creation protocol, another ACL, another effect
runner, or another durable state owner.

## 1. Goal

A signed goal begins in the ontology containing the acting agent. If that goal
changes another ontology, the agent ontology remains the DTX origin so it can
durably claim the operation and resolve a lost response.

This must work when a participant stages one of Quod's existing typed durable
effects. The immediate example is:

```text
agent ontology A
  -> quod:root::create_ontology(...)
  -> A records the signed operation claim in DTX Begin
  -> Root validates its normal ACL and action prerequisites
  -> Root's participant plan contains the create effect
  -> the existing local effect journal executes it after Root Finalize(commit)
```

Root owns only `create_ontology/2`. A different effect-bearing predicate stays
in the ontology that defines it and follows the same mechanism.

The design must also support a normal group containing several data/OCC
participants and one or more effect-bearing participants. It must not be tied
to ontology creation.

## 2. Fixed architecture

The following are not open to implementation shortcuts:

1. **One proof and ACL path.** Each target's existing `can_invoke/4` and action
   prerequisites authorize its plan. DTX effect support adds no policy check.
2. **One DTX path.** Begin, Prepare, Decision, Finalize, Complete, their current
   coordinator, and their current recovery driver remain the distributed
   commit protocol.
3. **One effect-custody owner.** `quod_effect_journal` retains the private
   prepared bytes and executes the effect. No participant-specific journal or
   lifecycle queue is added.
4. **One ordered P-before-E path.** A committed participant Finalize enters the
   same `quod_runtime` queue used by ordinary effect-bearing transactions.
   Runtime completes P before it releases E to the journal.
5. **One deterministic target validator.** The existing sealed plan,
   attestation, Prepare validation, committed reducer, and replay path validate
   the effect. No second validator or apply reducer is added.
6. **No external operation during proof, Prepare, Decision, or consensus.** The
   proof only stages a closed descriptor and private prepared bytes.
7. **No private bytes in a ledger.** Plans and transactions contain the public
   descriptor and its digest. The node-wide journal alone retains source,
   filesystem, seed, or manager preparation.
8. **No hidden population limit.** This work adds no new count cap. It retains
   the already-reviewed protocol rule of at most one direct effect per plan,
   the existing DTX participant bound, and the root-configured effect-journal
   capacity, which may be `unlimited`.

## 3. What commits, and what it proves

### 3.1 Public durable truth

The effect remains inside its target-owned sealed plan. The existing plan
digest binds it into:

- the manifest participant row;
- the target attestation;
- Begin and Prepare;
- the participant's certified Finalize history; and
- the final Complete chain.

No new effect receipt is added to Begin, Finalize, or Complete. The existing
plan and its digest already provide that binding.

A target committee verifies the same things it verifies for an ordinary
effect-bearing transaction:

- the plan belongs to this exact `{Namespace, GenesisAnchor}`;
- the plan signer is admitted at the frozen parent;
- its target authorization transcript is valid;
- its OCC dependencies and material are valid;
- the effect descriptor is canonical and known;
- `Executor` equals the plan signer; and
- `Actor` equals the plan principal.

Move the current `valid_direct_plan_effects/2` rules out of `quod_prolog` into
one pure target-owned `quod_effect:validate_plan(Plan, Material)` seam (name
illustrative), then extend them for DTX. Ordinary plan submission, target
attestation, Prepare voting, and committed Finalize replay all call that one
function. These checks are not duplicated today; the refactor prevents four
copies from appearing as the previously forbidden paths become reachable.
The outer manifest matcher remains atom-safe and checks only signed counts,
identity, and digests; it must not decode a foreign ontology's material merely
to repeat target-owned checks.

### 3.2 Local external truth

The private prepared payload and the eventual external result are node-local.
Other validators cannot prove that a directory was created, a process started,
or a remote manager call succeeded.

Therefore:

- `Finalize(commit)` proves that the participant's durable plan was published;
- after ordered P reaches that Finalize, the executor's journal may perform E;
- `Complete` proves that every participant applied its matching Finalize; and
- `Complete` does **not** claim that every node-local E operation succeeded.

An operator error cannot roll back a decision that is already committed. It is
recorded in the existing local effect journal and shown as local status.

The ordinary single-ontology in-process API may keep its current stronger
convenience of waiting for its local journal result. A distributed caller
returns the certified group outcome. This is an authority boundary, not a
second executor: a remote local-IO result is not consensus truth and must not
be copied into Complete.

## 4. Exact effect release point

For an effect-bearing participant:

```text
sealed plan
  -> private journal custody established
  -> Begin accepted at the origin
  -> Prepare locks the participant plan
  -> Decision(commit)
  -> Finalize(commit) publishes the plan once
  -> target projection and MVCC snapshot are flushed
  -> existing runtime P tier processes that Finalize height
  -> existing effect journal is released
  -> idempotent E execution and desired-state verification
```

The release point is participant `Finalize(commit)`, not origin `Complete`:

- the certified commit Decision is already irreversible;
- Finalize is the existing point at which the target publishes its hidden
  plan;
- the target already has an exact ordered P-before-E barrier there; and
- waiting for Complete would require a new reverse notification from the
  origin to every target.

`Finalize(abort)` discards the hidden plan and retires its exact local journal
row. It never executes E. A direct no-Prepare abort has no plan and no effect
row.

## 5. Private custody before Begin

### 5.1 Why custody must move first

The private prepared bytes live in the target proof session. That session ends
after the group hand-off. Begin must not become durable unless every
effect-bearing target has first datasync'd the private preparation needed to
honour a later commit.

The group hand-off therefore reuses the existing dormant Begin intent as the
authority boundary for one generic custody step. Registering that intent in
Simplex is volatile, owner-monitored, not signed, not journaled, and not
eligible for proposal. It makes the exact `GroupRef` report `pending` through
the existing origin barrier without making Begin durable.

The exact order is:

1. seal every participant plan as today;
2. build one manifest and collect the existing target attestations;
3. build the exact Begin and derive its stable `GroupRef`;
4. register that Begin as the origin's existing dormant `dtx_intent`;
5. for every plan whose signed `effects_count` is one, ask that same sealed
   scope to persist its prepared effect directly as `group_pending` in
   `quod_effect_journal`; issue these bounded requests concurrently under the
   proof's existing absolute deadline;
6. only after every durable binding succeeds, checkpoint the exact `GroupRef`
   and activate the existing Begin intent; and
7. close participant scopes normally.

If any binding fails before step 6, the origin cancels its dormant intent. No
Begin was signed or registered in the signing journal. Already-bound target
rows observe definitive `not_found` through their normal reconciliation and
retire; a late concurrent binding observes the same absence and also retires.
A lost cleanup message cannot strand or execute one.

The dormant intent removes the ambiguous interval from the earlier design.
A group journal row has its exact recovery reference and an authoritative
pending origin before it is persisted, so it needs no later activation state
or activation request. A crash after step 6 is ordinary uncertain group work:
the caller keeps the same `GroupRef`, the coordinator continues, and journal
reconciliation follows the certified outcome. It must never return a result
that invites the client to submit a new goal.

Step 5 uses the existing `quod_scope_session` abstraction for local,
co-hosted, and remote scopes. The remote form adds one exact operation to the
one scope-wire command/event grammar, conceptually:

```text
bind_group_effects(GroupRef, PlanDigest)     -> group_effects_bound
```

The target scope already owns the sealed plan and proof-local prepared row;
the request carries neither private payload nor another executable goal.
Correlation, sequencing, authentication, deadline, and teardown are the
existing scope-session rules.

### 5.2 Stable private reference

The journal's current transaction-only `ref` becomes one closed commit
reference type:

```erlang
{transaction, Namespace, Anchor, TxId}

{group_effect, 1, GroupRef, TargetIdentity, PlanDigest}
```

`group_effect` is private journal metadata, not a ledger record or network
protocol. `TargetIdentity` and `PlanDigest` make a row unambiguous when the
origin is also a participant or when several participants contain effects.

The group row stores the exact sealed plan bytes instead of inventing an
ordinary `#transaction{}` that never commits. Its public descriptor still
binds the private action and prepared payload digests exactly as today.

### 5.3 Lost replies and owner death

Binding is idempotent. A reply lost after journal persistence is handled by
repeating the same request with the same reference. The row is already
`group_pending`; there is no second state transition to lose.

If a target scope owner dies, the journal must not discard the group row and
must not assume that Begin committed. It resolves the exact `GroupRef` through
the existing group outcome/barrier path:

- dormant intent, pending Begin, certified Begin, or later group history:
  retain;
- committed Finalize(commit): release after the target P frontier;
- committed Finalize(abort) or terminal abort: retire;
- definitive pre-Begin `not_found` or `coordinator_retired`: retire; and
- unavailable or rebuilding: retain and retry.

This closes the crash between origin Begin activation and a lost custody
reply without another timer, store, or coordinator.

The existing `retire_bound_owner_monitor/2` is still an explicit audit seam.
It remains the ordinary transaction rule only: an unactivated transaction can
never commit. A group row never enters `bound_owners`, so an owner `DOWN`
cannot route it through `not_activated` retirement. Tests must pin that type
separation rather than add a group-specific exception inside the function.

The dormant origin intent owns pre-Begin liveness. If its proof worker dies or
its deadline expires, Simplex's existing monitor cancels the intent; target
rows then obtain definitive `not_found` and retire. If Begin was activated,
the origin signing journal/submission or certified history remains pending and
the row stays. On journal restart every persisted `group_pending` row enters
the same barrier-driven reconciliation immediately.

## 6. Journal refactor, not a second journal

`quod_effect_journal` keeps its one row map, capacity projection, snapshot,
execution worker, desired-state check, waiters, and retry loop. Refactor only
the commit-specific parts:

- replace transaction-only `transaction`/`ref` assumptions with one typed
  commit binding;
- let a bound row carry either exact transaction bytes or exact plan bytes;
- retain the existing ordinary hand-off to Simplex for transaction rows;
- make group rows passive custody: DTX controls are submitted only by the
  existing coordinator;
- generalize reconciliation to classify both ordinary and group outcomes;
- keep one effect execution function and one terminal state machine; and
- bump the private journal snapshot/row version once, with no compatibility
  branch because deployment already requires the coordinated clean re-found
  and journal cleanup.

The journal must not parse raw ledger history itself. It asks the controlling
Prolog projection for a bounded effect-resolution result. That projection is
already the authority used for ordinary outcome recovery and DTX replay.

The current state names are transaction-specific: `prepared` means "activated
and ready to hand to Simplex", not DTX Prepare. Replace them in the private
snapshot with explicit states:

```text
transaction_bound -> transaction_ready -> transaction_submitted
group_pending
released          -> applied | operator_error
any non-terminal  -> retired
```

`reconcile_row/1` dispatches from these states and the typed commit binding.
A group row is created directly in `group_pending` after the dormant origin
intent exists. It can never enter `bound_owners` or reach `handoff_row/1`;
only a transaction row asks Simplex to sign and submit ordinary content. This
replaces the current state-only dispatch instead of adding a special journal
owner.

The shared result is conceptually:

```text
pending
released(Height)
retired(Reason)
unavailable
```

For a group row, the query is target-local first. It inspects that target's
existing DTX outcome projection and P frontier. The origin group barrier is
needed only to distinguish an orphaned pre-Prepare row from a still-live
group; normal committed execution does not replay or refetch the agent ledger.

## 7. DTX validation changes

The current group-wide rejection is removed at every existing validation
layer together:

- `quod_prolog:submit_sealed_plans/5` no longer rejects a participant set
  merely because one plan contains an effect;
- `quod_dtx:plan_matches_manifest/4` no longer requires
  `effects_count(Plan) =:= 0`;
- attestation, Begin bundle, Prepare check, replay, catch-up, and foreign-log
  validation all continue through that one matcher;
- after target-owned materialization, the one shared
  `quod_effect:validate_plan(Plan, Material)` validates the already-supported
  `effects` material for ordinary submission, attestation, Prepare, and
  replay; and
- the existing direct-effect checks—one effect, known descriptor, empty diff,
  executor/signer binding, actor/principal binding, canonical bytes and
  bounds—remain the only effect rules.

The existing per-plan rule that a direct effect cannot share a plan with a D
diff remains unchanged, but its public error becomes
`effect_requires_empty_diff`. A group may nevertheless contain:

- one effect-only participant;
- ordinary D/OCC participants; and
- several effect-only participants, each with its own local journal custody.

There is no lifecycle, Root, creation, or join branch in DTX validation.

Accepting a formerly invalid DTX shape is consensus-breaking even if tuple
arities do not change. This work is part of the same uncommitted generation as
`generic-agent-identity-plan.md`, so version numbers are allocated **once**:

- `PLAN_VERSION = 7` includes agent identity and effect-bearing DTX plans;
- `MANIFEST_VERSION = 3` covers the changed participant-plan acceptance;
- `RECORD_VERSION = 3` covers Begin/Prepare/Decision/Finalize/Complete;
- `CONTROL_VERSION = 2` remains the unchanged outer author envelope;
- `ATTESTATION_VERSION = 2` keeps its tuple shape, while its acceptance
  semantics are transitively bound by manifest V3; and
- scope wire V5 includes both agent authentication and the custody command in
  section 5.1.

The implementation must land before that generation's coordinated clean
re-found. It must not bump these versions a second time or retain older
decoders. If the identity generation were deployed separately first, this
table would have to be reallocated before coding; that is not the current
release plan. The DTX endpoint framing remains unchanged because no endpoint
tuple changes.

## 8. Ordered apply and runtime reuse

`quod_committed_projection` already materializes the participant plan once at
Finalize(commit). Extend its existing result rather than adding an effect
apply path:

- `apply_prepared` applies the D diff as today and carries the plan's existing
  `effects` list in the same `group_applied` publication;
- `discard_prepared` returns the exact `{GroupRef, TargetIdentity,
  PlanDigest}` retirement binding without decoding effect material—the
  existing `GroupId` plus the manifest's origin tuple reconstruct the public
  `GroupRef` exactly;
- malformed or mismatched effect material remains a deterministic invalid
  committed **commit** Finalize; and
- effect-only plans still have `applied_ops = []`, so they produce no fake
  fact reaction.

`quod_prolog` publishes a DTX apply envelope with the same `effects` field as
an ordinary applied transaction. `quod_runtime` already coalesces that field
and calls `quod_effect_journal:release_applied/2` only after the P tier reaches
the height. Reuse that code unchanged where possible.

Abort retirement is not an E operation and does not pass through the reaction
dispatcher. Ordered Prolog apply tells the same journal to retire rows matching
the exact group binding after the abort projection is flushed. Abort must not
decode the plan merely to recover an effect list: if private material is
missing or the plan bytes are unreadable, the certified abort must still
apply. Journal reconciliation through the authoritative outcome projection is
the fallback and remains able to retire the row.

The existing applied-status endpoint and Complete verifier continue to mean
"the participant Finalize is durably projected." They do not wait for or
report local effect success.

## 9. Recovery and failure matrix

| Failure point | Required behavior |
|---|---|
| proof alternative fails before sealing | overlay drops effect and private preparation |
| one target journal refuses custody | no signed/durable Begin; retire any rows already bound |
| crash after dormant Begin intent registration, before custody | its owner monitor cancels the intent; no row and no signed/durable Begin |
| crash/lost reply after a group row datasync, before Begin activation | row sees the dormant intent as pending; cancellation retires it, activation retains it |
| crash immediately after Begin activation | row was already `group_pending`; exact GroupRef reconciliation later releases or retires it |
| Begin never commits and coordinator admission retires | row retires as `coordinator_retired`; no E |
| Prepare rejects | Decision abort; every bound effect row eventually retires |
| Decision(commit), before target Finalize | row stays pending; no E |
| Finalize(commit), before runtime P | row stays pending; no E |
| runtime P reaches Finalize | row becomes released and existing worker executes E |
| Finalize(abort) | row retires; no E |
| node crashes during E | existing desired-state check resolves or retries without duplicating the logical operation |
| journal has no matching private row | public effect remains auditable; this node performs no E |
| executor is later removed from committee | already-committed local obligation remains; removal does not undo it |
| controlling ontology is temporarily not hosted after restart | retain and retry; never infer rejection from process absence |
| incompatible local desired state | terminal local `operator_error`; group commit remains committed |
| duplicate/replayed Finalize | idempotent row transition; E occurs at most once logically |
| catch-up installs Finalize | same projection and journal reconciliation as live apply |

Failure diagnostics stay on the existing Prolog path. An ordinary predicate
that exhausts already contributes its dereferenced call to `fail_reasons`.
An application or bridge refusal with a concrete cause uses the existing
`fail_with_reason/1`; a foreign prerequisite's bounded reason stack is merged
back into the caller. An Erlang/process/transport fault remains a typed
framework or outcome error rather than being mislabeled as Prolog `false`.
No second DTX-specific reason channel is added, and no reason is persisted in
an effect-journal row. The lifecycle bridge audit keeps plain failure only for
genuine logical absence or mismatch; every typed preparation/staging refusal
is mapped through its existing bounded lifecycle failure reason.

## 10. Result and Explorer semantics

An effect-bearing group returns the normal anchored group result:

- committed only after origin Complete;
- aborted with the certified Decision reasons; or
- `outcome_unknown` with the same stable `GroupRef`.

It never retries or re-proves after uncertainty.

Explorer shows, for each effect-bearing participant:

- target ontology identity and Finalize slot;
- operation, actor, executor, target identity, and EffectId from the certified
  plan;
- `diff: []` when no D fact changed; and
- local journal state when the viewed node owns the row:
  - transaction row: `transaction_bound`, `transaction_ready`,
    `transaction_submitted`, `released`, `applied`, `retired`, or
    `operator_error`;
  - group row: `group_pending`, `released`, `applied`, `retired`, or
    `operator_error`.

The UI labels execution status as local. It must not present it as a property
certified by Complete.

## 11. Performance and metrics

The normal commit path adds no ledger replay and no new quorum round:

- effect custody uses the already-open target scope;
- the bounded effect-bearing targets bind concurrently, so custody adds one
  remote round-trip window rather than one sequential window per target;
- one local journal datasync is still required at each effect-bearing target
  before Begin activation, as required to avoid losing private preparation;
- plans, attestations, controls, and Complete remain the current bounded DTX
  messages; and
- Finalize release reuses the existing runtime queue and journal worker.

The dormant intent occupies the existing single DTX-intent slot for its origin
namespace while those bindings are in flight. A concurrent group proof from
the same origin therefore receives the existing typed retryable `busy`; it
must retry the same signed operation and OperationId, never create a new
operation after an uncertain result. This is bounded by one concurrent custody
round and the proof's existing absolute deadline. It is an explicit
per-namespace contention contract, not a new queue or hidden capacity limit.

Recovery reads the local target outcome projection. It consults the remote
origin barrier only for an orphaned or not-yet-prepared group row. It must not
refetch the agent ontology, re-verify the identity certificate, or replay a
foreign ledger for every effect attempt.

The sealing proof's existing absolute deadline bounds the dormant Begin
intent. On worker exit Simplex's existing monitor cancels it. Group rows
already reconcile from creation and therefore observe either that pending
intent, its activated successor, or definitive absence. Once outcome is
uncertain, custody is intentionally retained until a definitive result becomes
available; no arbitrary TTL may discard private bytes for a group that could
have committed. Capacity pressure is visible through the existing journal
policy and never changes that safety rule.

The existing journal gauges remain the capacity authority: active rows,
reservations, terminal rows, configured capacity, and unlimited policy count
transaction and group custody together. One additional label-free
`quod_effect_custody_group_active` gauge reports how much of active custody is
owned by DTX groups, so an operator can distinguish group pressure without a
second metric family or a second state owner. The existing Grafana custody
panel renders that subset beside total active custody.

Namespace, target identity, GroupId, EffectId, actor, executor, goal, and error
payload are never metric labels. Add Grafana panels in the final integration
slice if new metrics remain necessary after reuse.

## 12. Exact keep / refactor / delete map

| Area | Keep | Refactor | Delete |
|---|---|---|---|
| proof and ACL | normal selector, `can_invoke/4`, actions, overlay staging | none beyond exposing the existing prepared effect to group custody | any effect-specific authorization idea |
| DTX | manifest, attestation, coordinator, controls, recovery, current-view verification | admit and carry already-valid effect plans | group-wide `effect_requires_single_participant` rejection |
| effect custody | one `quod_effect_journal`, capacity, execution, desired-state verification | typed transaction/group commit binding; explicit states; `retire_bound_owner_monitor/2` type boundary; `reconcile_row/1` | transaction-only state/ref assumptions, not the ordinary path |
| apply | `quod_committed_projection`, one Prolog apply fold | carry effects in existing group publication; ordered abort retirement | any DTX-only effect reducer |
| runtime | one queue, P-before-E frontier, `release_direct_effects` | accept the same effects field from DTX publication | separate group-effect queue |
| outcome | existing transaction/group projections and exact barriers | one bounded effect-resolution view | raw-ledger scanning in the journal |
| Explorer | current transaction/control views and local effect status | render effect-bearing participant plans | lifecycle-only group rendering |

The implementation finishes with repository-wide searches for the removed
group error contract and every statement saying effects are excluded from
DTX. The surviving same-plan rule must use `effect_requires_empty_diff`, so no
active `effect_requires_single_participant` remains. Historical text may
retain the old term only when explicitly labelled historical.

The exact source closure includes:

- delete the group rejection in `quod_prolog:submit_sealed_plans/5`;
- delete `effects_count(Plan) =:= 0` from
  `quod_dtx:plan_matches_manifest/4`;
- rename the surviving diff-plus-effect result in
  `quod_dtx:seal_admissible/4`;
- move `valid_direct_plan_effects/2` from `quod_prolog` into `quod_effect`;
- constrain `quod_effect_journal:retire_bound_owner_monitor/2` to ordinary
  transaction rows and refactor `reconcile_row/1` as specified above; and
- extend `quod_scope_wire`, `quod_scope_session`, and the existing target scope
  dispatcher with the one V5 custody operation—no parallel transport.

The active documentation sweep must rewrite, not merely historical-label, the
old boundary in at least:

- `doc/durable-lifecycle-effects-plan.md`;
- `doc/ontology-lifecycle-single-path-plan.md`;
- `doc/ontology-actor-architecture.md`;
- `doc/distributed-proof-plan.md`; and
- `doc/generic-agent-identity-plan.md`.

## 13. Reviewable implementation slices

### Slice 1 — pure protocol admission

**Working-tree status:** implemented.

- confirm the one coordinated V7/M3/record-V3/scope-V5 allocation rather than
  bumping it twice;
- remove the group-wide effect prohibition from the one matcher and origin
  router;
- move the existing executor/actor/shape rules into one pure target-owned
  validator shared by ordinary submission, attestation, Prepare, and replay;
- rename the retained diff-plus-effect error;
- make the committed reducer expose effect lists for apply/discard; and
- add pure codec, tamper, check/apply, replay, and abort fixtures.

This slice is not enabled alone in a deployed release. It lands with the
following custody slice before any re-found.

### Slice 2 — group custody in the existing journal

**Working-tree status:** implemented.

- generalize journal commit bindings and private snapshot rows;
- add idempotent group bind/reconcile operations with exact rollback behavior;
- split the existing origin hand-off into dormant-intent registration and
  final checkpoint/activation, without adding another coordinator or store;
- add the one operation to the existing scope V5 codec/session and thread
  bounded concurrent custody through existing sealed scope handles before
  Begin activation;
- create group rows directly in their reconciled pending state; and
- add every pre-Begin, contention, and hand-off crash test.

### Slice 3 — Finalize release and recovery

**Working-tree status:** implemented.

- carry effects in the existing DTX apply publication;
- reuse runtime's P-before-E release;
- retire abort rows in ordered apply;
- generalize journal reconciliation through the existing outcome projections;
  and
- test live, replay, catch-up, duplicate Finalize, restart during E, and
  operator errors.

### Slice 4 — end-to-end closure

**Working-tree status:** implementation and repository gates complete;
independent review and deployment remain.

- make both current failing signed-agent creation tests pass without changing
  their expected group path;
- add a true remote effect participant, a mixed data/effect group, and a group
  with several effect participants;
- invert `foreign_prerequisite_uses_normal_scope_boundary` to prove that its
  foreign prerequisite plus Root effect now succeeds through DTX;
- update Explorer, metrics/panels if needed, source comments, and all authority
  documents;
- remove the stale rejection code/tests/docs rather than retaining a shim; and
- run compile, full EUnit, relevant CT, xref, Dialyzer, client/UI builds,
  generated-asset equality, stale-term sweep, and `git diff --check`.

Deployment remains part of the same already-planned coordinated clean re-found.
There is no rolling activation or compatibility mode.

## 14. Required adversarial tests

At minimum, review must independently prove:

1. an effect-only foreign participant is admitted and its origin operation
   claim remains in A;
2. Root alone authorizes `create_ontology/2`; A performs no duplicate ACL;
3. a target ACL refusal produces no journal row and no signed/durable Begin;
4. changing any effect, plan, manifest, target, principal, executor, GroupRef,
   or PlanDigest fails closed;
5. a Byzantine admitted plan signer cannot bypass executor/actor binding, and
   a plan containing both D diff and direct effect remains rejected;
6. all effect-bearing target rows are durable before the dormant Begin intent
   can be activated, signed, or proposed;
7. partial custody failure retires earlier rows and leaves no signed/durable
   Begin;
8. journal capacity exhaustion at a later target retires earlier rows and
   leaves no signed/durable Begin;
9. the state machine has no row-activation window: a crash immediately after
   Begin activation finds every effect row already `group_pending` and later
   releases it;
10. while one origin's dormant intent is waiting on custody, a second signed
    group operation from that origin receives typed retryable `busy`, and the
    first operation still completes;
11. Simplex death before Begin activation makes custodied group rows resolve to
    `not_found`, while death after activation rebuilds pending authority from
    the signing journal;
12. origin or target owner death and lost replies on dormant-intent, bind, and
    Begin-activation boundaries neither lose nor duplicate an effect;
13. Prepare failure and both abort paths execute no E, including an abort whose
    plan material cannot be decoded;
14. Finalize(commit) releases only after target P reaches its slot;
15. Complete can certify durable application without falsely certifying local
    E success;
16. replay and catch-up release or retire the same exact row as live apply;
17. duplicate/equivalent Finalize and coordinator recovery execute one logical
    effect;
18. no matching private payload means no IO;
19. the origin also being an effect participant remains unambiguous and
    executes once;
20. several participants' effects remain independently custodied and ordered
    by their own target ledgers;
21. a journal restart with a pending group row recovers from projections, not
    raw history or a re-proof;
22. no route, identity-certificate, ACL, DTX, or effect-executor duplicate is
    introduced; and
23. the two current failing lifecycle witnesses become green through this
    path.

## 15. Non-goals

- no special `create_ontology` or Root coordination path;
- no effect success certificate in Complete;
- no rollback of committed D because local E failed;
- no transfer of a private prepared payload to another executor;
- no arbitrary callback, MFA, or Prolog goal in an effect descriptor;
- no removal of existing per-descriptor byte bounds or the reviewed one-effect
  plan shape in this slice;
- no new agent-identity, ACL, subscription, reaction, or directory design; and
- no deployment before full implementation review and the coordinated clean
  re-found.
