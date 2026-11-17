-ifndef(QUOD_PROOF_LIMITS_HRL).
-define(QUOD_PROOF_LIMITS_HRL, true).

-include("quod_ingress_limits.hrl").
-include("quod_directory_limits.hrl").

%% Shared namespace validation allowance: Prolog's parked requests and
%% Simplex's preference for an owned parent verdict use the same setting.
-define(QUOD_VALIDATION_TTL_MS, 2000).

%% Proof populations allocate memory under the pinned Prolog material policy.
%% Remaining policies and actual identifier widths are distinguished below.

%% Coalesced change notices use an all-heads marker beyond this optimization
%% bound. It neither refuses a write nor limits an ontology's population.
-define(QUOD_MAX_CHANGED_HEADS, 1024).
%% Direct effects are deliberately singleton in the first protocol version.
%% The representation remains a bounded list so a later reviewed effect class
%% can raise the shared bound without another shape change.
-define(QUOD_MAX_DIRECT_EFFECTS, 1).
%% One node-wide foreign-history owner (doc/outdated/distributed-proof-plan.md §8). Dormant
%% histories stay as verified disk caches and are opened only when a proof or
%% follow needs them. Exact monitors and deadlines own live work;
%% there is no fixed population refusal.

%% The process-free DTX endpoint uses the complete transport envelope capacity.
-define(QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS, 30000).
-define(QUOD_DTX_ENDPOINT_REQUEST_ID_BITS, 128).

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

%% Routers retain only correlations owned by live proofs and exact deadlines;
%% they do not impose a second population quota on admitted work.

-endif.
