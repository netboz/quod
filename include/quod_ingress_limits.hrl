-ifndef(QUOD_INGRESS_LIMITS_HRL).
-define(QUOD_INGRESS_LIMITS_HRL, true).

-include("quod_transport_limits.hrl").

%% ETF overhead for `{batch, [First]}` beyond First's standalone encoding.
%% This accounts bytes; it is not an admission quota.
-define(BATCH_ENVELOPE_BYTES, 15).
-endif.
