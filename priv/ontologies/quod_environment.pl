%% Shared environment concepts. Worlds and personal lobbies own instances;
%% this ontology owns the class and attribute vocabulary only.
acl_sovereign(quod:environment).

can_invoke(Goal, _, _, _) :- environment_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- environment_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

environment_query(isa(_, _)).
environment_query(have_attribute(_, _, _)).

isa(environment, thing).
isa(sky_sphere, environment).

have_attribute(sky_sphere, panorama, atom).
have_attribute(sky_sphere, diameter, millimetres).
have_attribute(sky_sphere, rotation, degrees).
have_attribute(sky_sphere, brightness, permille).
have_attribute(sky_sphere, tint, colour).
