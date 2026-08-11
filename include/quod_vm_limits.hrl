-ifndef(QUOD_VM_LIMITS_HRL).
-define(QUOD_VM_LIMITS_HRL, true).

%% Keep enough atom-table capacity for the VM and loaded code after a caller
%% vocabulary source has been refused. This is a safety reserve, not a quota.
-define(QUOD_ATOM_SAFETY_MARGIN, 100000).

%% One authenticated, ontology-owned material envelope may introduce only this
%% many previously unknown Prolog symbols.  Transaction relay and durable local
%% plans share the same materializer, so neither path can drift to a different
%% atom-allocation policy.
-define(QUOD_MAX_NEW_MATERIAL_ATOMS, 64).

-endif.
