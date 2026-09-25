%% Shared lobby and device classes. Recipes are pure descriptions; concrete
%% device instances and ownership live in each personal lobby ontology.
acl_sovereign(quod:lobby).

can_invoke(Goal, _, _, _) :- lobby_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- lobby_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

lobby_query(lobby_recipe(_, _, _)).
lobby_query(device_menu(_, _)).
lobby_query(isa(_, _)).
lobby_query(class_eidolon(_, _, _)).
lobby_query(lobby_options(_, _)).
lobby_query(ontology_creation_allowed(_, _, _)).

%% A user's editable facts cannot grant names outside its own personal lobby.
%% The pending requirement is read in the same proof as the prepared creation.
ontology_creation_allowed(Owner, Name, Options) :-
    current_principal(Owner),
    Owner = agent_instance_ref(UserNamespace, UserAnchor, Instance),
    binary_codes(UserNamespace, UserBytes),
    append(UserBytes, [47,108,111,98,98,121], LobbyBytes),
    binary_codes(Name, LobbyBytes),
    UserNamespace::(current_ontology_identity(UserNamespace, UserAnchor),
                    instance_of(human_user, Instance),
                    lobby_provisioning(Instance, pending(Name))),
    lobby_options(Owner, Options).

%% A template is reviewed founding source stored in this ontology, not a path
%% read from whichever node happens to receive the creation request.
%% Founding supplies instance_template/1 and exact presentation/GUI references.
lobby_options(Owner,
    [source(Source),
     terms([lobby_owner(Owner), instance_of(lobby, personal_lobby),
            instance_of(prolog_console, console),
            lobby_device(personal_lobby, console),
            lobby_vocabulary(Namespace, Anchor),
            presentation_vocabulary(PresentationNamespace, PresentationAnchor),
            gui_vocabulary(GuiNamespace, GuiAnchor)]),
     external_predicate_modules([quod_agent_predicates])]) :-
    term_variables(Owner, []),
    Owner = agent_instance_ref(_, _, _),
    current_ontology_identity(Namespace, Anchor),
    instance_template(Source),
    presentation_vocabulary(PresentationNamespace, PresentationAnchor),
    gui_vocabulary(GuiNamespace, GuiAnchor).

isa(lobby, thing).
isa(device, thing).
isa(prolog_console, device).
class_eidolon(prolog_console, playing, console).
class_eidolon(prolog_console, edition, console).

%% Menu selection opens a local view. It does not claim an ontology action
%% committed. The entered goal subsequently uses the ordinary signed cursor.
device_menu(prolog_console,
    [menu_entry(prove_goal, <<"Prove a goal">>, open_view(proof_console))]).

%% +Y is up; the console faces -Z. Child transforms are in the parent's frame.
%% The two presentations reuse one recipe with different exposed surfaces.
%% HSL harmony pairs terracotta (18 degrees) with green (138), 120 degrees apart.
%% Ivory and amber share a neighbouring warm hue (38); painted surfaces retain
%% their colour with low metallic factors under the lobby's simple lighting.
lobby_recipe(Mode, Subject,
    [part(<<"floor">>, cylinder(10000, 100), transform(0, -50, 0, 0, 0, 0),
          pbr(<<"#813F22">>, 0, 900, 0), unlabelled, depicts_nothing),
     part(<<"console">>, group, transform(0, 0, 0, 0, 0, 0),
          no_surface, unlabelled, Subject),
     part(<<"pedestal">>, cylinder(460, 850),
          relative(<<"console">>, transform(0, 425, 0, 0, 0, 0)),
          pbr(<<"#E1D2B7">>, 100, 600, 0), unlabelled, depicts_nothing),
     part(<<"body">>, box(1600, 1000, 160),
          relative(<<"console">>, transform(0, 1400, 0, 0, 0, 0)),
          Body, unlabelled, depicts_nothing),
     part(<<"screen">>, plane(1440, 820),
          relative(<<"body">>, ScreenAt),
          pbr(<<"#06180C">>, 0, 450, 80), unlabelled, depicts_nothing),
     part(<<"status">>, sphere(55),
          relative(<<"body">>, transform(700, -465, -95, 0, 0, 0)),
          pbr(<<"#EEA62B">>, 0, 500, 400), unlabelled, depicts_nothing),
     part(<<"console-label">>, group,
          relative(<<"body">>, transform(0, 640, 0, 0, 0, 0)),
          no_surface, label(Label, <<"centre">>), depicts_nothing)]) :-
    console_surface(Mode, Body, Label),
    presentation_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                align(plane(1440, 820), centre, box(1600, 1000, 160), front, 5, ScreenAt)).

console_surface(playing, pbr(<<"#196630">>, 150, 550, 0), <<"PROLOG CONSOLE">>).
console_surface(edition, pbr(<<"#BD8728">>, 150, 550, 0), <<"CONSOLE STRUCTURE">>).
