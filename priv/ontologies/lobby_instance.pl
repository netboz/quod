%% Personal lobby behaviour. Founding supplies lobby_owner/1, exact vocabulary
%% references and device class memberships; no user registry here.
%% Found with quod_agent_predicates for proof-bound identity checks.
can_invoke(_, Principal, _, _) :- lobby_owner(Principal).

ontology_source_mode(editable) :- current_principal(Principal), lobby_owner(Principal).

lobby_space(Space, Modes) :-
    findall(S, instance_of(lobby, S), [Space]), findall(M, lobby_modes(M), [Modes]).

world_view(Space, Mode, Marks) :-
    instance_of(lobby, Space), lobby_view(Mode, Marks).

lobby_modes(Modes) :-
    lobby_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor), lobby_modes(Modes)).

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
placed_devices([Entity | Entities], [device(Classes, Entity, Id, At) | Devices]) :-
    device_classes(Entity, Classes),
    findall(placed(I, T), device_placement(Entity, I, T), [placed(Id, At)]),
    placed_devices(Entities, Devices).

%% Local subclasses contribute their declared parents. The pinned vocabulary
%% resolves its own ancestry; no foreign class definitions are copied here.
device_classes(Device, Classes) :-
    lobby_vocabulary(Namespace, _),
    findall(Class, (instance_of(Direct, Device),
                    (Parent = Direct; isa(Direct, Parent)),
                    vocabulary_class(Parent, Namespace, Class)), Raw),
    sort(Raw, Classes), Classes = [_ | _].

no_follow(vocabulary_class/3).
vocabulary_class(Reference, Namespace, Class) :-
    nonvar(Reference), Reference = _:_, !,
    '$quod_owner_name'(Reference, Owner, Class), ontology_name(Owner, Namespace).
vocabulary_class(Class, _, Class).

lobby_eidolons(Device, Mode, Style, Recipes) :-
    device_classes(Device, Classes),
    lobby_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                device_eidolons(Classes, Mode, Style, Recipes)).

lobby_menu(Device, Entries) :-
    device_classes(Device, Classes),
    lobby_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                device_menu(Classes, Entries)).

lobby_workspace(Device, ViewId, View) :-
    lobby_menu(Device, Entries),
    member(menu_entry(_, _, open_view(ViewId)), Entries),
    gui_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                gui_view(ViewId, View)).
