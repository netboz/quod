%% Personal lobby behaviour. Founding supplies lobby_owner/1, exact vocabulary
%% references and instance_of(prolog_console, Device); no user registry here.
%% Found with quod_agent_predicates for proof-bound identity checks.
can_invoke(_, Principal, _, _) :- lobby_owner(Principal).

lobby_view(Mode, Scene) :-
    findall(Device, instance_of(prolog_console, Device), [Console]),
    current_ontology_identity(Namespace, Anchor),
    lobby_vocabulary(LobbyNamespace, LobbyAnchor),
    LobbyNamespace::(current_ontology_identity(LobbyNamespace, LobbyAnchor),
                    lobby_recipe(Mode, depicts(Namespace, Anchor, Console), Parts)),
    presentation_vocabulary(PresentationNamespace, PresentationAnchor),
    PresentationNamespace::(current_ontology_identity(PresentationNamespace, PresentationAnchor),
                           model(Parts, Scene)).

lobby_menu(Device, Entries) :-
    instance_of(prolog_console, Device),
    lobby_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                device_menu(prolog_console, Entries)).

lobby_workspace(Device, View) :-
    instance_of(prolog_console, Device),
    gui_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                gui_view(proof_console, View)).
