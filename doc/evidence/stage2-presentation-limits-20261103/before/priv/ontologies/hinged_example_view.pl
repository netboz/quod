%% Authored ordinary-view recipe for the hinged examples. A body-bound group
%% receives its pose only from the existing signed simulation stream; appearance
%% parts retain their authored local attachment frames.
hinged_example_view(W, Marks) :-
    findall(object(D, Id, Subject, Parts),
            hinged_example_appearance(W, D, Id, Subject, Parts), Objects),
    hinged_example_marks(Objects, W, Marks).

hinged_example_marks([], _, []).
hinged_example_marks([object(D, Id, Subject, Parts) | Rest], W,
    [mark(Id, <<"group">>, [], body_pose(D, Revision), no_surface,
          label(Text, <<"above">>), depicts(Ns, Anchor, Subject)) | Marks]) :-
    current_ontology_identity(Ns, Anchor),
    findall(R, physics_body_definition(W, D, R, _, _, _), [Revision]),
    findall(S, physics_hinged(W, D, _, S), [State]),
    hinged_example_label(State, Text),
    hinged_example_parts(Parts, Id, Appearance),
    hinged_example_marks(Rest, W, Following), append(Appearance, Following, Marks).

hinged_example_parts([], _, []).
hinged_example_parts([part(Id, Kind, Fields, At, Surface) | Rest], Parent,
    [mark(Id, Kind, Fields, relative(Parent, At), Surface,
          unlabelled, depicts_nothing) | Marks]) :-
    hinged_example_parts(Rest, Parent, Marks).

hinged_example_label(idle, <<"Ready to close">>).
hinged_example_label(closing(_), <<"Closing">>).
hinged_example_label(cancelled(_), <<"Cancelled">>).
hinged_example_label(finished(_, closed), <<"Closed">>).
hinged_example_label(finished(_, blocked(_)), <<"Blocked">>).
