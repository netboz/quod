-ifndef(QUOD_DIRECTORY_LIMITS_HRL).
-define(QUOD_DIRECTORY_LIMITS_HRL, true).

%% One auditable definition for signed records, ETS admission and resync state.
-define(DIRECTORY_MAX_NAMESPACES, 32).
-define(DIRECTORY_MAX_NAMESPACE_BYTES, 255).
-define(DIRECTORY_ROUTE_TTL_MS, 30000).
-define(DIRECTORY_MAX_ROUTES_PER_NS, 8).
-define(DIRECTORY_MAX_ROUTES, 2048).
-define(DIRECTORY_MAX_RESYNC_RECORDS, 128).
-define(DIRECTORY_MAX_RESYNC_SESSIONS, 2048).

-endif.
