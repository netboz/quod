-ifndef(QUOD_CLIENT_GOAL_LIMITS_HRL).
-define(QUOD_CLIENT_GOAL_LIMITS_HRL, true).

-include("quod_directory_limits.hrl").
-include("quod_proof_limits.hrl").

%% Client rates and finite vocabulary overrides remain explicit owner options;
%% there is no built-in cumulative vocabulary quota.

%% Node-wide signed-goal routing owns only volatile, exactly monitored
%% correlations/workers. Existing deadlines, authenticated encoding and explicit
%% finite owner allowances govern the corresponding boundaries.
-define(QUOD_CLIENT_GOAL_ROUTER_TIMEOUT_MS, 60000).
-define(QUOD_CLIENT_GOAL_REQUEST_ID_BITS, 128).

-endif.
