-ifndef(QUOD_VM_LIMITS_HRL).
-define(QUOD_VM_LIMITS_HRL, true).

%% Keep enough atom-table capacity for the VM and loaded code after a caller
%% vocabulary source has been refused. This is a safety reserve, not a quota.
-define(QUOD_ATOM_SAFETY_MARGIN, 100000).

%% Existing untrusted client goal/reference syntax allowance. Durable material
%% uses the owning ontology's material_policy.pl admission instead; accepted
%% history must remain materializable when current policy is tightened.
-define(QUOD_MAX_NEW_MATERIAL_ATOMS, 512).

-endif.
