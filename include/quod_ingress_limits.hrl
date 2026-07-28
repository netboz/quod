-ifndef(QUOD_INGRESS_LIMITS_HRL).
-define(QUOD_INGRESS_LIMITS_HRL, true).

%% One protocol definition for ingress admission and final block validation.
-define(MAX_BATCH_TXS, 256).
-define(MAX_BLOCK_BYTES, (256 * 1024)).
-define(BATCH_ENVELOPE_BYTES, 6).
-define(SIGNED_GROWTH_BYTES, 96).

-endif.
