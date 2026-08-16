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

%% Ordinary client traffic is governed by the existing bounded ingress and
%% worker pools, not a product-level per-user request quota. An operator may
%% opt into a temporary rate policy through `client_rate_limits`; the client
%% boundary ships with no rate policy by default. The cumulative atom ceiling
%% remains a VM-safety bound: atoms disappear when the VM restarts, so
%% persisting this counter would make it stricter without protecting more.
-define(QUOD_CLIENT_MAX_CUMULATIVE_NEW_ATOMS, 16384).

%% domain+NUL, four 32-byte values, namespace length/body, mode, parser,
%% deadline, goal length/body. This is a decode admission bound, not an
%% approximation used by the encoder.
-define(QUOD_CLIENT_GOAL_REQUEST_BYTES,
        (32 + (4 * 32) + 2 + ?DIRECTORY_MAX_NAMESPACE_BYTES +
         1 + 1 + 8 + 4 + ?QUOD_CLIENT_GOAL_TEXT_BYTES)).

%% One complete signed-client reply is deliberately a single bounded frame.
%% Large nondeterministic reads use the existing cursor instead of growing a
%% second multi-frame result stream.  The envelope allowance covers the fixed
%% endpoint wrapper, trace/correlation fields, and deterministic ETF framing.
-define(QUOD_CLIENT_GOAL_MAX_REPLY_BYTES, (512 * 1024)).
-define(QUOD_CLIENT_GOAL_MAX_ENVELOPE_BYTES,
        (?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES + (16 * 1024))).

%% Node-wide signed-goal routing owns only volatile correlations/workers.  The
%% target proof engine and cursor owner retain their existing independent caps.
-define(QUOD_CLIENT_GOAL_MAX_CORRELATIONS, 256).
-define(QUOD_CLIENT_GOAL_MAX_INBOUND_WORKERS, 64).
-define(QUOD_CLIENT_GOAL_MAX_INBOUND_PER_FORWARDER, 8).
-define(QUOD_CLIENT_GOAL_ROUTER_TIMEOUT_MS, 60000).
-define(QUOD_CLIENT_GOAL_REQUEST_ID_BITS, 128).

-endif.
