-ifndef(QUOD_PROOF_LIMITS_HRL).
-define(QUOD_PROOF_LIMITS_HRL, true).

%% One source of truth for the bounded distributed-proof worker state.
-define(QUOD_MAX_ACTIVE_PROOF_DEPTH, 8).
-define(QUOD_MAX_SCOPES_PER_PROOF, 8).
-define(QUOD_MAX_INVOCATIONS_PER_SCOPE, 64).
%% Every retained invocation may have one origin-side continuation proxy.
-define(QUOD_MAX_PROXIES_PER_PROOF,
        (?QUOD_MAX_SCOPES_PER_PROOF * ?QUOD_MAX_INVOCATIONS_PER_SCOPE)).
-define(QUOD_MAX_ANSWERS_PER_INVOCATION, 10000).
-define(QUOD_MAX_NESTED_GOAL_BYTES, 8192).
-define(QUOD_MAX_PROOF_ANSWER_BYTES, 65536).
-define(QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF, 1024).

%% Sealing bounds (distributed-proof-plan §4.2). The transcript charge is taken
%% BEFORE a goal runs; the plan bounds are enforced at seal time and again on
%% every decode of a plan blob.
-define(QUOD_MAX_SCOPE_TRANSCRIPT_BYTES, (12 * 1024)).
-define(QUOD_MAX_PLAN_ENVELOPE_BYTES, (24 * 1024)).
-define(QUOD_MAX_PLAN_DIFF_OPS, 1024).
-define(QUOD_MAX_PLAN_READ_FUNCTORS, 1024).
%% Defined in bytes for operator-facing clarity; the sole worker spawn seam
%% converts it to this VM's heap words before installing the hard kill limit.
-define(QUOD_SCOPE_WORKER_MAX_HEAP_BYTES, (64 * 1024 * 1024)).

%% Hard-break scope-session wire.  These values are shared by producers,
%% decoders, admission checks, and boundary tests; do not duplicate them in
%% the transport or router.
-define(QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES, (128 * 1024)).
-define(QUOD_SCOPE_COMMAND_TIMEOUT_MS, 30000).
%% Reserve part of the origin-owned absolute proof budget for a target-authored
%% terminal event to cross the network.  This is the maximum reserve: short
%% budgets scale it down so the target still receives useful execution time.
%% The reserve is delivery time, not another timeout.
-define(QUOD_SCOPE_TIMEOUT_REPLY_GRACE_MS, 1000).
-define(QUOD_SCOPE_WIRE_KEY_BITS, 256).
-define(QUOD_SCOPE_WIRE_PROOF_ID_BITS, 256).
-define(QUOD_SCOPE_WIRE_OPAQUE_ID_BITS, 128).
-define(QUOD_SCOPE_WIRE_MAX_UINT64, 16#FFFFFFFFFFFFFFFF).

%% One node-local origin router is the bounded correlation registry for remote
%% scopes.  Pending command entries are nested under those scopes and inherit
%% the invocation bound, so no independent unbounded request table exists.
-define(QUOD_MAX_ROUTER_SCOPES, 512).
-define(QUOD_MAX_ROUTER_SCOPES_PER_OWNER, ?QUOD_MAX_SCOPES_PER_PROOF).
-define(QUOD_MAX_ROUTER_SCOPES_PER_PEER, 16).
-define(QUOD_MAX_ROUTER_PENDING_PER_SCOPE,
        ?QUOD_MAX_INVOCATIONS_PER_SCOPE).

%% Target-side authenticated scope-open token buckets. The table and every
%% bucket are bounded before goal decoding, worker spawn, or monitor creation.
-define(QUOD_SCOPE_OPEN_RATE_PER_SECOND, 32).
-define(QUOD_SCOPE_OPEN_RATE_BURST, 32).
-define(QUOD_SCOPE_OPEN_MAX_BUCKETS, 1024).
-define(QUOD_SCOPE_OPEN_BUCKET_IDLE_MS, 60000).

-endif.
