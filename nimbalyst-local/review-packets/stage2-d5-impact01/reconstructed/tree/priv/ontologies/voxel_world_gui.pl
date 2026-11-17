%% Compose with voxel_world.pl and gui_instance.pl. The application supplies
%% its existing GUI vocabulary, question policy and explicit domain ACLs.
%% Presets compile to authored field_v1 data; worlds never follow a changing
%% catalogue recommendation when an unchanged chunk is materialized.
voxel_preset(meadow, <<"Meadows and dry hills">>,
    [biome(-40000,2000,1000,3,4,1500),biome(0,6000,2500,1,2,1500),
     biome(40000,11000,6500,1,6,1000)]).
voxel_preset(highlands, <<"Alpine highlands">>,
    [biome(-40000,5000,3000,1,2,1500),biome(0,14000,10000,6,6,500),
     biome(40000,24000,16000,5,6,2000)]).
voxel_preset(badlands, <<"Sandstone badlands">>,
    [biome(-40000,2000,1500,3,4,2000),biome(0,9000,6000,4,4,2000),
     biome(40000,16000,12000,4,6,1000)]).

voxel_blueprint(Name,Seed,Spacing,ClimateMetres,HillsPercent,CavesPercent,Field) :-
    term_variables([Name,Seed,Spacing,ClimateMetres,HillsPercent,CavesPercent],[]),
    integer(Seed), Seed >= 0, Seed < 18446744073709551616,
    integer(Spacing), Spacing >= 256, Spacing mod 2 =:= 0,
    integer(ClimateMetres), ClimateMetres > 0,
    integer(HillsPercent), HillsPercent >= 0,
    integer(CavesPercent), CavesPercent >= 0, CavesPercent < 100,
    voxel_preset(Name,_,Bands), voxel_scaled_biomes(Bands,HillsPercent,Scaled),
    Climate is ClimateMetres*1000,
    Terrain = [plane(0),biome_relief(Climate,10,16000,11,Scaled)],
    (CavesPercent = 0 -> CaveLayers = []
    ; Width is CavesPercent*65536//100, CaveLayers = [caves(16000,12,Width,2000)]),
    RockHeight is -4000,
    append(Terrain,CaveLayers,Layers), append(Layers,[material_below(RockHeight,6)],Ops),
    Field = field_v1(Seed,Spacing,Ops,1).
voxel_scaled_biomes([],_,[]).
voxel_scaled_biomes([biome(C0,H,A,T,S,D)|Rest],Scale,[biome(C,Height,Amplitude,T,S,D)|Scaled]) :-
    C is C0, Height is H*Scale//100, Amplitude is A*Scale//100,
    voxel_scaled_biomes(Rest,Scale,Scaled).

%% These are editable form defaults, not runtime allocation allowances.
voxel_parameter(preset,quod:gui:selection,<<"Landscape">>,meadow,[]).
voxel_parameter(seed,quod:gui:number_input,<<"Seed">>,1947,
    [attribute(range,range(0,4294967295,1))]).
voxel_parameter(spacing,quod:gui:selection,<<"Ground detail">>,1000,
    [attribute(options,[option(500,<<"Fine — 0.5 m">>),option(1000,<<"Medium — 1 m">>),
                        option(2000,<<"Coarse — 2 m">>)])]).
voxel_parameter(extent,quod:gui:selection,<<"World size">>,bounded,
    [attribute(options,[option(bounded,<<"Bounded">>),option(unbounded,<<"Unbounded">>)])]).
voxel_parameter(radius,quod:gui:number_input,<<"Bounded world radius">>,32,
    [attribute(range,range(16,512,16)),attribute(unit,metres)]).
voxel_parameter(climate,quod:gui:number_input,<<"Biome size">>,128,
    [attribute(range,range(16,1024,16)),attribute(unit,metres)]).
voxel_parameter(hills,quod:gui:slider,<<"Terrain height">>,100,
    [attribute(range,range(0,300,5)),attribute(unit,percent)]).
voxel_parameter(caves,quod:gui:slider,<<"Cave openness">>,15,
    [attribute(range,range(0,40,1)),attribute(unit,percent),
     attribute(help,<<"Zero disables underground caves. A 2 m roof is preserved.">>)]).

instance_of(quod:gui:form,voxel_generation(W)) :- instance_of(voxel_world,W).
instance_of(Class,voxel_setting(W,Key)) :- voxel_parameter(Key,Class,_,_,_),instance_of(voxel_world,W).
instance_of(quod:gui:button,generate_voxel(W)) :- instance_of(voxel_world,W).
gui_children(voxel_generation(W),[voxel_setting(W,preset),voxel_setting(W,seed),
    voxel_setting(W,spacing),voxel_setting(W,extent),voxel_setting(W,radius),
    voxel_setting(W,climate),voxel_setting(W,hills),voxel_setting(W,caves),generate_voxel(W)]).
attribute(voxel_generation(_),label,<<"Generate terrain">>).
attribute(voxel_generation(_),help,
    <<"Choose a landscape. Changing generation requires an empty world with no digs or paint edits. Use a new world to preserve an edited landscape.">>).
attribute(voxel_setting(_,Key),label,Label) :- voxel_parameter(Key,_,Label,_,_).
attribute(voxel_setting(_,Key),Name,Value) :-
    voxel_parameter(Key,_,_,_,Properties),member(attribute(Name,Value),Properties).
attribute(voxel_setting(_,preset),options,Options) :-
    findall(option(Name,Label),voxel_preset(Name,Label,_),Options).
attribute(generate_voxel(_),label,<<"Generate terrain">>).
gui_initial(voxel_generation(_),voxel_setting(_,Key),Value) :- voxel_parameter(Key,_,_,Value,_).

voxel_generation_fields(W,
    [field(voxel_setting(W,preset),Preset),field(voxel_setting(W,seed),Seed),
     field(voxel_setting(W,spacing),Spacing),field(voxel_setting(W,extent),Mode),
     field(voxel_setting(W,radius),Radius),field(voxel_setting(W,climate),Climate),
     field(voxel_setting(W,hills),Hills),field(voxel_setting(W,caves),Caves)],
    recipe(Preset,Seed,Spacing,Mode,Radius,Climate,Hills,Caves)).

voxel_generation_spec(recipe(Preset,Seed,Spacing,Mode,Radius,Climate,Hills,Caves),Spec) :-
    voxel_blueprint(Preset,Seed,Spacing,Climate,Hills,Caves,Field),
    voxel_generation_extent(Mode,Radius,Spacing,Extent),Spec = terrain_v1(Extent,smooth,Field).

gui_form(voxel_generation(W),Fields,
    submit(generate_voxel(W),voxel_generation_entered(W,Revision,Versions,Preset,Seed,
                                                     Spacing,Mode,Radius,Climate,Hills,Caves))) :-
    voxel_generation_fields(W,Fields,recipe(Preset,Seed,Spacing,Mode,Radius,Climate,Hills,Caves)),
    voxel_world_state(W,Revision,_),voxel_patch_versions(W,Versions).

voxel_generation_entered(W,Revision,Versions,Preset,Seed,Spacing,Mode,Radius,Climate,Hills,Caves) :-
    transaction((current_principal(Actor),
        findall(H,gui_question_policy(voxel_generation(W),H,Actor),[Human]),
        voxel_generation_spec(recipe(Preset,Seed,Spacing,Mode,Radius,Climate,Hills,Caves),Spec),
        findall(Owner,voxel_world_owner(W,Owner),Owners),
        (Owners = [] -> assertz(voxel_world_owner(W,Human)); Owners = [Human]),
        voxel_world_state(W,Revision,Before),
        (Before = none -> Versions = [],voxel_create(W,Revision,Spec)
        ; voxel_regenerate(W,Revision,Versions,Spec)))).

voxel_generation_extent(unbounded,_,_,unbounded).
voxel_generation_extent(bounded,Radius,Spacing,bounded(chunk_v1(L,L,L),chunk_v1(H,H,H))) :-
    integer(Radius),Radius > 0, Width is Spacing*8,
    Radius*1000 mod Width =:= 0,H is Radius*1000//Width,L is -H.

%% Digging is an ordinary submitted form. Coordinate/radius ranges belong to
%% application policy. The whole current patch basis fences the draft because
%% its brush coordinates are not known until the user submits the fields.
voxel_brush_controls(_,_,_) :- fail.
instance_of(quod:gui:form,voxel_excavation(W)) :- voxel_terrain_binding(W,_,_).
instance_of(quod:gui:number_input,voxel_brush(W,Key)) :-
    voxel_terrain_binding(W,_,_),member(Key,[x,y,z,radius]).
instance_of(quod:gui:button,dig_voxel(W)) :- voxel_terrain_binding(W,_,_).
gui_children(voxel_excavation(W),[voxel_brush(W,x),voxel_brush(W,y),voxel_brush(W,z),
                                voxel_brush(W,radius),dig_voxel(W)]).
attribute(voxel_excavation(_),label,<<"Dig terrain">>).
attribute(voxel_excavation(_),help,<<"Remove a sphere of ground at these world coordinates. Changes are saved when you submit.">>).
attribute(voxel_brush(_,x),label,<<"East / west">>).
attribute(voxel_brush(_,y),label,<<"Height">>).
attribute(voxel_brush(_,z),label,<<"North / south">>).
attribute(voxel_brush(_,radius),label,<<"Radius">>).
attribute(voxel_brush(_,_),unit,millimetres).
attribute(voxel_brush(W,Key),range,Range) :-
    findall(controls(C,R),voxel_brush_controls(W,C,R),[controls(Coordinates,Radius)]),
    (Key = radius -> Range = Radius ; member(Key,[x,y,z]),Range = Coordinates).
attribute(dig_voxel(_),label,<<"Dig">>).
gui_initial(voxel_excavation(_),voxel_brush(_,Key),0) :- member(Key,[x,y,z]).
gui_initial(voxel_excavation(W),voxel_brush(_,radius),Min) :-
    voxel_brush_controls(W,_,range(Min,_,_)).
gui_form(voxel_excavation(W),
    [field(voxel_brush(W,x),X),field(voxel_brush(W,y),Y),field(voxel_brush(W,z),Z),
     field(voxel_brush(W,radius),Radius)],
    submit(dig_voxel(W),voxel_excavation_entered(W,Revision,Versions,X,Y,Z,Radius))) :-
    voxel_world_state(W,Revision,Spec),Spec \= none,voxel_patch_versions(W,Versions).
voxel_excavation_entered(W,Revision,Versions,X,Y,Z,Radius) :-
    transaction((voxel_expected_world(W,Revision,_),voxel_patch_versions(W,Current),
        (Versions = Current -> true ; fail_with_reason(voxel_patch_conflict(W))),
        Brush = dig_sphere(vector(X,Y,Z),Radius),
        voxel_edit_basis(W,Brush,Revision,Affected),voxel_edit(W,Revision,Affected,Brush))).

%% Compose voxel_world_view.pl to expose viewing distance through the same
%% form tree. Prefetch/retention and allocation remain authored view policy.
instance_of(quod:gui:form,voxel_view_settings(W)) :- voxel_terrain_binding(W,_,_).
instance_of(quod:gui:number_input,voxel_distance(W)) :- voxel_terrain_binding(W,_,_).
instance_of(quod:gui:button,apply_voxel_view(W)) :- voxel_terrain_binding(W,_,_).
gui_children(voxel_view_settings(W),[voxel_distance(W),apply_voxel_view(W)]).
attribute(voxel_view_settings(_),label,<<"Terrain view">>).
attribute(voxel_distance(_),label,<<"Viewing distance">>).
attribute(voxel_distance(_),unit,metres).
attribute(voxel_distance(W),range,Range) :- voxel_view_range(W,Range).
attribute(apply_voxel_view(_),label,<<"Apply">>).
gui_initial(voxel_view_settings(W),voxel_distance(_),Metres) :-
    voxel_presentation(W,_,_,view_distance(Distance,_,_),_),Metres is Distance//1000.
gui_form(voxel_view_settings(W),[field(voxel_distance(W),Metres)],
    submit(apply_voxel_view(W),voxel_view_entered(W,Before,Metres))) :-
    findall(V,voxel_presentation(W,_,_,V,_),[Before]).
voxel_view_entered(W,Before,Metres) :-
    Before = view_distance(_,Prefetch,Retention),Distance is Metres*1000,
    voxel_set_view(W,Before,view_distance(Distance,Prefetch,Retention)).
