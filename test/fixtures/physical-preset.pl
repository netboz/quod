% Explicitly chosen physical preset for independent physics/browser regressions.
% The fixture grants ordinary root creation and node hosting before invocation.
% This helper is never included in production account signup or setup.
physical_fixture_found(Reference) :-
    current_principal(Owner), human_user_owner(Owner),
    physical_fixture_name(Name), hosting_node(Node),
    lobby_vocabulary(Preset, Pin), Node = agent_instance_ref(NodeNs, _, _),
    transaction((
        \+ physical_fixture_reference(_),
        Preset::(current_ontology_identity(Preset, Pin), lobby_options(Owner, Node, Options)),
        quod:root::create_ontology(Name, Options, Anchor),
        NodeNs::request_ontology_hosting(Owner, Node, Name, Anchor, discoverable),
        Reference = ontology_ref(Name, Anchor),
        assertz(physical_fixture_reference(Reference)))).
account_navigation(entity_ref(Ns, Anchor, Room), Modes) :-
    current_principal(Owner), human_user_owner(Owner),
    physical_fixture_reference(ontology_ref(Ns, Anchor)),
    Ns::(current_ontology_identity(Ns, Anchor), lobby_space(Room, Modes)).
