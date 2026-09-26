%% Surface recipes use the existing renderer-neutral optical vocabulary.
%% Colours are authored appearances, not measurements of physical substances.
acl_sovereign(quod_material_eidolons).
can_invoke(Goal, _, _, _) :- eidolon_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- eidolon_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

eidolon_query(class_eidolon(_, _, _, _)).
eidolon_query(eidolon(_, _, _)).
eidolon_query(instance_of(_, _)).
eidolon_query(texture_asset(_, _, _, _)).

surface_recipe(wood, solid, warm_wood, surface(<<"#93613D">>,0,700,0,[])).
surface_recipe(oak_wood, solid, oak, Surface) :- textured_surface(wood_table_001, 1000, Surface).
surface_recipe(stone, solid, stone, surface(<<"#918477">>,0,900,0,[])).
surface_recipe(marble, solid, marble, Surface) :- textured_surface(floor_tiles_02, 2500, Surface).
surface_recipe(metal, solid, metal, surface(<<"#919DA0">>,1000,350,0,[])).
surface_recipe(bronze, solid, bronze, surface(<<"#AE8051">>,1000,400,0,[])).

%% A more specific material class wins. Incomparable alternatives or two
%% recipes at the same specificity have no unique answer; order cannot decide.
class_eidolon(Material, playing, Style, recipe(Ns, Anchor, Recipe)) :-
    material_vocabulary(MaterialNs, MaterialAnchor),
    findall(candidate(Class, Id), surface_recipe(Class, Style, Id, _), Candidates),
    findall(Class, member(candidate(Class, _), Candidates), Classes),
    MaterialNs::(current_ontology_identity(MaterialNs, MaterialAnchor),
                 most_specific_materials(Material, Classes, Selected)),
    findall(Id, (member(candidate(Class, Id), Candidates), member(Class, Selected)), Ids),
    sort(Ids, [Recipe]), current_ontology_identity(Ns, Anchor).

eidolon(Recipe, material(Material), Surface) :-
    surface_recipe(Class, _, Recipe, Surface), material_vocabulary(Ns, Anchor),
    Ns::(current_ontology_identity(Ns, Anchor), material_kind(Material, Class)).

instance_of(surface_eidolon, Recipe) :- surface_recipe(_, _, Recipe, _).

texture_asset(wood_table_001, <<"base_colour">>,
    asset(<<"460dd08d240f4a1f02982415048c3c5c200f385db212da18dc7e2df68bf4d0be">>, <<"image/jpeg">>),
    source(<<"https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/wood_table_001/wood_table_001_diff_1k.jpg">>, <<"CC0-1.0">>)).

texture_asset(wood_table_001, <<"normal">>,
    asset(<<"9bf7ddf5721e225c20290f1772ae37f9bdfd49658f6d458259eb794e2149d3cf">>, <<"image/jpeg">>),
    source(<<"https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/wood_table_001/wood_table_001_nor_gl_1k.jpg">>, <<"CC0-1.0">>)).

texture_asset(wood_table_001, <<"orm">>,
    asset(<<"29d3f34a7c2c213e21b320365495fad673d3c8a3ce885b879fc0a77a187dd828">>, <<"image/jpeg">>),
    source(<<"https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/wood_table_001/wood_table_001_arm_1k.jpg">>, <<"CC0-1.0">>)).

texture_asset(floor_tiles_02, <<"base_colour">>,
    asset(<<"05988d474ecb1f9cd48e65d978db88212252ef8b5af8ed3833395c1f86b2b469">>, <<"image/jpeg">>),
    source(<<"https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/floor_tiles_02/floor_tiles_02_diff_1k.jpg">>, <<"CC0-1.0">>)).

texture_asset(floor_tiles_02, <<"normal">>,
    asset(<<"5ce11f7e5f12a1d61588f226a79e27eb8b57b95d2f95d1d6cbde613110696669">>, <<"image/jpeg">>),
    source(<<"https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/floor_tiles_02/floor_tiles_02_nor_gl_1k.jpg">>, <<"CC0-1.0">>)).

texture_asset(floor_tiles_02, <<"orm">>,
    asset(<<"e03673c57b47c2ce436d8cd3851ff1030e1304162d16c47e82c54721e5c17479">>, <<"image/jpeg">>),
    source(<<"https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/floor_tiles_02/floor_tiles_02_arm_1k.jpg">>, <<"CC0-1.0">>)).

textured_surface(Asset, Repeat, surface(<<"#FFFFFF">>, 0, 1000, 0, Textures)) :-
    findall(texture(Slot, Ref, repeat(Repeat, Repeat)), texture_asset(Asset, Slot, Ref, _), Textures).
