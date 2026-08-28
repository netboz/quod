-ifndef(QUOD_PROOF_LIMITS_HRL).
-define(QUOD_PROOF_LIMITS_HRL, true).

-include("quod_ingress_limits.hrl").
-include("quod_directory_limits.hrl").

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
%% Direct effects are deliberately singleton in the first protocol version.
%% The representation remains a bounded list so a later reviewed effect class
%% can raise the shared bound without another shape change.
-define(QUOD_MAX_DIRECT_EFFECTS, 1).
-define(QUOD_MAX_DIRECT_EFFECT_BYTES, 2048).
-define(QUOD_MAX_PREPARED_EFFECT_BYTES, (256 * 1024)).
%% The committed envelope's durable top-level goal and selected result.
-define(QUOD_MAX_TOPLEVEL_GOAL_BYTES, (8 * 1024)).
-define(QUOD_MAX_DURABLE_RESULT_BYTES, (16 * 1024)).
%% Durable multi-ontology control records.  The semantic body limit leaves a
%% fixed margin below the existing 256 KiB block ceiling for the target-bound
%% author envelope and one-item maximum-size block framing. A group has the same
%% participant ceiling as the proof that produced it.
-define(QUOD_MAX_DTX_PARTICIPANTS, ?QUOD_MAX_SCOPES_PER_PROOF).
-define(QUOD_MAX_DTX_BODY_BYTES, (224 * 1024)).
%% Deterministic ETF adds exactly 28 bytes around a binary in a canonical
%% one-control payload `{batch, [{dtx, Blob}]}`. Ordinary blocks may carry more
%% controls when their combined encoded size fits the block byte ceiling.
-define(QUOD_DTX_BATCH_PAYLOAD_OVERHEAD_BYTES, 28).
-define(QUOD_MAX_DTX_CONTROL_BYTES,
        (?MAX_BLOCK_BYTES - ?QUOD_DTX_BATCH_PAYLOAD_OVERHEAD_BYTES)).

%% One node-wide foreign-history owner (distributed-proof-plan §8). Dormant
%% histories stay as verified disk caches and are opened only when a proof or
%% follow needs them. Exact monitors, deadlines and byte bounds own live work;
%% there is no fixed population refusal.
-define(QUOD_MAX_FOREIGN_PAGE_ENTRIES, 256).
-define(QUOD_MAX_FOREIGN_PAGE_BYTES, (900 * 1024)).

%% Process-free DTX recovery endpoint.  It may carry one optional page-format
%% acceleration sidecar beside the semantic request/response, so it shares the
%% existing foreign-page byte owner.  The transport frame remains the outer
%% bound and the sidecar is never authority.
-define(QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES,
        ?QUOD_MAX_FOREIGN_PAGE_BYTES).
-define(QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS, 30000).
-define(QUOD_DTX_ENDPOINT_REQUEST_ID_BITS, 128).

%% Defined in bytes for operator-facing clarity; the sole worker spawn seam
%% converts it to this VM's heap words before installing the hard kill limit.
-define(QUOD_SCOPE_WORKER_MAX_HEAP_BYTES, (64 * 1024 * 1024)).

%% Hard-break scope-session wire.  The largest command carries one exact
%% operation-custody submission plus a maximum-size agent principal, two
%% bounded namespaces, and fixed scope/ETF metadata.  Derive the envelope from
%% those shared semantic owners so every submission accepted by the transaction
%% codec can cross a remote scope.  The 1024-byte fixed allowance exceeds the
%% current 920-byte maximum after the principal blob.
-define(QUOD_SCOPE_WIRE_MAX_FIXED_METADATA_BYTES, 1024).
-define(QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES,
        (?QUOD_MAX_OPERATION_SUBMISSION_BYTES +
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

%% Router ownership follows the proof-shape bounds.  There is deliberately no
%% node-wide or peer-wide population quota: those rejected otherwise valid
%% concurrent proofs based on arrival timing.  Pending command entries are
%% nested under a scope and inherit the invocation bound.
-define(QUOD_MAX_ROUTER_SCOPES_PER_OWNER, ?QUOD_MAX_SCOPES_PER_PROOF).
-define(QUOD_MAX_ROUTER_PENDING_PER_SCOPE,
        ?QUOD_MAX_INVOCATIONS_PER_SCOPE).

-endif.
