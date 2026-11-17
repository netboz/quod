-ifndef(QUOD_PROOF_LIMITS_HRL).
-define(QUOD_PROOF_LIMITS_HRL, true).

-include("quod_ingress_limits.hrl").
-include("quod_directory_limits.hrl").

%% Shared namespace validation allowance: Prolog's parked requests and
%% Simplex's preference for an owned parent verdict use the same setting.
-define(QUOD_VALIDATION_TTL_MS, 2000).

%% Proof populations allocate memory under the pinned Prolog material policy.
%% The remaining bounds describe encoded payloads, identifiers and transport.
-define(QUOD_MAX_NESTED_GOAL_BYTES, ?QUOD_MAX_TOPLEVEL_GOAL_BYTES).

%% A complete plan must fit its enclosing durable network control payload.
-define(QUOD_MAX_PLAN_ENVELOPE_BYTES, ?QUOD_MAX_DTX_BODY_BYTES).
%% Coalesced change notices use an all-heads marker beyond this optimization
%% bound. It neither refuses a write nor limits an ontology's population.
-define(QUOD_MAX_CHANGED_HEADS, 1024).
%% Direct effects are deliberately singleton in the first protocol version.
%% The representation remains a bounded list so a later reviewed effect class
%% can raise the shared bound without another shape change.
-define(QUOD_MAX_DIRECT_EFFECTS, 1).
-define(QUOD_MAX_DIRECT_EFFECT_BYTES, 2048).
%% The committed envelope's durable top-level goal and selected result.
-define(QUOD_MAX_DURABLE_RESULT_BYTES, (16 * 1024)).
%% Durable multi-ontology control records.  The semantic body limit leaves a
%% fixed encoding margin below the block ceiling for the target-bound
%% author envelope and one-item maximum-size block framing.
-define(QUOD_MAX_DTX_BODY_BYTES, (?MAX_BLOCK_BYTES - (32 * 1024))).
%% Deterministic ETF adds exactly 28 bytes around a binary in a canonical
%% one-control payload `{batch, [{dtx, Blob}]}`. Ordinary blocks may carry more
%% controls when their combined encoded size fits the block byte ceiling.
-define(QUOD_DTX_BATCH_PAYLOAD_OVERHEAD_BYTES, 28).
-define(QUOD_MAX_DTX_CONTROL_BYTES,
        (?MAX_BLOCK_BYTES - ?QUOD_DTX_BATCH_PAYLOAD_OVERHEAD_BYTES)).

%% One node-wide foreign-history owner (doc/outdated/distributed-proof-plan.md §8). Dormant
%% histories stay as verified disk caches and are opened only when a proof or
%% follow needs them. Exact monitors, deadlines and byte bounds own live work;
%% there is no fixed population refusal.
-define(QUOD_MAX_FOREIGN_PAGE_ENTRIES, 256).

%% Process-free DTX recovery endpoint.  It may carry one optional page-format
%% acceleration sidecar beside the semantic request/response, so it shares the
%% existing foreign-page byte owner.  The transport frame remains the outer
%% bound and the sidecar is never authority.
-define(QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES,
        ?QUOD_MAX_FOREIGN_PAGE_BYTES).
-define(QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS, 30000).
-define(QUOD_DTX_ENDPOINT_REQUEST_ID_BITS, 128).

%% Hard-break scope-session wire.  The largest command carries one exact
%% operation-custody submission, the certified-read carrier accepted by the
%% transaction codec, a maximum-size agent principal, two bounded namespaces,
%% and fixed scope/ETF metadata. Derive the envelope from those shared semantic
%% owners so every accepted submission can cross a remote scope. The 1024-byte
%% fixed allowance exceeds the current fixed metadata after the principal blob.
-define(QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES,
        (?QUOD_MAX_OPERATION_SUBMISSION_BYTES +
         ?QUOD_MAX_DTX_BODY_BYTES +
         ?QUOD_MAX_TOPLEVEL_GOAL_BYTES +
         ?QUOD_SCOPE_WIRE_MAX_FIXED_METADATA_BYTES)).
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
