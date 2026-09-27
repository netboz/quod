%% Personal lobby behaviour. Founding supplies lobby_owner/1, exact vocabulary
%% references and instance_of(prolog_console, Device); no user registry here.
%% Found with quod_agent_predicates for proof-bound identity checks.
can_invoke(_, Principal, _, _) :- lobby_owner(Principal).

lobby_view(Mode, Scene) :-
    current_ontology_identity(Namespace, Anchor),
    lobby_sky(Sky),
    findall(Entity, lobby_device(personal_lobby, Entity), Entities),
    placed_devices(Entities, Devices),
    lobby_vocabulary(LobbyNamespace, LobbyAnchor),
    LobbyNamespace::(current_ontology_identity(LobbyNamespace, LobbyAnchor),
                    lobby_recipe(Mode, lobby(Namespace, Anchor, Sky, Devices), Parts)),
    modelling_vocabulary(ModellingNamespace, ModellingAnchor),
    ModellingNamespace::(current_ontology_identity(ModellingNamespace, ModellingAnchor),
                        model(Parts, Scene)).

%% Every visual parameter is durable lobby state. Exact-one reads make an
%% incomplete or ambiguous edit fail closed instead of inventing a default.
lobby_sky(sky(Entity, Panorama, Diameter, Rotation, Brightness, Tint)) :-
    findall(S, instance_of(sky_sphere, S), [Entity]),
    one_attribute(Entity, panorama, Panorama),
    one_attribute(Entity, diameter, Diameter),
    one_attribute(Entity, rotation, Rotation),
    one_attribute(Entity, brightness, Brightness),
    one_attribute(Entity, tint, Tint).

one_attribute(Entity, Name, Value) :-
    findall(V, attribute(Entity, Name, V), [Value]).

%% Missing or ambiguous instance data fails the view, rather than silently
%% dropping a device inside findall/3. No class or device is hardcoded here.
placed_devices([], []).
placed_devices([Entity | Entities], [device(Class, Entity, Id, At) | Devices]) :-
    findall(C, instance_of(C, Entity), [Class]),
    findall(placed(I, T), device_placement(Entity, I, T), [placed(Id, At)]),
    placed_devices(Entities, Devices).

lobby_menu(Device, Entries) :-
    instance_of(Class, Device),
    lobby_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                device_menu(Class, Entries)).

lobby_workspace(Device, View) :-
    instance_of(prolog_console, Device),
    gui_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                gui_view(proof_console, View)).
