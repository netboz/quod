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

-endif.
