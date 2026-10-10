-ifndef(QUOD_INGRESS_LIMITS_HRL).
-define(QUOD_INGRESS_LIMITS_HRL, true).

%% Shared protocol bounds for founding, ingress, consensus, and history validation.
-define(MAX_VALIDATORS, 64).
-define(MAX_BLOCK_BYTES, (256 * 1024)).
%% New volatile admissions share the ingress population bound. It never
%% limits recovery of obligations already accepted into durable custody.
-define(MAX_INGRESS_TXS, 512).
%% Payload policy is unchanged. V2 adds three 32-byte ETF binaries (block era,
%% parent era and parent hash) plus a tuple header to the prior envelope's
%% slot/parent/time/tag allowance. This is encoding overhead, not payload space.
-define(QUOD_MAX_CANONICAL_BLOCK_BYTES,
        (?MAX_BLOCK_BYTES + 128 + 3 * (5 + 32) + 2)).
%% One canonical signed transaction is the common opaque payload accepted by
%% transaction verification and relay admission.  An operation-custody
%% submission is the deterministic `{submit, Author, Signature, Canonical}`
%% wrapper; ETF adds 122 bytes, with six bytes of representation allowance.
-define(QUOD_MAX_CANONICAL_TRANSACTION_BYTES, (256 * 1024)).
-define(QUOD_MAX_OPERATION_SUBMISSION_BYTES,
        (?QUOD_MAX_CANONICAL_TRANSACTION_BYTES + 128)).
%% Leaves deterministic room for the generated incarnation and founding committee in slot 1.
-define(MAX_GENESIS_INITIAL_DIFF_BYTES, (192 * 1024)).
%% ETF overhead for `{batch, [First]}` beyond First's standalone encoding.
%% Further elements reuse the list encoding and therefore cannot increase this
%% fixed allowance; the collector remains an O(1) incremental byte counter.
-define(BATCH_ENVELOPE_BYTES, 15).
-endif.
