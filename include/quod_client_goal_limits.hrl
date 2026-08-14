-ifndef(QUOD_CLIENT_GOAL_LIMITS_HRL).
-define(QUOD_CLIENT_GOAL_LIMITS_HRL, true).

-include("quod_directory_limits.hrl").
-include("quod_proof_limits.hrl").

%% Signed-goal v1 is deliberately close to the existing durable top-level goal
%% bound. The parsed durable blob is checked independently after parsing.
-define(QUOD_CLIENT_GOAL_TEXT_BYTES, ?QUOD_MAX_TOPLEVEL_GOAL_BYTES).
-define(QUOD_CLIENT_GOAL_MAX_TOKENS, 2048).
-define(QUOD_CLIENT_GOAL_MAX_NUMBER_CHARS, 1024).
-define(QUOD_CLIENT_GOAL_MAX_SYMBOL_BYTES, 1024).

%% The authenticated browser boundary admits ordinary goals and vocabulary
%% growth under separate budgets.  A caller that uses no new callable symbols
%% pays only the request budget.  The cumulative ceiling is per VM lifetime:
%% atoms disappear when the VM restarts, so persisting this counter would make
%% the limit stricter without protecting any additional state.
-define(QUOD_CLIENT_GOAL_RATE_WINDOW_MS, 60000).
-define(QUOD_CLIENT_GOAL_RATE_TOTAL, 1024).
-define(QUOD_CLIENT_GOAL_RATE_PER_USER, 60).
-define(QUOD_CLIENT_GOAL_RATE_PER_PEER, 120).
-define(QUOD_CLIENT_GOAL_RATE_KEYS, 512).
-define(QUOD_CLIENT_SYMBOL_RATE_TOTAL, 4096).
-define(QUOD_CLIENT_SYMBOL_RATE_PER_USER, 256).
-define(QUOD_CLIENT_SYMBOL_RATE_PER_PEER, 512).
-define(QUOD_CLIENT_MAX_CUMULATIVE_NEW_ATOMS, 16384).

%% domain+NUL, four 32-byte values, namespace length/body, mode, parser,
%% deadline, goal length/body. This is a decode admission bound, not an
%% approximation used by the encoder.
-define(QUOD_CLIENT_GOAL_REQUEST_BYTES,
        (32 + (4 * 32) + 2 + ?DIRECTORY_MAX_NAMESPACE_BYTES +
         1 + 1 + 8 + 4 + ?QUOD_CLIENT_GOAL_TEXT_BYTES)).

-endif.
