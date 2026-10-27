%% New material is admitted by the ontology whose proof owns the transition.
%% Root owns founding; each target owns its sealed plans. An override is an
%% ordinary ontology fact, governed by that ontology's existing write policy.
%% The engine selects from the pinned committed view and captures its reads.
%% A policy-changing plan must leave a valid final policy. Zero is valid and
%% can close the write lane; no implicit maintenance allowance overrides it.
material_limit(Kind, Resource, Limit) :-
    material_limit_override(Kind, Resource, Limit).
material_limit(Kind, Resource, Limit) :-
    material_default_limit(Kind, Resource, Limit),
    \+ material_limit_override(Kind, Resource, _).

%% Unlimited allocation remains subject to the complete enclosing encoding
%% and VM bounds. Symbol counts include known names as well as new names.
material_default_limit(founding, canonical_bytes, unlimited).
material_default_limit(founding, symbols, 2048).
material_default_limit(plan, canonical_bytes, unlimited).
material_default_limit(plan, symbols, 2048).
material_default_limit(plan, operations, 1024).
material_default_limit(plan, reads, 1024).

%% Execution memory is an allocation policy, not an encoding constraint.
%% Each proof selects its pinned committed ontology's allowance. Historical
%% verification does not re-admit already accepted material under today's policy.
material_default_limit(proof, heap_bytes, unlimited).
