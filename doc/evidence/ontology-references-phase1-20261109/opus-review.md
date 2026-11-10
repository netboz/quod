# Claude Opus review of the preceding Phase 1 candidate

Session: ea91cdc1-e21b-4ebd-a17d-2b02bfb8d13f. Read-only, no tests run by the reviewer. Findings refer to the candidate before Yan authorized the corrections; this transcript is preserved unchanged below.

Reading the plan and required docs before I go into the patch; continuing the review.

Reviewing the engine diffs now (guard frame, scope sessions, runtime).

Checking custody ACL clauses for the removed assignment check.

Now checking how class-owner checks interpret local instance subjects.

Guard frame looks consistent so far; moving to the runtime/resource-selection refactor.

Runtime has one plausible stall; now checking the scope-wire read-set change and construction.pl.

Signed-read path: precise read sets are collected and shipped on every read, not just runtime selections. Now construction.pl.

Checking whether quod:gui ever forwards caller-shaped goals into storing ontologies (the ACL grants above are goal-wildcards gated only on chain head).

HUD/question ACLs are broad by chain head but each owner rule re-checks principals; no concrete bypass found. Now the Godot class-ref/storing-ontology flow.

Now the cold release preparation (atomicity, removed definitions, installed dependents).

Checking test diffs for weakened obligations, starting with runtime tests.

Need to verify a potentially serious change: proof-context origin identity now set to the request's agent ontology.

I found no blocking defect in the Phase 1 authorization core. I found two Medium/Low cost-and-liveness defects, one Low ownership regression, and two Low test/doc gaps. This was a read-only inspection of `/home/yan/src/quod_worktrees/pearl-stone`: I ran no builds or tests, made no edits, delegated nothing, and reproduced none of the findings. Each one is consultative and needs your own check.

## Findings, most severe first

### 1. Medium — every signed read now gathers and ships per-predicate read sets that only the runtime uses
- **Where:**
  - `src/quod_prolog.erl:4394-4399`: every `mode := read` request calls `quod_proof_context:read_dependencies()`, whatever its `read_mode`.
  - `src/quod_proof_context.erl:636-646`: that call issues `quod_scope_session:read_set/1` once per opened scope.
  - `src/quod_scope_session.erl:243-261`: for a remote scope this is a router command plus a network round trip, using the proof's remaining deadline.
  - The result is a 4-tuple carrying all predicate/version pairs. `quod_client_result.erl:316-318` validates them and `quod_client_goal_router.erl:620` encodes the whole result onto the link.
  - Ordinary consumers throw the pairs away: `quod_client_view.erl:261` and `quod_client_result.erl:407`.
- **Trigger:** any Godot or browser view read, renewal or setup read whose proof opens foreign scopes. Examples are `quod:user::account_navigation`, `quod:gui::hud_commands` and `gui_question_form` at another ontology.
- **Consequence:**
  - One extra command per scope on every read and renewal (a network round trip when the scope is remote), on a path where unchanged renewals are meant to do only the needed work.
  - Larger routed result frames, which raises the chance of `result_too_large`.
  - A new failure mode: if `read_set` times out or the scope dies after the answer was produced, a completed read becomes `{error, Reason}` (see `quod_prolog.erl:4397`).
  - The journeys measure reader/history/install and file I/O, not these messages or the payload size, so they would not catch it.
- **Evidence vs inference:** the call path and the discarding sites are read from code. Latency and payload impact are inferred.
- **Smallest fix (existing owners):** collect pairs only for the internal committed selector. `#proof_request.read_mode` / `#pinned_origin.read_mode` already distinguish `prove_est/3` (`committed_read`). Client reads would return `{Ns, Anchor, H, []}` without issuing `read_set`. No new path or flag is needed.

### 2. Low–Medium — node-identity withdrawal drops a pending resource-selection reply, stalling the resource worker up to its 30 s budget
- **Where:**
  - `src/quod_runtime.erl:2223`: new in Phase 1, `refresh_node_executor` → `{none,_} -> stop_agents(S)`.
  - `quod_runtime.erl:2491-2494`: `stop_agents` sets `projection_waiter = none` without replying.
  - Phase 1 merged two waiters into that one slot: the source wait `{sources, From, Key, Basis}` set by `resource_selected` (`:358`), and the agent wait `{agents, ...}` (`:417`).
  - The worker's call is `gen_server:call(..., {resource_selected, ...}, infinity)` (`:3100`).
  - At HEAD, `stop_agents` was only reached from `kill_runner`, which also kills the worker.
- **Trigger:** the node identity is withdrawn (`local_node_reference()` becomes `none`) while a resource worker is waiting in `resource_selected` or `project_agents`. For example, an `agent_hosts` selection waiting for certified source progress.
- **Consequence:** the reply is never sent. The worker blocks until `runner_kill` (`RECONCILE_BUDGET_MS = 30000`) and ends as an interrupted failure. The runtime's whole serialized resource lane (physics, hosting) waits behind it. This breaks the owner-notification / no-hidden-wait rule.
- **Evidence vs inference:** code inspection only; not reproduced.
- **Smallest fix:** keep the waiter on this branch, or move the `projection_waiter` clearing from `stop_agents` into `kill_runner`. Completion is already driven elsewhere: by source notices via `finish_source_selection`, and by agent DOWN messages via `finish_agent_projection`. Alternatively, reply `{error, selection_superseded}` before clearing.

### 3. Low — the class owner lost its assignment check in `agent_key_preparation/5`
- **Where:**
  - `priv/ontologies/quod_agent.pl:69-70` is now just a call to `can_prepare_agent_key/5`.
  - At HEAD, `agent_instance.pl:42-44` also required `agent_preparation_assignment(Instance, OldHost, OldEpoch)`.
  - It is used by the recovery action `prepare_agent_key` (`quod_agent.pl:157-165`).
- **Consequence:** the "candidate key matches the current assignment" invariant for the owner's action now rests only on each storing ontology's editable ACL. The plan moved that check into the ACL for the native custody check only (plan:197-201), not for the action at `quod:agent`. The wrapper is now a redundant alias that `agent_query` also exports.
- **Evidence vs inference:** the removal is in the code. Exploitability is not shown: the shipped ACLs (`agent_recovery_policy.pl:18-22`, `quod_user.pl:165-167`, `lobby_instance.pl:79-81`) keep equivalent checks, and `assign_agent_host` re-checks `agent_hosted` at commit.
- **Smallest fix:** restore `agent_preparation_assignment(Instance, OldHost, OldEpoch)` in `agent_key_preparation/5` at `quod:agent`. Leave the native custody check calling the storing ACL as the plan decided.

### 4. Low (test obligation) — "not a space" refusal now accepts any failure
- **Where:** `test/quod_physics_tests.erl:1219` replaced `assert_reason({not_space,room}, …)` with `{failed,_}`. Production `place/3` (`quod_space.pl:139-141`) now fails silently on `space_instance(Space,space)`.
- **Consequence:** an ACL denial, a pose failure or any other failure satisfies the test, so it no longer proves the refusal came from the reclassification. The state-unchanged checks at `:1220-1223` still hold.
- **Smallest fix:** in the test, also assert that the destination fails `quod:space::space_instance(…, space)` and that no ACL/physics refusal reason is present. Adding a reason would be a production choice for you to make.

### 5. Low (documentation) — scope wire v16 is undocumented
- **Where:** `src/quod_scope_wire.erl:37` moves to v16, adds `scope_read_set` as a command and an event, and the selection is now a 5-tuple carrying the read mode (`quod_transaction_scope.erl:27-28`). `doc/multiwrite-architecture.md:145-150` still describes only v14 and its v13 boundary.
- **Fix:** one sentence in that section covering v16's selection read mode and read-set exchange.

## Inspected with no concrete defect found
- **Committed guard frame:**
  - `committed_authorization_result` publishes the session first and then uses `committed_read_state`. That hides staged `local` reads (`read_view`), forbids writes and transients, clears hooks, and records reads into the shared read set.
  - `replace_revision` now keeps the target frame's read flags, so adopting a guard invocation's revision cannot downgrade the session's current frame.
  - The read mode travels through selections into nested local and remote scopes and on re-entry (`open_checked`, `current_selection/1`). Read-only and control-proof transients are handled correctly.
- **Construction context:**
  - It lives in the overlay revision, so checkpoints and distributed savepoints restore it on rollback.
  - The `instance_of(Class, Instance)` check in `operation_authorized` ends the class-policy treatment if the membership is retracted.
  - The committed `\+ instance_of` still applies, and build inputs cannot forge it.
- **Owner following:** removing `no_follow(class_permission/3)` and `no_follow(class_requirement/3)` behaves as decided. An unqualified local class stays local. Grants and checks are tagged with their declaring owner (`operation_grants/2`, `'$quod_class_predicate'/3`).
- **Constructors:** `constructor/3` refusal works at both the local and foreign owner. Parts and bodies are removed, and the test covers the owner-body refusal (`quod_space_creation_tests.erl:85-91`).
- **Signup:** `signup_options/4` writes terms only, with the seven pins. `ontology_creation_allowed/3` variant-digest matching rejects changes and variable aliasing.
- **`quod:gui` / `quod:user` ACLs:** these grant broadly by chain head, but every `quod:gui` write path re-checks the principal and owner relation. I found no caller-shaped goal being forwarded into a storing ontology.
- **Public discovery:** discovery of `quod:user` Eidolons is now public, but source introspection stays behind root's `system_source_access`, and the updated test keeps the private source-view and predicate-list refusals.
- **Godot:** class refs and the storing ontology are carried through menu, form, draft and Eidolon flows. Draft keys include the storing ontology.
- **Signed resource selection:** keeps the original deadlines, runs in the worker rather than blocking the owner, and invalidates by precise reads.
- **Cold release preparation:** covers one atomic transaction, explicit removal of founding-injected facts, installed dependents, and leaves activation unclaimed.

## Limitations
- I did not trace every one of the 66 changed test files line by line; I sampled where assertions were removed (physics, lobby/source, space creation).
- Godot test harness changes were not reviewed in depth.
- Phase 0 changes (badmatch-style refusal-arm removals in `quod_scope_session`/`quod_prolog`) were left out as already authorized.
- Owner-side `check(…)` grants and requirements receive the storing-local `instance(Id)` without its storing identity. This fails closed and is unused by shipped classes, so it is a residual note, not a finding.
- I don't have a clean answer on whether repeated `selection_superseded` re-selection could loop when a remote scope pins below the local source view. It is a residual risk only.

