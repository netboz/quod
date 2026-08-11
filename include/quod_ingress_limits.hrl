-ifndef(QUOD_INGRESS_LIMITS_HRL).
-define(QUOD_INGRESS_LIMITS_HRL, true).

%% Shared protocol bounds for founding, ingress, consensus, and history validation.
-define(MAX_VALIDATORS, 64).
-define(MAX_BATCH_TXS, 256).
-define(MAX_BLOCK_BYTES, (256 * 1024)).
%% Leaves deterministic room for the generated incarnation and founding committee in slot 1.
-define(MAX_GENESIS_INITIAL_DIFF_BYTES, (192 * 1024)).
%% ETF overhead for `{batch, [First]}` beyond First's standalone encoding.
%% Further elements reuse the list encoding and therefore cannot increase this
%% fixed allowance; the collector remains an O(1) incremental byte counter.
-define(BATCH_ENVELOPE_BYTES, 15).
-define(SIGNED_GROWTH_BYTES, 96).

-endif.
