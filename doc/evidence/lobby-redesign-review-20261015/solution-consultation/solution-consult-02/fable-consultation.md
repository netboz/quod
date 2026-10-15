# Lobby first-host: consultation (Fable, offline, source-checked)

## Short answer

Yes. The server-only first-host lifecycle was self-imposed. The one transition the server was supposed to drive (initial host/key + enable + admissions) can be an ordinary **user-signed** execute, issued by the existing signup→lobby handoff in `client/src/accounts.js`, retained in the existing IndexedDB journal before send (`submitDurable`: `journal.put/replace` precedes `post`), and resolved only through `/api/goals/outcomes` (`resolveSignedOperations`). That removes disposition items 1–3 (unassigned physics phase, node-mode custodied signing, node-origin `signed_physics_request`) outright. No new service, process, journal or handshake.

What it does **not** remove is the hosted actor's own activation store (`physics_store_request` issued by `quod_agent:invoke_live` custodied branch). That exists today for every physics world and every owner incarnation; it is unrelated to the lobby. Details in §4 — it needs a ruling from Yan, not lobby code.

## 1. Chosen design (what runs, in order)

1. Signup → `provision_lobby/1` as today. Founding source for the lobby includes `space.pl` + physics composition + default policy; founding facts: `physics_space(personal_lobby, disabled, physics_authority)`, `physics_run(.., 0, none)`, `physics_structure(.., 1)`, `physics_next_body(.., 0)` (no magic IDs), allowances, `physics_definition/3` for floor/roof/console/pilot, `physics_admission/4`, `physics_initial_host(personal_lobby, Node)` written by provisioning = the node whose hosting was requested, control binding `physics_control(personal_lobby, Owner, 1, controlled(pilot, eye)) :- lobby_owner(Owner)`, viewpoint, motion.
2. On the lobby op's terminal `committed`, `accountResult` (step `lobby`) does `rememberAccount`, then a **signed read** (not journaled, idempotent): `lobby_reference(ontology_ref(L,A)), L::(current_ontology_identity(L,A), physics_preparation(W, Node, Key))`. This calls `prepare_agent_key_custody/5` (read-only proof, `local_destination`, `agent_key_preparation` policy, stable vault key — `quod_agent_predicates.erl:98-182`). Happens after the anchor exists.
3. Then one **execute**, child of the lobby op via `replaceOperation: operation.id` (atomic parent→child in `operation-journal.js` `replace`): `L::(current_ontology_identity(L,A), physics_initialize(W, Node, Key))` — one transaction in the lobby: `goal(agent_hosted(I, Node, 1, Key))` (existing `initialize_agent_host` action, guards `agent_preparation_assignment(I, none, 0)`), retract `disabled`/assert `enabled`, then `space_place(E, 0, entity_ref(Ns,A,W))` for each `physics_initial_content(W, E)`. `space_place` → `space_accept_placement` → `physics_space_change(.., admitted)` allocates bodies via `physics_next_body`, asserts `physics_body_definition(.., live(Subject, Assignment, Revision, Digest))`. Any refused policy/body check aborts the whole thing. Single writer → ordinary lane.
4. Commit → `physics_projection` now yields the world (`physics_enabled` ∧ `agent_hosted` on this node) → `install_physics` starts `quod_physics` → **existing** hosted activation, run fence, recovery. Unchanged.

Why `disabled` at founding rather than "enabled intent": `physics_view_selection` reports `disabled` honestly before and after a refused init; enabled-but-unhosted would report `recovering` forever (`physics_active_selection`, `Hosts = []`). The flip is one fact inside the same atomic transition, not a second protocol.

## 2. Shared interface (in `quod_physics.pl`, lobby-independent)

```prolog
can_initialize_physics(_, _) :- fail.     % composition supplies
physics_initial_host(_, _) :- fail.
physics_initial_content(_, _) :- fail.

physics_preparation(W, Node, Key) :-
    current_principal(P), can_initialize_physics(W, P),
    physics_space(W, disabled, I), physics_initial_host(W, Node),
    agent_preparation_assignment(I, none, 0),
    current_ontology_identity(Ns, Anchor),
    prepare_agent_key_custody(agent_instance_ref(Ns, Anchor, I), none, 0, Node, Key).

physics_initialize(W, Node, Key) :-
    term_variables([W, Node, Key], []),
    transaction((current_principal(P), can_initialize_physics(W, P),
        physics_space(W, disabled, I), physics_initial_host(W, Node),
        goal(agent_hosted(I, Node, 1, Key)),
        retract(physics_space(W, disabled, I)), assertz(physics_space(W, enabled, I)),
        current_ontology_identity(Ns, Anchor),
        findall(E, physics_initial_content(W, E), Es),
        physics_place_all(Es, entity_ref(Ns, Anchor, W)))).
```

Lobby composition: `can_initialize_physics(personal_lobby, O) :- lobby_owner(O).`, `physics_initial_content(personal_lobby, E)` for the four entities, plus the draft's existing grants (`can_prepare_agent_key`, `can_assign_agent_host`, activation `can_invoke`s, `can_cancel_physics_activation`). JS passes only the three bindings it received; it chooses nothing.

## 3. Blocker → solution

| Blocker | Chosen solution | Seam |
| --- | --- | --- |
| Server-only first-host obligation, unassigned physics phase (disp. 1) | Dropped. First host is a user-signed execute from the existing handoff. | `accounts.js accountResult` + new `physics_initialize/3` |
| Node custodied signing can't compose (disp. 2), node-origin `signed_physics_request` (disp. 3) | Not needed; node never signs the init. | — |
| Key preparation before anchor exists | Read step runs after `provision_lobby` commits; `prepare_agent_key_custody` is read-only, stable, destination-checked. | `quod_agent_predicates.erl:98-182` |
| Custody-before-send for the init op; lost reply; disconnect before/after; restart | Existing journal: row written before post; unknown outcome → row kept; resume → outcomes endpoint only; terminal replay of parent re-runs the handoff only if the child was never created (replace is atomic). | `signed-client.js submitDurable/resolveSignedOperations`, `operation-journal.js replace` |
| Rejection | Terminal `fail` → row deleted, "setup refused"; lobby stays `disabled`; explicit `finishAccountSetup` retargeted to the init step (new attempt after a *terminal* outcome only). Remove `complete_lobby_setup`. | `accounts.js finishAccountSetup/provisionLobby` |
| Wrong anchor / stale assignment | Goal is anchored (`L::(current_ontology_identity(L,A),…)`); `agent_preparation_assignment(I,none,0)` guards both read and execute; `scope_identity` check in the predicate. | existing |
| Revocation | Explicit later disable/withdraw; `physics_enabled` fails → projection drops the world → `install_physics` stops it. View path writes nothing. `physics_initialize` cannot re-run (assignment ≠ none/0). | existing |
| Disabled state / no activation on view | Founding `disabled`; only a committed parent's child continues; `client_world_view` is a read. | existing |
| Local live definition needs a fabricated self-subscription (disp. 5) | `physics_space_change` admitted: `(current_ontology_identity(Ns,Anchor) -> true ; physics_subscription(Ns,Anchor))`; `quod_runtime:resolve_physics_body/6` local-identity branch reads definition/assignment/delegate from the same committed selection, ordinary read deps, foreign path unchanged. | `quod_physics.pl` ~line 71; `quod_runtime.erl resolve_physics_body/6` (not in excerpt — verify) |
| Scene/controls must resolve the admitted pilot body (disp. 7) | `physics_agent` body/revision become a rule over `physics_body_definition(W,B,R,controlled,_,live(entity_ref(Ns,A,pilot),_,_,_))`; scene marks use `body_pose(B,R)` from placements; remove `lobby_device/2`, `device_placement/3`. | `quod_physics.pl`, `lobby_instance.pl world_view/lobby_view` |
| `entity_eidolons` ignores inheritance (disp. 6) | `findall(Class, ((instance_of(D,Entity) ; D = Entity, isa(D,D)), isa(D,Class)), Raw)` using the existing transitive `isa/2`. Keep `instance_of(lobby_floor, floor)` class-first as written. | `common_predicates.pl:62` |

## 4. The activation store — pre-existing, and distinct from first-host

**Can a composite init set the initial run so the owner needs no first activation? No.** `quod_physics:advance_current` requests activation whenever `custody := none`, and `start_native` only runs when `run_token =:= #s.token` — a random per-incarnation token (`init/1`). The run is an incarnation fence, not a one-time step: every owner start (first and every restart) stores and activates. The user cannot sign it either (`physics_actor/1` requires the hosted authority as principal). The client journal is irrelevant to it.

**What actually happens in the crash window (store submitted, reply unobserved, owner restarts):**
- Store committed, inner activation never sent → new incarnation resolves the inner request → not committed → `{unavailable, activation_resolution_unavailable}` / `activation_unresolved`, phase `unresolved`. Stuck until the owner's explicit `physics_cancel_activation/3`; cancel stops/reinstalls the process; a late inner activation then fails (`physics_request` gone). Honest, explicit, not automatic. Same for a terminally rejected inner activation.
- Store never admitted → new incarnation stores again. Safe.
- Store in flight, unknown → new incarnation issues a **distinct** store at the same generation. Both read `physics_request(W,_)` absent; the empty-slot read conflict (the same mechanism spaces.md relies on for competing `space_place` proofs) rejects the later one; `physics_previous_complete` refuses if the first already applied. At most one `physics_request` per generation; never two runs; no deadline change; no invented outcome.

So the safety properties hold at the domain, and the only exposed state is bounded. What is **not** met is the literal sentence in `lobby-redesign.md`: "a new runtime incarnation [does not permit] another submission of an uncertain write" — the owner's volatile `#s.uncertain` is lost on restart and a new incarnation does issue a distinct store. There is no durable place for the store bytes without a second journal (`quod_effect_journal` holds prepared effects; forbidden to stretch), and deterministic bytes are refuted (random op id/token, expiry).

**Verdict:** not a lobby release blocker — the lobby's first-host op is fully custodied client-side, and the activation path is explicitly "existing" in the design. It **is** an unresolved standing contract for every physics world. Smallest remedy with existing owners: (a) Yan rules that the custody slot's domain exclusivity is the store's contract (distinct attempts across incarnations cannot both commit; stored-unsent → explicit cancel), and the doc sentence is amended to say exactly that; (b) make the pending/terminal custody visible to the owner through the console (`physics_activation_status/3` already derives it; `physics_cancel_activation/3` already exists; policy `can_cancel_physics_activation` from the draft). No retry, no timer, no new store. If Yan rejects (a), this becomes a real blocker for *all* physics, not just the lobby, and I have no lawful remedy without a shared durable-admission design.

## 5. Exact scope

Add: `physics_preparation/3`, `physics_initialize/3`, `physics_place_all/2`, 3 hooks; local branch in `physics_space_change`; pilot-body rule; `entity_eidolons` inheritance; `resolve_physics_body/6` local branch (Erlang, small); `accounts.js` step `physical` (~30 lines: read → execute with `replaceOperation`; terminal branch deletes); `finishAccountSetup` retarget; lobby default source from the superseded draft minus `lobby_startup/1`, `start_lobby_physics/2`, magic IDs, `lobby_physics_host/1` (becomes `physics_initial_host/2`).
Remove: `complete_lobby_setup`, `lobby_device/2`, `device_placement/3`, `placed_devices/2`, lobby-physics journal stage remnants. Docs: rewrite lobby-redesign.md §§"Founding…"/"Concrete shared gaps"; mark disposition's "remaining blocking contract" as relocated to the activation store ruling.
No new Erlang process, no new journal, no node-signed first host.

## 6. Unresolved (verify before implementing)

1. **Yan ruling** on §4(a). Lobby-independent.
2. Does the `::` read into the lobby execute on the hosting node so `local_destination(Node)` holds for `physics_initial_host`? If not, the read fails closed (`custody_destination_unavailable`) and login re-tries the continuation — acceptable only if it is not permanently wrong under the normal deployment.
3. Exact round trip of the 32-byte prepared key through the read reply and back into goal text (memory: signed-read replies have mangled 32-byte binaries). `initialize_agent_host` only checks 32 bytes; a wrong key commits an inert host. Test: committed `agent_key/3` equals the vault's staged key.
4. `physics_control_configuration` (not in excerpt): confirm where it takes the pilot body and reroute through the live binding.
5. Nested `transaction/1` + self-`::` inside `physics_initialize` (spaces.md says re-entrant scope and savepoints exist; confirm in one write proof).
6. Pre-existing: `physics_active_selection` yields `simulation_view` once generation > 0 even before native install; the view says "recovering" only at run 0. Not in this scope.

## 7. Acceptance tests

- Fresh signup on a clean candidate → lobby `disabled` → preparation read → init commits → one `physics_request`/run per owner incarnation → landing on floor, console/roof collision, authored openings (desktop).
- Non-lobby physical fixture using the same `physics_initialize/3`; nonphysical space → `nonphysical`.
- Refused init (policy false; oversized body; allowance) → `fail`, no partial facts, lobby `disabled`, no native world; explicit `finishAccountSetup` creates a new attempt only after terminal.
- Wrong anchor; stale assignment (second init) → fail, no change.
- Browser crash after `replace` before post → resume resolves child via outcomes only; same bytes never hit `/api/goals/execute` twice (assert at ingress). Crash before `replace` → parent terminal replay creates the child once.
- Lost reply / disconnect after submit → row kept, outcome resolved on login; no second signing.
- Owner restart between store submit and reply: exactly one `physics_request` for G, zero or one run advance, world ends `active` or `unavailable` with `physics_activation_status(.., pending)` visible; owner cancel then recovers. No automatic re-store beyond the single new-incarnation attempt; no deadline extension.
- Explicit disable → world stops; opening the lobby never re-enables.
- Unchanged reload: no domain write, no history replay, no geometry rebuild (`installs` counter unchanged).
- Local definition admitted without `subscribes/2` to self; foreign path still requires the authored subscription.
- `entity_eidolons(floor, E)` includes recipes selected on inherited classes; `instance_of(lobby_floor, floor)` untouched.

Stop notification: no tool access in this review, so `/bin/sh /home/yan/.codex/notify-stop.sh` was not invoked.