-ifndef(QUOD_INGRESS_LIMITS_HRL).
-define(QUOD_INGRESS_LIMITS_HRL, true).

-include("quod_transport_limits.hrl").

%% Encoding capacity, shared by founding, ingress and historical validation.
%% A scope envelope carries two material blobs beside a principal and fixed
%% metadata. History pages also carry a material block twice, with its full
%% certificate and an empty finalizing carrier. Use the tighter carrier bound;
%% authored material_policy.pl allowances govern admission below this ceiling.
-define(QUOD_MAX_TOPLEVEL_GOAL_BYTES, (128 * 1024)).
-define(QUOD_SCOPE_WIRE_MAX_FIXED_METADATA_BYTES, 1024).
-define(MAX_VALIDATORS, 64).
%% ETF signature rows cost 108 bytes; 1024 covers entry, empty-carrier and page
%% metadata. The maximal full-committee transfer test checks this envelope.
-define(QUOD_COMPACT_HISTORY_OVERHEAD_BYTES, (?MAX_VALIDATORS * 108 + 1024)).
-define(MAX_BLOCK_BYTES,
        min((?QUOD_TRANSPORT_MAX_FRAME_BYTES - ?QUOD_MAX_TOPLEVEL_GOAL_BYTES -
             ?QUOD_SCOPE_WIRE_MAX_FIXED_METADATA_BYTES - 128) div 2,
            (?QUOD_MAX_FOREIGN_PAGE_BYTES - ?QUOD_COMPACT_HISTORY_OVERHEAD_BYTES) div 2)).
%% New volatile admissions share the ingress population bound. It never
%% limits recovery of obligations already accepted into durable custody.
-define(MAX_INGRESS_TXS, 512).
%% V2 adds three 32-byte ETF binaries (block era,
%% parent era and parent hash) plus a tuple header to the prior envelope's
%% slot/parent/time/tag allowance. This is encoding overhead, not payload space.
-define(QUOD_MAX_CANONICAL_BLOCK_BYTES,
        (?MAX_BLOCK_BYTES + 128 + 3 * (5 + 32) + 2)).
%% One canonical signed transaction is the common opaque payload accepted by
%% transaction verification and relay admission.  An operation-custody
%% submission is the deterministic `{submit, Author, Signature, Canonical}`
%% wrapper; ETF adds 122 bytes, with six bytes of representation allowance.
-define(QUOD_MAX_CANONICAL_TRANSACTION_BYTES,
        (?MAX_BLOCK_BYTES - 128 - ?BATCH_ENVELOPE_BYTES)).
-define(QUOD_MAX_OPERATION_SUBMISSION_BYTES,
        (?QUOD_MAX_CANONICAL_TRANSACTION_BYTES + 128)).
%% ETF overhead for `{batch, [First]}` beyond First's standalone encoding.
%% Further elements reuse the list encoding and therefore cannot increase this
%% fixed allowance; the collector remains an O(1) incremental byte counter.
-define(BATCH_ENVELOPE_BYTES, 15).
-endif.
