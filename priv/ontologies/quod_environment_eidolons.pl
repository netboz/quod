%% Reusable eidolons for environment classes. The output uses only the
%% renderer-neutral geometry, surface and asset vocabulary.
acl_sovereign(quod:environment:eidolons).

can_invoke(Goal, _, _, _) :- eidolon_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- eidolon_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

eidolon_query(class_eidolon(_, _, _, _)).
eidolon_query(eidolon(_, _, _)).
eidolon_query(panorama_asset(_, _, _)).

class_eidolon(Class, Mode, panoramic, recipe(Ns, Anchor, sky_sphere_panoramic)) :-
    environment_eidolon(Class, Mode, sky_sphere_panoramic),
    current_ontology_identity(Ns, Anchor).

environment_eidolon(sky_sphere, playing, sky_sphere_panoramic).
environment_eidolon(sky_sphere, edition, sky_sphere_panoramic).

eidolon(sky_sphere_panoramic,
        environment(sky(Entity, Panorama, Diameter, Rotation, Brightness, Tint), Ns, Anchor),
        [part(<<"sky">>, sky_sphere(Diameter), transform(0, 0, 0, 0, Rotation, 0),
              Surface, unlabelled, depicts(Ns, Anchor, Entity))]) :-
    panorama_asset(Panorama, Asset, _),
    Surface = surface(Tint, 0, 1000, Brightness,
                      [texture(<<"base_colour">>, Asset, repeat(1000, 1000))]).

panorama_asset(belfast_sunset_puresky,
    asset(<<"d47c2b1b40f651cab5b4b151c92b66b788ceb2d57e2056a0ce7c469f333c23f4">>, <<"image/jpeg">>),
    source(<<"https://dl.polyhaven.org/file/ph-assets/HDRIs/extra/Tonemapped%20JPG/belfast_sunset_puresky.jpg">>, <<"CC0-1.0">>)).
