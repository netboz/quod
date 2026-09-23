%% Explicit delegation by this node's own ontology. The runtime supplies the
%% requesting ontology's installed identity; a hosting declaration alone grants
%% no node signing authority. Grant and consequence belong to one signed proof.
node_authorized_goal(Source, Anchor, Goal) :-
    can_execute_for(Source, Anchor, Goal),
    Source::(current_ontology_identity(Source, Anchor), call(Goal)).
