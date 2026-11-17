-ifndef(QUOD_CLIENT_GOAL_LIMITS_HRL).
-define(QUOD_CLIENT_GOAL_LIMITS_HRL, true).

-include("quod_directory_limits.hrl").
-include("quod_proof_limits.hrl").

%% Ordinary client traffic is governed by the existing bounded ingress and
%% worker pools, not a product-level per-agent request quota. An operator may
%% opt into a temporary rate policy through `client_rate_limits`; the client
%% boundary ships with no rate policy by default. The cumulative atom ceiling
%% remains a VM-safety bound: atoms disappear when the VM restarts, so
%% persisting this counter would make it stricter without protecting more.
-define(QUOD_CLIENT_MAX_CUMULATIVE_NEW_ATOMS, 16384).

%% Node-wide signed-goal routing owns only volatile, exactly monitored
%% correlations/workers. Population is not an admission policy; byte, term,
%% deadline and VM-safety bounds remain at the untrusted boundary.
-define(QUOD_CLIENT_GOAL_ROUTER_TIMEOUT_MS, 60000).
-define(QUOD_CLIENT_GOAL_REQUEST_ID_BITS, 128).

-endif.
