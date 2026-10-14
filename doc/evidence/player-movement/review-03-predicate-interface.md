# Player movement review 03: Prolog predicates as the VR interface (Fable, consultative)

Date: 2026-10-07. Targeted note after Yan's steering: VR talks to the world
through Prolog predicates backed by Erlang external predicates, as in bbsvx.
The raw simulation-socket input path is withdrawn. This note does not repeat
[review-01](review-01.md) or [review-02](review-02.md); their binding,
projection, race and recovery findings stand. No production edit, build or
test.

Read for this note: `AGENTS.md`;
`/home/yan/src/bbsvx/src/ontologies/bbsvx_physics_predicates.erl`;
`src/quod_predicates.erl`, `src/predicates/quod_agent_predicates.erl`,
`src/predicates/quod_runtime_predicates.erl`,
`src/predicates/quod_ontology_predicates.erl`,
`src/predicates/quod_transaction_predicates.erl`, `src/predicates/quod_ask.erl`,
`src/quod_effect.erl`, `src/quod_effect_journal.erl` (moduledoc),
`src/quod_erlog_db_local_prove.erl` (live bridges, prepared effects),
`src/quod_dtx.erl` (sealing), `src/quod_prolog.erl` (read-only normalisation),
`src/quod_client_goal_target.erl`, `src/quod_physics.erl`.

Legend as before: **EXISTING**, **RECOMMENDATION**, **DECISION** (no
existing path suffices; the parent must choose).

---

## 1. What bbsvx did, and what Quod already has (EXISTING)

bbsvx (`bbsvx_physics_predicates.erl:1-30`): write predicates validate and
read facts during proof, record a `#effect{type=construct_effect}` descriptor,
always succeed, and `exec_*` dispatch runs **after diff application**. Read
predicates `body_position/2`, `body_rotation/2`, `body_velocity/2` unify live
engine state. Every bbsvx physics command was therefore a replicated goal;
there was no transient lane.

Quod has the same two halves, with stricter classes
(`quod_predicates.erl` moduledoc):

| Quod piece | Class / rule | Movement relevance |
| --- | --- | --- |
| `query` bridge, `live_observation` dependency (default for `register/5`) | Allowed in proof, verdict and reaction. Recorded as a live bridge; `seal_bound_reads` rejects sealing a nonempty diff or effects that consulted one (`quod_dtx.erl:249-257`, `quod_erlog_db_local_prove.erl:583`). | The exact class for `body_pose/3`, fit/sweep checks and any other live physics read. Nothing to add. |
| `staging` bridge | Proof kind only; stages durable ops into the overlay (`trigger_event/1`, `create_ontology/3`). Durable direct effects are the closed `quod_effect` descriptor, lifecycle `create|join` only (`quod_effect.erl:22-26`), released by `quod_effect_journal` after ordered apply. | Closed. Movement must not be forced through it; a per-input ledger write is exactly what is forbidden. |
| `reaction` bridge (`physics_observation/1`, `prepare_signed_request/3`) | Read-only matching of one `react_on/2`; the bound goal then enters the hosted actor's queue. | The door's committed-intent lane. Correct for durable consequences; a consensus commit per intent change. |
| `sign_agent_request/2` (`quod_agent_predicates.erl:51-56`) | `query` class, but **fails unless `quod_proof_session:read_only_state/1` is true**, then evaluates `can_sign_agent_request/3` policy and releases a signature from the vault. | Precedent: a governed side effect on a local owner, released only in a read-only session, after Prolog policy, with nothing sealed. |
| `request_resource/4` (`quod_runtime_predicates.erl:290-312`) | `query` class, proof kind only; sends `reconcile_resource` to the runtime and waits within the proof budget. | Precedent: a query bridge with an owner side effect that is idempotent (converge to committed state). |
| Read-only `::` scope (`quod_ask.erl:299-301`) | `read_only() -> local`: a read-mode `World::Goal` is proved on this node's copy of the world. | A read-mode goal from the human's ontology reaches the world scope on the node where the proof runs. |
| Read-only session writes | A DB write in a read-only proof is refused as `{error, read_only}` (`quod_prolog.erl:5502-5506`). | A read proof structurally cannot produce a diff. |
| Erlog state is functional | The overlay (`#lp{}` inside `#est.db`) is discarded with the failed branch; `prepared_effects` already live there (`quod_erlog_db_local_prove.erl:233-253`). | Anything staged in the overlay gets proof failure and backtracking semantics for free. |

So Quod already has: live reads as queries, durable intent as reactions, and
a read-only-session-only release pattern. It does not have a transient
(never-sealed, never-journaled) staged effect released after a successful
read-only proof.

---

## 2. The three candidate paths for transient movement

### A. Governed runtime query (the `sign_agent_request` shape)

A `query` bridge `physics_intent(Agent, Seq, Intent)` that, inside a read-only
proof, checks policy and immediately hands the intent to the local
`quod_physics` owner.

- Preserves "no ledger write" and "no second executor".
- Breaks "proof failure/backtracking": the owner receives the intent the
  moment the bridge runs; a later failing conjunct or a cut-away alternative
  has already moved the body. `sign_agent_request` tolerates this because a
  released signature is inert until submitted; a movement intent is not.
- Making the intent idempotent and sequenced (as `request_resource` is
  idempotent) limits the damage but is precisely "silently treating a movement
  side effect as a query". **Rejected for writes; correct for reads.**

### B. Extend the existing proof/effect owner with a transient class

A bridge stages a *transient* descriptor into the proof overlay beside
`prepared_effects`; the read path of `quod_prolog:execute_signed` releases the
staged descriptors to the local owner only when the proof succeeds; the
descriptor never enters `quod_effect`, the journal, the diff or sealing.

- Preserves backtracking (overlay is functional state).
- No ledger write (read-only session; refuse staging outside one, exactly as
  `sign_agent_request` refuses signing outside one).
- No second executor: the release is one message to the already-registered
  `quod_physics` owner, which validates it against its installed spec, the
  same way it validates `physics_selected`.
- **This is the path that matches Yan's model and the constraints. It requires
  a small extension that does not exist today (DECISION below).**

### C. Committed intent (door pattern)

`physics_set_intent(W, Agent, Seq, Intent)` as an ordinary transaction; the
owner installs it from the projection; a sampled result comes back through the
authority's signed action.

- Correct and already built for durable objectives (door close, future
  "go to", durable reposition with occupancy validation, review-02 I1).
- A consensus round per intent change. Continuous VR locomotion changes
  intent many times per second; a commit per change violates "no per-frame
  ledger writes" in spirit even if each write is not literally per frame.
- **Keep for discrete, durable-worthy intents. Not the continuous lane.**

---

## 3. Recommended concrete semantics (RECOMMENDATION)

### 3.1 Vocabulary (world ontology, Prolog owns the policy)

```prolog
%% Live reads: query class, live_observation. Fail if no local owner.
body_pose(World, Body, pose(vector(X,Y,Z), quaternion_m(QX,QY,QZ,QW))).
physics_fit(World, Agent, Motion, Result).      % sweep without applying
%% Transient staged effects: only inside a read-only proof.
physics_intent(World, Agent, Seq, Intent).      % latest continuous intent
physics_step_intent(World, Agent, Seq, Step).   % teleport, snap turn: applied once
%% Prolog-side validation, no bridge involved.
valid_movement_intent(World, Agent, Intent) :- physics_agent(World, Agent, _, _, Motion), ...
```

The human's signed read goal is, for example:

```prolog
World::(current_principal(P),
        physics_control(World, P, Epoch, controlled(Agent)),
        can_control_physics_agent(World, P, Agent),
        valid_movement_intent(World, Agent, Intent),
        physics_intent(World, Agent, Seq, Intent)).
```

Everything before the bridge is ordinary committed-snapshot Prolog: control
row, grant, motion policy (speed and turn clamps, supported modes) are proved
first. The bridge takes only a ground, already-validated term. Appearance,
viewpoint and tracking never pass through it.

### 3.2 Bridge contract

- Registered `staging` class (it stages into the overlay), but the handler
  fails closed unless `quod_proof_session:read_only_state(St)` is true. That
  makes a durable transaction structurally unable to carry movement, mirroring
  `sign_agent_request`. Dispatch's class matrix already excludes verdict and
  reaction contexts.
- The staged descriptor is
  `{physics_transient, World, Principal, Epoch, Agent, AgentRev, BodyRev,
    Height, Seq, Intent, Expiry}` where `Principal` is the authenticated
  principal (`quod_scope_session:principal/0` or proof context, as
  `current_principal/1` reads it), `Height` the proof's pinned height, and
  `Expiry = min(signed not_after_ms, policy freshness)` via the existing
  `current_request_expiry/1`.
- Staging requires a registered local owner (`quod_reg:where({physics_world, World})`)
  and fails with a visible reason otherwise. It performs no I/O during proof.
- At most one continuous intent and a bounded number of step intents per
  proof; the policy predicate (`physics_allowances/5` sibling) owns the bound,
  not an Erlang constant.

### 3.3 Release

- The read path of `execute_signed` releases staged transient descriptors
  only if the proof produced an answer. If the goal yields more than one
  answer with differing transient sets, refuse (visible error); the goal must
  be deterministic in its effect. Failure, exception, deadline and `read_only`
  refusals release nothing.
- Release is one message to the owner: `Pid ! {physics_transient, Ref, Descriptor}`.
  No reply is awaited inside the proof. The proof's answer reports
  `staged(Seq)`, not `applied`.
- The owner (`quod_physics`) validates the descriptor against its installed
  spec: `Principal`, `Epoch`, `Agent`, `AgentRev`, `BodyRev` must equal the
  installed control row, and `Height` must be ≤ its spec's height. A mismatch
  or a stale `Seq` is dropped silently (stale and duplicate notices are
  harmless, AGENTS.md). A continuous intent replaces the previous one for that
  principal; a step intent is applied once at the next step and its `Seq`
  recorded. The owner never holds a queue; it holds one latest intent and one
  pending step per control.
- Outcome is observed, not acknowledged: the existing view stream shows the
  pose; `body_pose/3` or a `physics_last_applied(World, Agent, Seq)` live query
  answers a lost reply. Nothing is resubmitted.

### 3.4 Durable lane stays the door pattern

Teleport that the domain wants durable, "go to" objectives, and occupancy-
validated reposition use `physics_set_intent/4` as a transaction, owner
execution and the authority's signed sampled result, exactly like
`physics_close_door/4`. A transient step intent that lands the body somewhere
is lossy by definition (`world.md`: unsaved motion is lossy).

### 3.5 Why this honours every constraint

- Proof failure and backtracking: staged state is in the Erlog overlay.
- No per-frame ledger write: read-only session only; nothing sealed.
- No second executor: the release target is the existing owner; the proof
  runner does not execute anything.
- Not a query in disguise: the write bridge is `staging`-classed and
  released after success; the read bridges are `query`/`live_observation` and
  already taint sealing.
- One principal across scopes: the proof runs under the human; the world's
  `can_invoke/4` and the control row decide.
- Repeated cost: one signed read proof per intent change, zero writes, a
  bounded map in the owner. The client sends on change and at expiry, not per
  frame; policy sets freshness. This cost must be measured; a read proof opens
  the world scope locally each time (`get_or_open_scope`).

---

## 4. Required decisions (DECISION)

**D1. Transient staged-effect release does not exist.** Quod has no
never-sealed effect class and no post-success release hook in the read path.
Adding it touches `quod_erlog_db_local_prove` (one overlay slot beside
`prepared_effects`, same backtracking), `quod_prolog:execute_signed` read
completion (release on answer, refuse on ambiguity), and the owner's
`handle_info`. It must not touch `quod_effect`, the journal, `quod_dtx` or
sealing. Without D1 the only alternatives are A (rejected) or C (a commit per
intent change). The parent must decide to add it.

**D2. Locality.** The bridge reaches the owner only on the node hosting the
world's physics authority, and ordinary ingress runs the proof where the
human's ontology is available (`quod_client_goal_ingress.erl:execute_gateway`
forwards otherwise). The first profile therefore needs either: the human's
ontology available (validator or observer copy) on the authority's host and
the browser connected there, which is the same constraint the current view
endpoint already imposes (`local_authority_required`); or a new ingress route
to the host of a named hosted agent, which does not exist. Recommend the
former for the profile and state it.

**D3. Read-mode goal answer cardinality.** Decide whether transient release
requires exactly one answer (simplest, recommended) or the first answer. This
is a protocol choice at the read path, not an ontology one.

**D4. Who may stage.** The recommendation lets any principal with a current
`physics_control` row stage; a hosted actor principal can then drive an agent
through the same predicate from its own reaction-selected goal, which answers
review-02 I7 without a second input lane. Confirm this is wanted; otherwise
restrict by policy, not by Erlang.

---

## 5. What the parent can build and test now, in pure Prolog

- `valid_movement_intent/3` clamps and mode checks against `physics_agent/5`
  motion policy; unsupported modes fail, never fall back.
- `physics_control/4`, `can_control_physics_agent/3` and the goal shape in
  §3.1 proven under a foreign human principal in a read-only session, with
  `physics_intent/4` stubbed as a predicate that fails when no owner exists.
- The door-pattern durable intent `physics_set_intent/4` with expected
  revisions, for the discrete lane.
- Refusal of `physics_intent/4` inside `transaction/1` (execute mode) is a
  property of D1's handler and cannot be tested before it exists; record it
  as the first native/owner obligation.
