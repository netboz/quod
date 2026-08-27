-ifndef(QUOD_CLIENT_GOAL_LIMITS_HRL).
-define(QUOD_CLIENT_GOAL_LIMITS_HRL, true).

-include("quod_directory_limits.hrl").
-include("quod_proof_limits.hrl").

%% Signed agent references and goals share the existing durable top-level-term
%% bound. Both parsed durable blobs are checked independently after parsing.
-define(QUOD_CLIENT_GOAL_TEXT_BYTES, ?QUOD_MAX_TOPLEVEL_GOAL_BYTES).
-define(QUOD_CLIENT_AGENT_INSTANCE_TEXT_BYTES, ?QUOD_MAX_TOPLEVEL_GOAL_BYTES).
-define(QUOD_CLIENT_GOAL_MAX_TOKENS, 2048).
-define(QUOD_CLIENT_GOAL_MAX_NUMBER_CHARS, 1024).
-define(QUOD_CLIENT_GOAL_MAX_SYMBOL_BYTES, 1024).

%% Ordinary client traffic is governed by the existing bounded ingress and
%% worker pools, not a product-level per-agent request quota. An operator may
%% opt into a temporary rate policy through `client_rate_limits`; the client
%% boundary ships with no rate policy by default. The cumulative atom ceiling
%% remains a VM-safety bound: atoms disappear when the VM restarts, so
%% persisting this counter would make it stricter without protecting more.
-define(QUOD_CLIENT_MAX_CUMULATIVE_NEW_ATOMS, 16384).

%% domain+NUL, four 32-byte values, agent namespace length/body, instance-text
%% length/body, mode, parser, deadline, goal length/body. This is a decode
%% admission bound, not an approximation used by the encoder.
-define(QUOD_CLIENT_GOAL_REQUEST_BYTES,
        (32 + (4 * 32) + 2 + ?DIRECTORY_MAX_NAMESPACE_BYTES +
         4 + ?QUOD_CLIENT_AGENT_INSTANCE_TEXT_BYTES +
         1 + 1 + 8 + 4 + ?QUOD_CLIENT_GOAL_TEXT_BYTES)).

%% One complete signed-client reply is deliberately a single bounded frame.
%% Large nondeterministic reads use the existing cursor instead of growing a
%% second multi-frame result stream.  The envelope allowance covers the fixed
%% endpoint wrapper, trace/correlation fields, and deterministic ETF framing.
-define(QUOD_CLIENT_GOAL_MAX_REPLY_BYTES, (512 * 1024)).
-define(QUOD_CLIENT_GOAL_MAX_ENVELOPE_BYTES,
        (?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES + (16 * 1024))).

%% Node-wide signed-goal routing owns only volatile, exactly monitored
%% correlations/workers. Population is not an admission policy; byte, term,
%% deadline and VM-safety bounds remain at the untrusted boundary.
-define(QUOD_CLIENT_GOAL_ROUTER_TIMEOUT_MS, 60000).
-define(QUOD_CLIENT_GOAL_REQUEST_ID_BITS, 128).

-endif.
