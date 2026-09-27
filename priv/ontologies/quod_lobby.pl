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
lobby_query(class_eidolon(_, _, _, _)).
lobby_query(eidolon(_, _, _)).
lobby_query(lobby_options(_, _)).
lobby_query(ontology_creation_allowed(_, _, _)).
lobby_query(panorama_asset(_, _, _)).
lobby_query(have_attribute(_, _, _)).

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
%% Founding supplies instance_template/1 and exact modelling/GUI references.
lobby_options(Owner,
    [source(Source),
     terms([lobby_owner(Owner), instance_of(lobby, personal_lobby),
            instance_of(sky_sphere, personal_sky),
            attribute(personal_sky, panorama, belfast_sunset_puresky),
            attribute(personal_sky, diameter, 80000),
            attribute(personal_sky, rotation, 75),
            attribute(personal_sky, brightness, 120),
            attribute(personal_sky, tint, <<"#FFFFFF">>),
            instance_of(prolog_console, console),
            lobby_device(personal_lobby, console),
            device_placement(console, <<"console">>, transform(0, 0, 0, 0, 0, 0)),
            lobby_vocabulary(Namespace, Anchor),
            modelling_vocabulary(ModellingNamespace, ModellingAnchor),
            gui_vocabulary(GuiNamespace, GuiAnchor)]),
     external_predicate_modules([quod_agent_predicates])]) :-
    term_variables(Owner, []),
    Owner = agent_instance_ref(_, _, _),
    current_ontology_identity(Namespace, Anchor),
    instance_template(Source),
    modelling_vocabulary(ModellingNamespace, ModellingAnchor),
    gui_vocabulary(GuiNamespace, GuiAnchor).

isa(lobby, thing).
isa(device, thing).
isa(prolog_console, device).
isa(sky_sphere, thing).

%% A lobby owns its sky instance and may tune these values with ordinary
%% transactions. Panorama assets stay content-addressed shared vocabulary.
have_attribute(sky_sphere, panorama, atom).
have_attribute(sky_sphere, diameter, millimetres).
have_attribute(sky_sphere, rotation, degrees).
have_attribute(sky_sphere, brightness, permille).
have_attribute(sky_sphere, tint, colour).

panorama_asset(belfast_sunset_puresky,
    asset(<<"d47c2b1b40f651cab5b4b151c92b66b788ceb2d57e2056a0ce7c469f333c23f4">>, <<"image/jpeg">>),
    source(<<"https://dl.polyhaven.org/file/ph-assets/HDRIs/extra/Tonemapped%20JPG/belfast_sunset_puresky.jpg">>, <<"CC0-1.0">>)).
%% Class associations name ordinary, anchored Prolog recipe entry points.
class_eidolon(Class, Mode, Style, recipe(Ns, Anchor, Recipe)) :-
    device_eidolon(Class, Mode, Style, Recipe), current_ontology_identity(Ns, Anchor).
class_eidolon(Class, Mode, Style, recipe(Ns, Anchor, Recipe)) :-
    environment_eidolon(Class, Mode, Style, Recipe), current_ontology_identity(Ns, Anchor).
device_eidolon(prolog_console, playing, solid, console_playing).
device_eidolon(prolog_console, edition, solid, console_edition).
environment_eidolon(sky_sphere, playing, panoramic, sky_sphere_panoramic).
environment_eidolon(sky_sphere, edition, panoramic, sky_sphere_panoramic).

device_menu(prolog_console,
    [menu_entry(prove_goal, <<"Prove a goal">>, open_view(proof_console))]).

%% Every placed device is selected by class; repeated instances share recipes.
lobby_recipe(Mode, lobby(Ns, Anchor, Sky, Devices), [SkyPart, Floor | Parts]) :-
    environment_parts(Mode, Sky, Ns, Anchor, [SkyPart]),
    material_surface(marble, Stone),
    Floor = part(<<"floor">>, cylinder(10000, 100), transform(0, -50, 0, 0, 0, 0),
                 Stone, unlabelled, depicts_nothing),
    device_parts(Devices, Mode, Ns, Anchor, Parts).

environment_parts(Mode, Sky, Ns, Anchor, Parts) :-
    findall(Recipe, environment_eidolon(sky_sphere, Mode, panoramic, Recipe), [Recipe]),
    eidolon(Recipe, environment(Sky, Ns, Anchor), Parts).

eidolon(sky_sphere_panoramic,
        environment(sky(Entity, Panorama, Diameter, Rotation, Brightness, Tint), Ns, Anchor),
        [part(<<"sky">>, sky_sphere(Diameter), transform(0, 0, 0, 0, Rotation, 0),
              Surface, unlabelled, depicts(Ns, Anchor, Entity))]) :-
    panorama_asset(Panorama, Asset, _),
    Surface = surface(Tint, 0, 1000, Brightness,
                      [texture(<<"base_colour">>, Asset, repeat(1000, 1000))]).
device_parts([], _, _, _, []).
device_parts([device(Class, Entity, Id, At) | Devices], Mode, Ns, Anchor, Parts) :-
    findall(Recipe, device_eidolon(Class, Mode, solid, Recipe), [Recipe]),
    eidolon(Recipe, device(Entity), Model),
    modelling_vocabulary(MNs, MA),
    MNs::(current_ontology_identity(MNs, MA),
          place_model(Id, At, depicts(Ns, Anchor, Entity), Model, Placed)),
    device_parts(Devices, Mode, Ns, Anchor, Rest), append(Placed, Rest, Parts).

material_surface(Material, Surface) :-
    material_eidolons(Ns, Anchor),
    Ns::(current_ontology_identity(Ns, Anchor),
         class_eidolon(Material, playing, solid, recipe(RecipeNs, RecipeAnchor, Recipe))),
    RecipeNs::(current_ontology_identity(RecipeNs, RecipeAnchor),
               eidolon(Recipe, material(Material), Surface)).

%% Operational and exploded structure views share physical dimensions, while
%% their placement and labels express different uses of the same device.
eidolon(console_playing, device(_), Parts) :- console_parts(playing, Parts).
eidolon(console_edition, device(_), Parts) :- console_parts(edition, Parts).
console_parts(Mode,
    [part(<<"plinth">>, box(2000, 140, 1000), transform(0, 70, 120, 0, 0, 0),
          Shell, BaseLabel, depicts_nothing),
     part(<<"deck">>, box(1840, 70, 840), transform(0, 175, 80, 0, 0, 0),
          Wood, unlabelled, depicts_nothing),
     part(<<"support">>, box(760, 820, 480), transform(0, 590, 120, 0, 0, 0),
          Shell, SupportLabel, depicts_nothing),
     part(<<"support-face">>, box(620, 650, 70),
          relative(<<"support">>, transform(0, 0, -275, 0, 0, 0)),
          Bronze, unlabelled, depicts_nothing),
     part(<<"body">>, box(1900, 1100, 320), transform(0, 1450, 0, 0, 0, 0),
          Shell, BodyLabel, depicts_nothing),
     part(<<"left-cheek">>, box(160, 1040, 380),
          relative(<<"body">>, transform(-870, 0, 0, 0, 0, 0)),
          Wood, unlabelled, depicts_nothing),
     part(<<"right-cheek">>, box(160, 1040, 380),
          relative(<<"body">>, transform(870, 0, 0, 0, 0, 0)),
          Wood, unlabelled, depicts_nothing),
     part(<<"bezel">>, box(1540, 810, 90),
          relative(<<"body">>, transform(0, 40, -195, 0, 0, 0)),
          Inset, unlabelled, depicts_nothing),
     part(<<"screen">>, plane(1400, 680), relative(<<"bezel">>, ScreenAt),
          Screen, ScreenLabel, depicts_nothing),
     part(<<"shelf">>, box(1900, 180, 580),
          relative(<<"body">>, transform(0, -620, -180, 350, 0, 0)),
          Shell, ShelfLabel, depicts_nothing),
     part(<<"shelf-trim">>, box(1800, 50, 540),
          relative(<<"shelf">>, transform(0, 85, 0, 0, 0, 0)),
          Bronze, unlabelled, depicts_nothing),
     part(<<"status">>, sphere(55),
          relative(<<"shelf">>, transform(700, 70, -300, 0, 0, 0)),
          Glow, unlabelled, depicts_nothing),
     part(<<"status-ring">>, torus(110, 18),
          relative(<<"shelf">>, transform(700, 70, -310, 90, 0, 0)),
          Bronze, ControlLabel, depicts_nothing),
     part(<<"control-knob">>, cylinder(100, 55),
          relative(<<"shelf">>, transform(520, 70, -315, 90, 0, 0)),
          Bronze, unlabelled, depicts_nothing),
     part(<<"top-sign">>, box(900, 100, 80),
          relative(<<"body">>, transform(0, 650, -150, 0, 0, 0)),
          Bronze, label(Title, <<"above">>), depicts_nothing)]) :-
    material_surface(oak_wood, Wood), material_surface(bronze, Bronze),
    Shell = surface(<<"#253239">>,650,420,0,[]),
    Inset = surface(<<"#10191E">>,250,300,40,[]),
    Screen = surface(<<"#071419">>,0,350,120,[]),
    Glow = surface(<<"#F4B942">>,0,350,700,[]),
    console_layout(Mode, Gap, Title, BaseLabel, SupportLabel, BodyLabel,
                   ScreenLabel, ShelfLabel, ControlLabel),
    modelling_vocabulary(Ns, Anchor),
    Ns::(current_ontology_identity(Ns, Anchor),
         align(plane(1400, 680), centre, box(1540, 810, 90), front, Gap, ScreenAt)).
console_layout(playing, 5, <<"PROLOG CONSOLE">>, unlabelled, unlabelled,
               unlabelled, unlabelled, unlabelled, unlabelled).
console_layout(edition, 350, <<"CONSOLE PARTS">>,
               label(<<"WEIGHTED BASE">>, <<"above">>),
               label(<<"CENTRAL SUPPORT">>, <<"above">>),
               label(<<"DISPLAY HOUSING">>, <<"above">>),
               label(<<"SCREEN">>, <<"above">>),
               label(<<"CONTROL SHELF">>, <<"above">>),
               label(<<"STATUS CONTROL">>, <<"above">>)).
