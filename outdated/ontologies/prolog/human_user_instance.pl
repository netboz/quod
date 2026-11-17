%% Human-user instance behaviour, composed with gui_hud.pl. Founding supplies the local instance/key,
%% exact lobby vocabulary and one pending personal-lobby requirement.
%% Found with quod_agent_predicates; identity is the signed ontology instance.
%% The signed boundary verifies the principal's exact anchor. Admission must
%% re-prove from local facts without invoking an external predicate.
can_invoke(_, agent_instance_ref(Namespace, _, Instance), _, Namespace) :-
    instance_of(human_user, Instance).

human_user_owner(agent_instance_ref(Namespace, Anchor, Instance)) :-
    current_ontology_identity(Namespace, Anchor),
    instance_of(human_user, Instance).

ontology_source_mode(editable) :- current_principal(Owner), human_user_owner(Owner).

lobby_reference(Reference) :-
    current_principal(Owner),
    human_user_owner(Owner),
    Owner = agent_instance_ref(_, _, Instance),
    lobby_provisioning(Instance, linked(Reference)).

lobby_navigation(entity_ref(Ns, Anchor, Space), Modes) :-
    findall(Reference, lobby_reference(Reference), [ontology_ref(Ns, Anchor)]),
    Ns::(current_ontology_identity(Ns, Anchor), lobby_space(Space, Modes)).

action(provision_lobby(Instance),
       [current_principal(Owner), human_user_owner(Owner),
        Owner = agent_instance_ref(_, _, Instance),
        lobby_provisioning(Instance, pending(_))],
       lobby_provisioning(Instance, linked(_))).

%% The source guard, resulting exact reference and root's prepared creation
%% effect are one ordinary atomic transition. Linked means admitted creation;
%% temporary unavailability never selects a second namespace or anchor.
provision_lobby(Instance) :-
    current_principal(Owner),
    human_user_owner(Owner),
    Owner = agent_instance_ref(_, _, Instance),
    transaction((
        lobby_provisioning(Instance, pending(Name)),
        lobby_vocabulary(Namespace, Anchor),
        hosting_node(Node),
        Namespace::(current_ontology_identity(Namespace, Anchor),
                    lobby_options(Owner, Node, Options)),
        quod:root::create_ontology(Name, Options, CreatedAnchor),
        retract(lobby_provisioning(Instance, pending(Name))),
        assertz(lobby_provisioning(Instance,
            linked(ontology_ref(Name, CreatedAnchor)))),
        Node = agent_instance_ref(NodeNamespace, _, _),
        NodeNamespace::request_ontology_hosting(Owner, Node, Name, CreatedAnchor, discoverable),
        acknowledge_user_signup(Owner))).

%% A pre-existing independently founded human may have no signup receipt.
acknowledge_user_signup(Owner) :-
    (signup_origin(Namespace, Anchor, Token) ->
        Namespace::(current_ontology_identity(Namespace, Anchor),
                    acknowledge_signup(Token, Owner)),
        retract(signup_origin(Namespace, Anchor, Token))
    ; true).

%% Authored capacity for the human's composed question HUD.
gui_pending_allowance(Instance,8) :- instance_of(human_user,Instance).
