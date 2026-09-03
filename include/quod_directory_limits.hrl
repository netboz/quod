-ifndef(QUOD_DIRECTORY_LIMITS_HRL).
-define(QUOD_DIRECTORY_LIMITS_HRL, true).

%% Wire-shape and liveness bounds only; there are no directory population caps.
-define(DIRECTORY_MAX_NAMESPACE_BYTES, 255).
-define(DIRECTORY_ROUTE_TTL_MS, 30000).

-endif.
