%% Human-user instance behaviour. Founding supplies the local instance/key,
%% exact lobby vocabulary and one pending personal-lobby requirement.
%% Found with quod_agent_predicates; identity is the signed ontology instance.
can_invoke(_, Principal, _, _) :- human_user_owner(Principal).

human_user_owner(agent_instance_ref(Namespace, Anchor, Instance)) :-
    current_ontology_identity(Namespace, Anchor),
    instance_of(human_user, Instance).

lobby_reference(Reference) :-
    current_principal(Owner),
    human_user_owner(Owner),
    Owner = agent_instance_ref(_, _, Instance),
    lobby_provisioning(Instance, linked(Reference)).

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
        retract(lobby_provisioning(Instance, pending(Name))),
        lobby_vocabulary(Namespace, Anchor),
        Namespace::(current_ontology_identity(Namespace, Anchor),
                    lobby_options(Owner, Options)),
        quod:root::create_ontology(Name, Options, CreatedAnchor),
        assertz(lobby_provisioning(Instance,
            linked(ontology_ref(Name, CreatedAnchor)))),
        acknowledge_user_signup(Owner))).

%% A pre-existing independently founded human may have no signup receipt.
acknowledge_user_signup(Owner) :-
    (signup_origin(Namespace, Anchor, Token) ->
        Namespace::(current_ontology_identity(Namespace, Anchor),
                    acknowledge_signup(Token, Owner)),
        retract(signup_origin(Namespace, Anchor, Token))
    ; true).
