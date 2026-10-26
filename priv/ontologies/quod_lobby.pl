%% Shared lobby and device classes. Recipes are pure descriptions; concrete
%% device instances and ownership live in each personal lobby ontology.
acl_sovereign(quod:lobby).

can_invoke(Goal, _, _, _) :- lobby_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- lobby_query(Goal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

lobby_query(lobby_modes(_)).
lobby_query(isa(_, _)).
lobby_query(class_eidolon(_, _, _, _)).
lobby_query(eidolon(_, _, _)).
lobby_query(lobby_options(_, _, _)).
lobby_query(world_palette(_)).
lobby_query(gui_vocabulary(_, _)).
lobby_query(ontology_creation_allowed(_, _, _)).
lobby_query(Goal) :- public_source_query(Goal).

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
                    lobby_provisioning(Instance, pending(Name)), hosting_node(Node)),
    lobby_options(Owner, Node, Options).

%% Release-owned source paths use the ordinary prepared-creation lifecycle.
%% It freezes their complete contents into the new genesis before committing;
%% recovery uses that genesis and never reloads files or repairs source.
lobby_options(Owner, Node, Options) :-
    term_variables([Owner, Node], []),
    Owner = agent_instance_ref(_, _, _), Node = agent_instance_ref(_, _, _),
    findall(source_file(Path), lobby_source_file(Path), Sources), Sources = [_ | _],
    append(Sources, [terms([lobby_owner(Owner), instance_of(lobby, personal_lobby),
            physics_initial_host(personal_lobby, Node),
            instance_of(lobby_floor, floor),
            attribute(floor,mark_id,<<"floor">>),
            attribute(personal_roof,mark_id,<<"roof">>),
            attribute(console,mark_id,<<"console">>),
            attribute(personal_sky,mark_id,<<"sky">>),
            instance_of(agent, pilot),
            rendering_vocabulary(RenderingNamespace, RenderingAnchor),
            instance_of(sky_sphere, personal_sky),
            attribute(personal_sky, panorama, belfast_sunset_puresky),
            attribute(personal_sky, diameter, 80000),
            attribute(personal_sky, rotation, 75),
            attribute(personal_sky, brightness, 1000),
            attribute(personal_sky, tint, <<"#FFFFFF">>),
            instance_of(prolog_console, console),
            instance_of(lobby_roof, personal_roof),
            lobby_vocabulary(Namespace, Anchor),
            modelling_vocabulary(ModellingNamespace, ModellingAnchor),
            environment_vocabulary(EnvironmentNamespace, EnvironmentAnchor),
            environment_eidolons(EnvironmentEidolonNs,EnvironmentEidolonAnchor),
            gui_vocabulary(GuiNamespace, GuiAnchor),
            names_vocabulary(NamesNamespace, NamesAnchor) | Bodies]),
        external_predicate_modules([quod_agent_predicates])], Options),
    current_ontology_identity(Namespace, Anchor),
    lobby_definitions(Bodies),
    findall(ontology_ref(R, A), rendering_vocabulary(R, A),
        [ontology_ref(RenderingNamespace, RenderingAnchor)]),
    modelling_vocabulary(ModellingNamespace, ModellingAnchor),
    environment_vocabulary(EnvironmentNamespace, EnvironmentAnchor),
    environment_eidolons(EnvironmentEidolonNs,EnvironmentEidolonAnchor),
    gui_vocabulary(GuiNamespace, GuiAnchor),
    findall(ontology_ref(N,A),names_vocabulary(N,A),[ontology_ref(NamesNamespace,NamesAnchor)]).

%% Authored floor includes the depressed glass porthole and the raised outer
%% coping. The roof keeps its oculus and six entrances.
lobby_definitions([
    physics_definition(floor, 1, geometry(Floor, 1)),
    physics_definition(pilot, 1, geometry(capsule(500, 250), 1)),
    physics_definition(personal_roof, 1, geometry(Roof, 1)),
    physics_definition(console, 1, geometry(Console, 1))]) :-
    lobby_surface([ring(0,-550,0),ring(1100,-438,0),ring(2200,-100,0),
        ring(2450,200,0),ring(3000,0,0),ring(8560,0,0),ring(8560,780,0),
        ring(8750,1000,0),ring(9000,780,0)], Floor),
    lobby_surface([ring(2250, 4650, 0), ring(5500, 4325, 181), ring(8950, 3350, 2900)], Roof),
    Console = parts([part(vector(0, 70, 120), box(1000, 70, 500)),
                     part(vector(0, 175, 80), box(920, 35, 420)),
                     part(vector(0, 590, 120), box(380, 410, 240)),
                     part(vector(0, 1450, 0), box(950, 550, 210))]).

lobby_surface([ring(0,H,0)|Rings],surface([vector(0,Y,0)|Vertices],Triangles)) :- !,
    Y is H,
    lobby_surface(Rings,surface(Vertices,Rows)),
    findall(triangle(A1,B1,C1),(member(triangle(A,B,C),Rows),
        A1 is A+1,B1 is B+1,C1 is C+1),Shifted),
    findall(triangle(0,C,B),(member(J,[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23]),
        B is J+1,C is (J+1) mod 24+1),Cap), append(Cap,Shifted,Triangles).
lobby_surface(Rings, surface(Vertices, Triangles)) :-
    Directions = [d(1000000,0,1000),d(965926,258819,354),d(866025,500000,0),
        d(707107,707107,354),d(500000,866025,1000),d(258819,965926,354),
        d(0,1000000,0),d(-258819,965926,354),d(-500000,866025,1000),
        d(-707107,707107,354),d(-866025,500000,0),d(-965926,258819,354),
        d(-1000000,0,1000),d(-965926,-258819,354),d(-866025,-500000,0),
        d(-707107,-707107,354),d(-500000,-866025,1000),d(-258819,-965926,354),
        d(0,-1000000,0),d(258819,-965926,354),d(500000,-866025,1000),
        d(707107,-707107,354),d(866025,-500000,0),d(965926,-258819,354)],
    findall(vector(X, Y, Z),
        (member(ring(R, H, Drop), Rings), member(d(C, S, Q), Directions),
         X is R*C//1000000, Z is R*S//1000000, Y is H-Drop*Q//1000), Vertices),
    findall(Triangle,
        (append(Before,[_,_|_],Rings), length(Before,Row),
         member(J, [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23]),
         A is Row*24+J, B is (Row+1)*24+J, Cn is (J+1) mod 24,
         C is (Row+1)*24+Cn, D is Row*24+Cn,
         member(Triangle, [triangle(A,C,B), triangle(A,D,C)])), Triangles).

isa(lobby, physical_space).
isa(physical_space, space).
isa(space, thing).
isa(lobby_floor, thing).
isa(device, thing).
isa(prolog_console, device).
isa(imported_artifact, device).
isa(lobby_roof, thing).
%% Class associations name ordinary, anchored Prolog recipe entry points.
class_eidolon(Class,Mode,Style,recipe(Ns,Anchor,Recipe)) :-
    device_eidolon(Class,Mode,Style,Recipe), current_ontology_identity(Ns,Anchor).

device_eidolon(prolog_console, playing, solid, console_playing).
device_eidolon(prolog_console, edition, solid, console_edition).
device_eidolon(imported_artifact, playing, solid, imported_artifact_playing).
device_eidolon(lobby_floor, playing, solid, lobby_floor).
device_eidolon(lobby_floor, edition, solid, lobby_floor).
device_eidolon(lobby_roof, playing, solid, lobby_roof).
device_eidolon(lobby_roof, edition, solid, lobby_roof).

lobby_modes(Modes) :-
    findall(Mode, device_eidolon(_, Mode, solid, _), Offered), sort(Offered, Modes).

eidolon(lobby_floor,device(_),[
    part(<<"model">>,
                 mesh_asset(asset(<<"766c7015b7281f6009838145a06ae8c8b61c37bfc6116be16aaeaba1d8b817ee">>,
                                  <<"model/gltf-binary">>),
                            <<"gltf2-static-v1">>, scale(1000),
                            frame(aabb(-9000, -570, -9000, 9000, 1000, 9000),
                                  pivot(0, 0, 0), front(<<"-z">>)),
                            resources(2103472, 2101296, 55298, 64512, 1, 3, 1)),
                 transform(0, 0, 0, 0, 0, 0), asset_surfaces, unlabelled, depicts_nothing)]).

material_surface(Material, Surface) :-
    material_eidolons(Ns, Anchor),
    Ns::(current_ontology_identity(Ns, Anchor),
         class_eidolon(Material, playing, solid, recipe(RecipeNs, RecipeAnchor, Recipe))),
    RecipeNs::(current_ontology_identity(RecipeNs, RecipeAnchor),
               eidolon(Recipe, material(Material), Surface)).

%% New worlds freeze these catalogue-selected surfaces into their own state.
world_palette([
    material(1,surface(<<"#B7D6AA">>,0,950,0,[Grass])),
    material(2,surface(<<"#A58868">>,0,950,0,[Ground])),
    material(3,surface(<<"#E5D8AC">>,0,900,0,[Ground])),
    material(4,surface(<<"#C99B79">>,0,900,0,[Ground])),
    material(5,surface(<<"#E7E9E5">>,0,800,0,[])),
    material(6,surface(<<"#A1A5A5">>,0,900,0,[Ground]))]) :-
    material_eidolons(Ns,A),
    Ns::(current_ontology_identity(Ns,A),texture_asset(babylon_grass,<<"base_colour">>,GrassAsset,_)),
    Ns::(current_ontology_identity(Ns,A),texture_asset(babylon_ground,<<"base_colour">>,GroundAsset,_)),
    Grass = texture(<<"base_colour">>,GrassAsset,repeat(500,500)),
    Ground = texture(<<"base_colour">>,GroundAsset,repeat(500,500)).

%% Roof and ground are separate appearance assets, not physical body identities.
eidolon(lobby_roof, device(_),
    [part(<<"model">>,
          mesh_asset(asset(<<"e2342ad365f644003e22372f41a25e833541c6c30b314ac539534e5c3a077121">>,
                           <<"model/gltf-binary">>),
                     <<"gltf2-static-v1">>, scale(1000),
                     frame(aabb(-8875, 1000, -8852, 8875, 5250, 8852),
                           pivot(0, 0, 0), front(<<"-z">>)),
                     resources(942164, 940032, 20160, 38016, 1, 2, 1)),
          transform(0, 0, 0, 0, 0, 0), asset_surfaces, unlabelled, depicts_nothing)]).
%% Playing depicts the packaged console model; edition exposes its structure.
eidolon(console_playing, device(_),
    [part(<<"model">>,
          mesh_asset(asset(<<"2be70465da809e6e29b8b12aae01a568e54cd150e86f35f790e06a61fc82bc04">>,
                           <<"model/gltf-binary">>),
                     <<"gltf2-static-v1">>, scale(1000),
                     frame(aabb(-921, -929, -898, 881, 904, 894),
                           pivot(0, -929, 0), front(<<"-z">>)),
                     resources(5357484, 1227580, 31379, 50000, 1, 1, 4194304)),
          transform(0, 0, 0, 0, 0, 0), asset_surfaces,
          label(<<"PROLOG CONSOLE">>, <<"above">>), depicts_nothing)]).
eidolon(console_edition, device(_), Parts) :- console_parts(Parts).
%% The packaged public GLB is a sample recipe; the enclosing placed instance
%% remains the only source of its anchored subject and interaction rights.
eidolon(imported_artifact_playing, device(_),
    [part(<<"model">>,
          mesh_asset(asset(<<"ad1f1cbe8c100fd774e315b629d0bb1082820c9a7abe2a2a999aef846d675064">>,
                           <<"model/gltf-binary">>),
                     <<"gltf2-static-v1">>, scale(1000),
                     frame(aabb(-300, 0, -400, 1200, 1400, 300),
                           pivot(200, 0, -100), front(<<"+x">>)),
                     resources(1452, 96, 6, 2, 3, 2, 4)),
          transform(0, 0, 0, 0, 0, 0), asset_surfaces,
          label(<<"Imported model">>, <<"above">>), depicts_nothing)]).
console_parts(
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
    console_layout(Gap, Title, BaseLabel, SupportLabel, BodyLabel,
                   ScreenLabel, ShelfLabel, ControlLabel),
    modelling_vocabulary(Ns, Anchor),
    Ns::(current_ontology_identity(Ns, Anchor),
         align(plane(1400, 680), centre, box(1540, 810, 90), front, Gap, ScreenAt)).
console_layout(350, <<"CONSOLE PARTS">>,
               label(<<"WEIGHTED BASE">>, <<"above">>),
               label(<<"CENTRAL SUPPORT">>, <<"above">>),
               label(<<"DISPLAY HOUSING">>, <<"above">>),
               label(<<"SCREEN">>, <<"above">>),
               label(<<"CONTROL SHELF">>, <<"above">>),
               label(<<"STATUS CONTROL">>, <<"above">>)).

%% Physical input descriptions are shared data, never a connected-device list.
isa(xr_controller, device).
isa(htc_vive_controller, xr_controller).
lobby_query(controller_description(_, _)).
lobby_query(controller_default(_)).
lobby_query(controller_configuration(_, _)).
no_follow(controller_configuration/2).
no_follow(controller_roles/1).
no_follow(controller_overrides/2).
no_follow(controller_effective/3).
no_follow(controller_binding/1).
no_follow(controller_conflict/3).

controller_description(htc_vive_controller,
    controller([<<"htc-vive">>],
      [component(trigger,<<"xr-standard-trigger">>,trigger,[press,value]),
       component(grip,<<"xr-standard-squeeze">>,squeeze,[press]),
       component(pad,<<"xr-standard-touchpad">>,touchpad,[press,touch,axes2])],
      [target_ray,grip], Appearance)) :-
    class_eidolons([htc_vive_controller], input, solid,
        [eidolon(input,solid,recipe(Ns,A,Recipe))]),
    current_ontology_identity(Ns,A),
    eidolon(Recipe, class(htc_vive_controller), Appearance).

class_eidolon(htc_vive_controller,input,solid,recipe(Ns,A,vive_wand)) :-
    current_ontology_identity(Ns,A).
eidolon(vive_wand,class(htc_vive_controller),
    tracked_model(grip,asset(<<"bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94">>,
      <<"gltf2-static-v1">>,bounds(MinX,MinY,MinZ,59,23,106),
      resources(1114152,665696,17551,17344,37,1,4194304)))) :-
    MinX is -59, MinY is -70, MinZ is -117.

controller_default(settings([role(navigation,hand(left)),role(menu,hand(right))],vive_default,[])).
controller_bindings(vive_default,[
    bind(select,any,trigger,press_release,local(select)),
    bind(menu,menu,pad,radial(240),local(menu)),
    bind(drive,navigation,pad,axes_while(grip),control(drive)),
    bind(snap,navigation,pad,sector(horizontal,500,grip),control(snap)),
    bind(teleport,navigation,pad,sector(forward,500,grip),control(teleport(500)))]).

controller_configuration(settings(Roles,Set,Overrides),mapping(1,Roles,Bindings,Descriptions)) :-
    term_variables(settings(Roles,Set,Overrides),[]),
    controller_roles(Roles), controller_bindings(Set,Defaults),
    controller_overrides(Overrides,Defaults), controller_effective(Defaults,Overrides,Bindings),
    \+ (member(B,Bindings), \+ controller_binding(B)),
    \+ (member(B,Bindings),member(C,Bindings),B \== C,controller_conflict(B,C,Roles)),
    member(bind(select,_,_,press_release,local(select)),Bindings),
    findall(profile(Class,Description),controller_description(Class,Description),Descriptions),
    Descriptions = [_|_].
controller_roles([role(navigation,hand(N)),role(menu,hand(M))]) :-
    member(N,[left,right,none]),member(M,[left,right,none]).
controller_overrides([], _).
controller_overrides([Override|Rest], Defaults) :-
    (Override = disable(Id); Override = replace(bind(Id,_,_,_,_))),
    member(bind(Id,_,_,_,_),Defaults),
    \+ (member(Other,Rest),(Other = disable(Id);Other = replace(bind(Id,_,_,_,_)))),
    controller_overrides(Rest,Defaults).
controller_effective([],_,[]).
controller_effective([B|Rest],Overrides,Bindings) :-
    B = bind(Id,_,_,_,_),
    (member(disable(Id),Overrides) -> Bindings = Tail
    ; (member(replace(Replacement),Overrides),Replacement = bind(Id,_,_,_,_) -> Current = Replacement
      ; Current = B), Bindings = [Current|Tail]),
    controller_effective(Rest,Overrides,Tail).
controller_role(R) :- member(R,[any,navigation,menu]).
controller_press(C) :- member(C,[trigger,grip,pad]).
controller_permille(N) :- integer(N),N > 0,N < 1000.
controller_binding(bind(select,R,C,press_release,local(select))) :- controller_role(R),controller_press(C).
controller_binding(bind(menu,R,pad,radial(N),local(menu))) :- controller_role(R),controller_permille(N).
controller_binding(bind(drive,R,pad,axes_while(C),control(drive))) :-
    member(R,[navigation,menu]),member(C,[trigger,grip]).
controller_binding(bind(snap,R,pad,sector(horizontal,N,C),control(snap))) :-
    controller_role(R),controller_permille(N),member(C,[trigger,grip]).
controller_binding(bind(teleport,R,pad,sector(forward,N,C),control(teleport(F)))) :-
    controller_role(R),controller_permille(N),member(C,[trigger,grip]),controller_permille(F).
controller_conflict(bind(_,R,C,G,_),bind(_,S,C,H,_),Roles) :-
    controller_roles_overlap(R,S,Roles),
    \+ controller_disjoint(G,H).
controller_conflict(bind(_,R,C,press_release,_),bind(_,S,_,G,_),Roles) :-
    controller_roles_overlap(R,S,Roles),
    (G = axes_while(C);G = sector(_,_,C)).
controller_roles_overlap(R,S,Roles) :-
    (R = any;S = any;member(role(R,Hand),Roles),member(role(S,Hand),Roles)).
controller_disjoint(axes_while(C),sector(_,_,C)).
controller_disjoint(sector(_,_,C),axes_while(C)).
controller_disjoint(sector(horizontal,_,_),sector(forward,_,_)).
controller_disjoint(sector(forward,_,_),sector(horizontal,_,_)).
