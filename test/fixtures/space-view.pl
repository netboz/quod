entity_scene(artifact, playing,
        appearance(<<"manuscript">>, solid, Title,
                   transform(100,200,300,0,45,0), Eidolons)) :-
    attribute(artifact, title, Title),
    entity_eidolons(artifact, playing, solid, Eidolons).
class_eidolon(manuscript, playing, solid, recipe(Ns, Anchor, manuscript)) :-
    current_ontology_identity(Ns, Anchor).
eidolon(manuscript, Title,
    [part(<<"title">>, group, transform(0,0,0,0,0,0),
          no_surface, label(Title,<<"above">>), depicts_nothing)]).
