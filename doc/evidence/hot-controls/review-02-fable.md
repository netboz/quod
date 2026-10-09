# Fable review 02: hot controls commit 61ce04b and QUIC pin 9832288

This original report is retained verbatim below. Its F1/F4 findings were
withdrawn and F2 reassessed in the [corrected addendum](review-02-addendum.md).
The [parent disposition](review-02-resolution.md) records independent checks.

Read-only review of the frozen trees under `/tmp/quod-hot-controls/review-02`. I ran no builds or tests. Line numbers refer to the committed snapshot.

## Verdict

**Not ready to deploy as committed.** One high-severity liveness defect in the task commit: a signed control request whose signing agent lives in the same namespace as the physics world is reported as `queued(Seq)` but is never delivered to the simulator. This is the configuration the shipped default `physics_client_world/1` clause selects, and no test covers it. Everything else I checked in the Quod commit is sound, including proof savepoint and backtracking release, owner and native admission, the checkpoint store/finish/edit races, and client sequence suspension. Both QUIC fixes are correct and I found no regression in them or their callers. The evidence is honestly labelled, but the full gate pass applies to the integration tree, not to HEAD alone.

## Findings

### F1. High. Same-namespace control proof releases nothing

**Where.** [quod_proof_context.erl:339](/tmp/quod-hot-controls/review-02/quod/src/quod_proof_context.erl:339) `transient/0` scans only `ctx.scopes`. The only writer of that map is `open_scope` via `get_or_open_scope` (lines 597 to 615), which is reached from `quod_ask` when `::` targets a different namespace. `start/6` at line 101 never registers the origin session. [quod_prolog.erl:4409](/tmp/quod-hot-controls/review-02/quod/src/quod_prolog.erl:4409) `finalize_request_result` therefore sees `{ok, none}` for anything staged in the origin and calls `release_transient(none, _)`, which returns `ok`, so the proof result is returned as success.

**Trigger.** The self-ask branch at [quod_ask.erl:112](/tmp/quod-hot-controls/review-02/quod/src/predicates/quod_ask.erl:112) runs the inner goal in place in the origin state. `stage_transient` succeeds there: `transient_allowed` is set by `run_pinned_origin` for control evidence, `staging` is allowed in a proof, and `enter_read_only` is only used by action predicates. So:

1. The agent ontology hosts an enabled world. The default clause at [quod_physics.pl:18](/tmp/quod-hot-controls/review-02/quod/priv/ontologies/quod_physics.pl:18) returns the signer's own ontology reference. The socket fixture `simulation_open/2` in the tests uses exactly this layout for the view.
2. The browser's `movementGoal` builds `Ns :: (current_ontology_identity(...), physics_control_input(...))` with `Ns` equal to the signing agent's namespace.
3. The proof stages the effect in the origin state, finalizes, and replies `queued(Seq)`. `quod_physics:input/7` is never called. The body does not move and the world's `inputs` map never gains a row.
4. Client consequence in `command()` at [simulation.js:114](/tmp/quod-hot-controls/review-02/quod/client/src/simulation.js:114): drive commands silently no-op. The first snap, teleport, reposition or push sets `discreteSequence`; because feedback never advances, every later command returns `false` and the client wedges without any error.

**Why tests missed it.** Every control test goes through `quod_node_actor:signed_goal`, whose principal lives in the node namespace, so `::` always opens a local scope. `foreign_signed_control_view_and_reconnect_test_` is explicitly foreign.

**Correction.** Surface the origin session's staged transient at finalization. Pass the origin `Session` from `run_pinned_origin` into `finalize_request_result` and combine `quod_proof_session:transient(Session)` with the scope result under the existing `multiple_transient_effects` error. Confirm the origin session's current revision carries the staged value at that point, as it already must for execute-mode effects. Add a regression that signs a control request with `agent_namespace => Ns` after a socket-registered view, then asserts the world's `inputs` row and a delivered frame. The `sign_fixture` helper near test line 1201 is the right seam, with `mode => control`.

### F2. Low. A stale rest checkpoint takes down every world of the identity

**Where.** [quod_physics.erl:726](/tmp/quod-hot-controls/review-02/quod/src/quod_physics.erl:726) `rest_checkpoint/5` requires the body row at the same revision, a `{recovery,_,_}` policy, and no hinge. [quod_physics.pl:574](/tmp/quod-hot-controls/review-02/quod/priv/ontologies/quod_physics.pl:574) yields `Policy = invalid` when the rest policy is missing or duplicated. Any mismatch raises inside `projection/2` at line 609, which maps every exception to `invalid_physics_projection`, and `quod_runtime` then stops all worlds at [quod_runtime.erl:252](/tmp/quod-hot-controls/review-02/quod/src/quod_runtime.erl:252).

**Trigger.** Only `physics_move_body/5` performs the atomic invalidation. An ordinary committed edit that retracts or re-asserts the chair's `physics_body` fact at a new revision, or removes its `physics_rest_policy`, leaves the `rest_v1` fact in place. The next projection fails and the whole physics selection is unavailable until an author repairs facts. The tests themselves use raw `commit(Ns, {retract, ...})` edits, so this is a reachable authoring path.

**Correction.** Have `physics_recovery_checkpoint/2` select a rest checkpoint only when its body revision and a singleton policy still exist, so the authored baseline applies and the stale fact is reported through status rather than crashing the projection. Failing that, make the failure per world with a named reason.

### F3. Low. Any refused control reply tears the client view down

**Where.** `command()` and `failed` at [simulation.js:113](/tmp/quod-hot-controls/review-02/quod/client/src/simulation.js:113). Any reply other than `ok`, including an ordinary policy failure such as an impulse above `MaxImpulse` or a revoked push grant, calls `failed()`, which clears `current` and reports `unavailable`. [World.tsx:137](/tmp/quod-hot-controls/review-02/quod/ui/src/World.tsx:137) only sets status for `unavailable` and does not reconnect, so the human must refresh manually. The invalidation-window case self-heals because the socket `refresh` still arrives and bumps the revision. Suggest distinguishing a proof failure from an uncertain transport reply: keep the view, surface the refusal as feedback, and only suspend on uncertainty, which is what the documentation already describes.

### F4. Low. Remote transient discovery cannot succeed

**Where.** [quod_scope_session.erl:212](/tmp/quod-hot-controls/review-02/quod/src/quod_scope_session.erl:212) and the `scope_transient` dispatch at line 1314. A transient staged in a scope session on another node carries a pid local to that node. Control requests are refused at ingress for non-local targets, and `release_transient` from the origin node would fail on a foreign pid anyway. I could not find a path where this clause produces a delivered input. Under the clean-break rule, either refuse control proofs that open remote scopes or drop the remote clause and its dispatch.

## Checks that passed

- **Proof savepoints and backtracking.** `transient` lives in the immutable `#lp{}` and is included in `choicepoint_checkpoint` and `choicepoint_restore`, so disjunction backtracking, negation, cut-then-fail and savepoint rollback all discard it. `stage_transient` refuses a second effect, and `control_goal` retains the first surviving answer under the ordinary savepoint. `transient_allowed` is dropped inside read-only frames and is only granted for control evidence, so read, execute and cursor proofs cannot stage. Release happens after `finalize_pinned_result` and only on success.
- **Owner admission and application.** `handle_current_call({physics_input, ...})` checks projection fence, installed control, expiry, sequence, deadline, registration, pending discrete input and the push allowance against the installed `agent_controls`. `advance_input` rechecks expiry and allowance at application. Native `push_body` bounds resulting speed and refuses hinged or stale-revision bodies. `restore_rest` sleeps the body and checks zero-displacement overlap. Restores apply only to newly installed revisions, so live poses survive redraw and checkpoint-only installs.
- **Checkpoint races.** `physics_move_body/5` removes the checkpoint and cancels the waiting activity in one transaction. `physics_rest_measurement` fences on `(Generation, Tick)`, body revision, structure and request expiry. `physics_rest_replaceable` lets a distinct request replace custody after finish, cancellation with a changed revision, or a committed rejection, and never resubmits. The runtime's `resolve` lane uses the original bytes only.
- **Navigation guard.** The atomics guard is bumped at enqueue before any drop, worlds coalesce one notice until seen, `install` suspends rows whose control or projection changed while retaining the sequence, and `project_physics` refuses superseded selections. Unhealthy and execution-failure paths stop worlds via `kill_runner`.
- **Client sequence.** Suspended rows report their retained sequence, the client resumes from the high-water mark, discrete inputs block further commands until feedback catches up, and an uncertain reply suspends without replay. The self-ask `call/1` change correctly localizes cut.
- **`projection_advanced` ownership.** The 3-tuple is published from the `quod_prolog` engine process, which is what the socket's `owners` map keys on.

## QUIC dependency fixes

- **Credit fix** at [quic_connection.erl:7827](/tmp/quod-hot-controls/review-02/quic/src/quic_connection.erl:7827). Clamping `SendAllowance` and testing `ConnectionAllowed =< 0` closes the `{case_clause, -64}` crash. The queue drain already clamps and uses the entry offset, and the wake predicate uses the reserved offset, so a wake fires only when the retry fits and the queued remainder drains first. The regression test exercises the real peer with a suspended server.
- **Listener retirement** at [quic_server_sup.erl:73](/tmp/quod-hot-controls/review-02/quic/src/quic_server_sup.erl:73) and [quic_server_registry.erl:208](/tmp/quod-hot-controls/review-02/quic/src/quic_server_registry.erl:208). `unregister_stopped` is fenced by `is_process_alive`, `DOWN` is fenced by pid equality, and `register` clears superseded monitors with flush. Quod's only production caller is `quod_quic:terminate/2` and it benefits. One pre-existing limit, not a regression: `start_server` still reads the registry before `supervisor:start_child`, so a third-party `start_server` racing an in-progress `stop_server` can still see `already_started`.

## Evidence provenance

The clean-08 freeze differs from the committed tree in 32 files and has 6 freeze-only files. None of them are in the task patch. They are the uncommitted 0.7.254 baseline: 19 system ontology files, `quod_common_primitives.erl`, the Prolog-edit client files, two docs, two test modules and the version strings. So the 3794 EUnit, 146 CT and gate pass qualify the integration tree. HEAD by itself has only the feature-only 116-test closure as evidence; the remaining suite was never run on exactly HEAD. The README discloses the baseline inclusion, which is honest. The predicates the new ontology code depends on exist in the committed tree.

The session delta of +20 production lines is accurate for the session but not for the commit. The commit itself adds roughly 876 and removes 146 lines under `src/`, adds 326 to the ontology, adds about 800 of Rust and 478 of client source. The README attributes this to the required movement foundation. Under the working agreement, the commit-level delta should also be stated.

## Coverage gaps

- No test of a control request whose signing agent namespace equals the world namespace (F1). This is the highest-value addition.
- No test of a retained rest checkpoint after a raw body-fact edit or a removed rest policy (F2).
- No test of the client's behaviour on a plain proof refusal versus an uncertain reply (F3).
- The remote `scope_transient` reply path has no test and, as far as I can see, no reachable success (F4).
- No physical chair gesture, hardware WebXR acceptance or physical host restart is claimed, and none is covered.
