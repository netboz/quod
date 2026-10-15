# Review: `doc/lobby-redesign.md` (lobby review-02)

**Verdict: blockers.** The class model, inheritance and view composition are right and minimal. The first-authority lifecycle is not implementable as written: the proposed extension of the physics owner needs five concrete contract changes the design leaves unspecified, and the existing custody path has one liveness hole the design must name. Nothing below needs a new engine, service, queue or protocol.

## Findings

**1. First-authority lifecycle — the existing owner cannot run before a host exists.**
`physics_projection/2` (quod_physics.pl:470-473) requires `agent_hosted(I, Node, Epoch, Key)`; `install_physics` (quod_runtime.erl:3114) starts `quod_physics` only from those rows. Pre-authority there is no process to drive `request_activation`. `physics_admit` (quod_runtime.erl:3203-3205) resolves the executor only as `{agent, I, E, K}` from the spec's authority; a spec without one is silently dropped (`_ -> S`), leaving the process pending forever. `physics_capacity` (3240) crashes on a non-agent authority.
*Minimal correction:* a second `physics_projection` clause selecting a world with committed first-host configuration (`physics_first_host(W, Node)` or equivalent), `physics_enabled(W, I)`, `\+ agent_host(I,_,_,_)`, `\+ agent_key(I,_,_)`, emitting `authority = none, epoch = 0, key = none`; `physics_admit`/`physics_capacity` clauses for `authority := none` that use the node slot. No separate driver.

**2. Node slot cannot sign a custodied or key-prepared request.**
`sign_request(node, …)` (quod_agent.erl:243) matches only `{{node, NodeRef, Mode}, Goal, Expires}`. The custodied path (`invoke_live`, 222-236) re-enters with `{execute, Custody, Expires}` → no clause → caught as `agent_request_failed`. `prepare_goal(node, …)` (134) only fires when `Mode = {node, NodeRef, execute}`, so `{custodied,…}` wrapping a `{custody, AgentRef, 0, Var, Template}` goal skips preparation and fails the ground check. The design's "node executor prepares custody … one ordinary signed transaction" presumes a path that does not exist.
*Correction:* carry the inner `{node, NodeRef, execute}` mode through the custodied clause and prepare the `{custody,…}` template before signing. Small, but it is a `quod_agent` contract change and must be stated.

**3. Custody verification binds signer = scope; a node signature fails it.**
`signed_physics_request` (quod_physics_predicates.erl:196-206) requires the request's `agent_namespace/anchor` to equal the current scope and `goal_blob` to equal `encode_goal(physics_activate(W,G,Token))`. A node request is scoped to the node ontology with goal `node_authorized_goal(LobbyNs, LobbyAnchor, Op)` (node_execution.pl:4-6). `physics_actor/1` (quod_physics.pl:487-490) and `physics_activate` additionally require the principal to be the hosted authority. All three refuse the pre-authority case.
*Correction:* one explicit unassigned clause each: principal = the committed first-host node, `physics_run(W, 0, none)`, no `agent_host(I,…)`; `signed_physics_request` accepts request scope = that node's exact identity and goal = `node_authorized_goal(Here, History, Expected)`. Also verify `current_signed_request/1` sees the outer node bytes inside the `Source::` hop; if not, the composite action cannot bind to its custody row.

**4. Liveness hole: a retained-but-never-sent request has no exit except explicit cancel.**
After custody commits, only `invoke_live` (quod_agent.erl:227-231) submits. If the worker/node dies between commit and submit, every later incarnation hits `advance_current` last clause (quod_physics.erl:246) → resolve → `activation_resolution_unavailable` → `unresolved`, and `advance` is ignored in `unresolved` (174). Absence and in-flight are indistinguishable by design (multiwrite-architecture: pending/absent both error). The design says "resolve that identity across owner restart" as if resolution restores progress; it only restores *safety*. The same applies after a terminal `rejected` (bad body definition): `physics_previous_complete(request(_,0,…),0)` fails, so no new attempt can be stored until the row is cancelled.
*Correction:* state this explicitly: recovery from that window and from a rejected first-host is the owner's explicit `physics_cancel_activation/3`, which is sound because the composite's proof reads `physics_request/2`, so a cancelled request can never commit later (fence, not timeout). Grant `can_cancel_physics_activation(W, Owner)` in the default policy and surface `physics_activation_status/3` + resolved outcome in the view instead of plain `recovering`. Do **not** add a node auto-cancel timer. If Yan wants automatic liveness, the only candidate is exact redelivery of the retained `{Bytes, Signature}` (same operation id, same deadline) — the "exact claim redelivery" ruling — and that requires confirming apply dedups by `{actor, operation_id}`. That is a ruling, not something to assume.

**5. Repeated custody writes across restart — name it, don't hide it.**
`#s.uncertain` is volatile. A restarted unassigned incarnation seeing `custody := none` signs a *new* `physics_store_request` (246 → `request_activation`). Two custody writes for generation 0 are mutually exclusive via the `physics_request`/`physics_run` read set and are inert until committed; the loser never submits its inner request. This is the existing owner's behaviour, not a FIPA borrow — but the design text ("neither … a new runtime incarnation permits another submission") should say it applies to the *inner* first-host request only, and that custody writes are exclusive by generation.

**6. Local admission needs a local branch, not a self-subscription.**
`physics_space_change(W, Subject, admitted)` (quod_physics.pl:75) requires `physics_subscription(Ns, Anchor)`, which scans authored `subscribes/2` (101-104). Local entities (Ns = Here) fail.
*Correction:* `(Ns == Here, Anchor == History -> true ; physics_subscription(Ns, Anchor))` at that one site. Verify self-`::` (`Ns::(… physics_delegate_definition …)` at 80 and `physics_resolve_definition` live branch at 20) resolves to the local scope; and verify the Erlang installer serves a `live(entity_ref(Here,…))` source from local committed state rather than a foreign projection lookup. Keep foreign checks unchanged.

**7. `entity_eidolons/2` does not expand ancestry.**
common_predicates.pl:60 collects only direct `instance_of/2` classes. A `class_eidolon(physical_space, …)` recipe never selects for `personal_lobby`. `device_classes` (lobby_instance.pl:52) is a second, lobby-private ancestry expansion.
*Correction:* expand ancestors in `entity_eidolons` once (`instance_of(Direct, Entity), isa(Direct, Class)` — same shape as `space_instance/2`); delete `device_classes`/`lobby_eidolons` dispatch or reduce them to `class_eidolon/4` providers. One dispatch path.

**8. `world_view/3` is lobby-only.**
lobby_instance.pl:11 keys on `instance_of(lobby, Space)`; the required non-lobby physical-space fixture gets `Marks = []`/`unavailable` from `client_world_view`. The scene rule belongs with the space/physics composition, keyed on `space_contains/2` and class-selected Eidolons.

**9. Scene marks must be derived from the live binding or omitted.**
`physics_view_bodies` (quod_physics.pl:456-464) fails the whole selection (`unavailable`, not `recovering`) if any `body_pose(B,R)` lacks an exact `physics_body_definition(W,B,R,…)`. Pre-admission the selector must emit a solid's mark only from its current `live(entity_ref(Here,History,Entity),…)` row. This also fixes one physical truth: `device_placement/3` and magic ids go.

**10. Control binding timing.** Keep `physics_control(W, Owner, _, controlled(…))` in the step-4 transaction, not founding; otherwise `physics_selected_control` fails pre-body and the view reads `unavailable` instead of `recovering` (quod_physics.pl:434-441). Control configuration resolves the pilot body via its live binding, never a literal id.

**11. Class-first `instance_of/2` is inverted in the example.** spaces.md: `instance_of(Class, Entity)`. `instance_of(lobby_floor, floor)`, `instance_of(lobby_roof, roof)`, `instance_of(prolog_console, console)` declare classes `lobby_floor`/`lobby_roof`/`prolog_console`. Should be `instance_of(floor, lobby_floor)` etc. Also confirm vocabulary class terms are bare atoms, not `Owner:Name` references (`vocabulary_class/3`), or `isa`/`class_eidolon` keys won't match.

**12. Founding facts missing from the design.** `physics_run(W,0,none)`, `physics_structure(W,0)`, `physics_next_body(W,0)` must be founded or `body_allocator_missing`/`physics_advance_structure` fail. The pinned lobby vocabulary recipe (`lobby_recipe/3` consuming `device(Classes,Entity,Id,At)`) must change to accept `body_pose/2`; that is a system-ontology change covered only by the clean refound.

**13. Transitive `isa/2`.** Design and spaces.md depend on reflexive/transitive `isa/2` rules; only `isa(X,X)` use is visible. Verify the composed lobby program actually derives `isa(lobby, space)` without left-recursion.

## Minimal transition sequence (first authority)

- **T0 founding** (one tx): classes/instances; `physics_space(L, enabled, A)`; run/structure/allocator zero facts; allowances; definitions and `physics_admission/4`; first-host node selection fact; narrow ACL: node `can_invoke` for exactly `physics_store_request/6`, the composite first-host action, `can_prepare_agent_key(Node, A, none, 0, Node)`, `can_assign_agent_host(Node, A, none, 0, Node, _)`, setup entry/admit/delegate grants; owner `can_control_physics_agent`, `can_cancel_physics_activation`. Node ontology: `can_execute_for(L, Anchor, Goal)` for the same shapes.
- **T1** projection emits the unassigned row → `quod_physics` starts (authority none). View: `recovering`.
- **T2** (read-only, idempotent) node slot: `prepare_agent_key_custody(agent_instance_ref(L,Anchor,A), none, 0, Node, Key)` — vault key for `{Blob,0}` is stable; crash here costs nothing.
- **T3** node signs R = `node_authorized_goal(L, Anchor, first_host(L, 0, Token, Key))`; body: `initialize_agent_host(A, Node, Key)`, `space_place(E, 0, entity_ref(L,Anchor,W))` per solid, control/viewpoint binding, `physics_activate(L, 0, Token)`. Volatile; never sent.
- **T4** custody write C = node-signed `physics_store_request(L, 0, none, Token, Bytes_R, Sig_R)`. Unknown result: at most one generation-0 row can commit (read set on `physics_request`, `physics_run(L,0,_)`); a competing C' from a later incarnation is exclusive and inert. Only after C is observed `committed` does the same worker submit R.
- **T5** submit R. Unknown result → restart resolves exact bytes only; never re-signs. Committed → host, bodies, run 1 in one commit; projection flips to the hosted row; unassigned incarnation stops; hosted incarnation resolves R (committed) and performs its own ordinary activation 1→2. Rejected or never-sent → `unresolved`; owner cancel fences R, then a new attempt is allowed. Disable before R applies → R rejected (`physics_enabled` in `physics_actor` and admission). Wrong/stale anchor → `current_ontology_identity` fails inside `node_authorized_goal`. Stale selection after hosting → `agent_preparation_assignment(none,0)` fails.

## What is missing, exactly
Findings 1-3 (unassigned projection/executor plumbing, node-slot custodied+prepared signing, node-scoped custody verification) and the ruling in 4. The effect journal provides none of this; the design is right not to claim it. Do not start implementation until 1-4 and 6-9 are specified in the doc.

## Decisive tests (production owners, non-lobby fixture first)
1. Unassigned row → key prep → custody → submit → committed → hosted row → native; assert no `simulation_view` and no native resource before the hosted row.
2. Kill between custody commit and submit; restart: exactly one resolve, zero new signatures, zero second custody rows, phase `unresolved`; owner cancel → new attempt commits; late delivery of original R rejected.
3. Two incarnations issue custody writes for generation 0: one row, loser's R never reaches ingress.
4. Lost reply after submit: restart resolves `committed`; exactly one `agent_host` row.
5. Disable/revoke before R applies: rejected, no bodies, empty projection.
6. Local entities with no `subscribes/2` admit; foreign entity without subscription still refused; wrong anchor refused.
7. Body ids from `physics_next_body/2` only; control configuration follows the pilot's live binding after re-admission changes its id.
8. `space_instance(personal_lobby, space/physical_space)` hold; info space → `nonphysical`; `entity_eidolons(personal_lobby, _)` includes an inherited `physical_space` recipe.
9. Expired retained R: status `pending`, no resubmission, cancel clears.
10. Repeated `client_world_view` reload: no writes, no projection rebuild, no geometry rebuild.

No notification sent — tools unavailable this turn.
