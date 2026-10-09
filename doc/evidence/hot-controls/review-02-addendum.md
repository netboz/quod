# Addendum to review 02: reassessment of F1 to F4

Same frozen snapshot, read-only, no builds or tests.

## Corrected verdict

**F1 and F4 are withdrawn.** I missed the origin scope registration in `run_pinned_origin` and misread the local scope-session handle as a cross-node handle. With those corrections, I found no blocking defect in the task commit or the QUIC pin. What remains is one untested production path (same-namespace control), one actionable client behaviour (F3), and the evidence-provenance note from the main report, which stands unchanged.

## F1: withdrawn

[quod_prolog.erl:4374](/tmp/quod-hot-controls/review-02/quod/src/quod_prolog.erl:4374) calls `quod_proof_context:get_or_open_scope(OriginIdentity, ...)` before `RunFun` and finalization. The opener starts the origin session and returns a `{local_scope, ScopeId, Ns, Anchor, Applied, Session}` handle, and `open_scope` inserts it into `ctx.scopes`. So `transient/0` at line 339 does visit the origin session through the `transient({local_scope, ..., Session})` clause at [quod_scope_session.erl:210](/tmp/quod-hot-controls/review-02/quod/src/quod_scope_session.erl:210). My statement that the origin is never in the scope map was wrong, and adding `Session` separately would indeed double-count and trip `multiple_transient_effects`.

I also checked the one remaining way the self-ask path could still lose the effect: whether the origin session's current revision carries the staged value at finalization. The origin proof drives the same `quod_proof_session` open/next/finish machinery as a scope worker (quod_prolog.erl:5420 to 5514), and `finish_step` installs each step's state into `current`, which is what `transient(Handle)` reads at line 393. The foreign-world tests already exercise that same session module for the worker side. I see no later removal or revision problem.

**Exact remaining evidence gap.** No test sends a `control`-mode request whose signing agent namespace equals the world namespace. All control tests sign through `quod_node_actor:signed_goal` from the node namespace, so the in-place `call/1` branch at [quod_ask.erl:112](/tmp/quod-hot-controls/review-02/quod/src/predicates/quod_ask.erl:112) is never the staging site in any control test. The parent's planned same-namespace production-seam coverage is the right closure. The assertions that matter are: the world's `inputs` row appears for the principal, a frame is delivered, and a second staged command in one proof still fails whole.

## F4: withdrawn

I conflated the two handle shapes. `open_local_scope` at [quod_ask.erl:334](/tmp/quod-hot-controls/review-02/quod/src/predicates/quod_ask.erl:334) calls the target engine's `scope_open`, and the engine returns the local handle produced by `quod_scope_session:start/9`, which is `{quod_scope_session, Pid, ScopeId, ProofId, SessionRef, Ns, Anchor}` per the `local_handle()` type at line 53. That is a same-node worker for another cohosted namespace. The `transient({quod_scope_session, ...})` clause at line 212 and the `scope_transient` dispatch at line 1314 are therefore exactly the path every existing foreign-world control test takes, including `signed_control_releases_only_successful_proof_test_`. The clause is live, its reply never crosses a node boundary, and the pid it carries is local. Nothing to remove.

Cross-node origins hold `{remote_scope, ...}` handles, which fall to the `transient(_) -> {error, transient_scope_unavailable}` clause. Combined with the ingress refusal of non-local control targets, that is the correct fail-closed behaviour, not dead code.

## F2: reassessed as consistent with documented behaviour

The documented contract is that unsupported or invalid checkpoint declarations fail installation visibly with no silent baseline fallback. A raw authored edit that retracts or re-revisions a `physics_body` fact, or removes the rest policy, bypasses the supported `physics_move_body/5` action and leaves an invalid authored projection. Mapping that to `invalid_physics_projection` and stopping the worlds is the documented invalid-state outcome, and silently dropping the checkpoint would be exactly the hidden fallback the working agreement forbids. I downgrade F2 to informational. The only optional improvement is a more specific failure reason than `invalid_physics_projection` so an author can see which checkpoint or policy is inconsistent, and that is not required for this commit.

## F3: stands

A definite proof refusal (`fail`, for example an impulse above `MaxImpulse` or a revoked push grant) and an uncertain transport reply are both routed to `failed()` at [simulation.js:113](/tmp/quod-hot-controls/review-02/quod/client/src/simulation.js:113), and `unavailable` in [World.tsx:137](/tmp/quod-hot-controls/review-02/quod/ui/src/World.tsx:137) does not reconnect. The documented client contract suspends on uncertainty only. The parent is checking client handling, which is the right disposition.

## Unchanged from the main report

The QUIC credit and listener-lifecycle assessments stand. The evidence note stands: the full gate pass qualifies the integration tree with the uncommitted 0.7.254 baseline, and HEAD alone is covered by the feature-only 116-test closure. The commit-level line delta should be reported alongside the session delta.
