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
lobby_recipe(Mode, Subject,
    [part(<<"floor">>, cylinder(10000, 100), transform(0, -50, 0, 0, 0, 0),
          pbr(<<"#0B3954">>, 300, 850, 0), unlabelled, depicts_nothing),
     part(<<"console">>, group, transform(0, 0, 0, 0, 0, 0),
          no_surface, unlabelled, Subject),
     part(<<"pedestal">>, cylinder(460, 850),
          relative(<<"console">>, transform(0, 425, 0, 0, 0, 0)),
          pbr(<<"#848FA5">>, 700, 350, 0), unlabelled, depicts_nothing),
     part(<<"body">>, box(1600, 1000, 160),
          relative(<<"console">>, transform(0, 1400, 0, 0, 0, 0)),
          Body, unlabelled, depicts_nothing),
     part(<<"screen">>, plane(1440, 820),
          relative(<<"body">>, ScreenAt),
          pbr(<<"#17557A">>, 0, 900, 600), unlabelled, depicts_nothing),
     part(<<"status">>, sphere(55),
          relative(<<"body">>, transform(700, -465, -95, 0, 0, 0)),
          pbr(<<"#F9C80E">>, 0, 500, 1000), unlabelled, depicts_nothing),
     part(<<"console-label">>, group,
          relative(<<"body">>, transform(0, 640, 0, 0, 0, 0)),
          no_surface, label(Label, <<"centre">>), depicts_nothing)]) :-
    console_surface(Mode, Body, Label),
    presentation_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                align(plane(1440, 820), centre, box(1600, 1000, 160), front, 5, ScreenAt)).

console_surface(playing, pbr(<<"#0B3954">>, 750, 250, 0), <<"PROLOG CONSOLE">>).
console_surface(edition, pbr(<<"#F9C80E">>, 0, 850, 200), <<"CONSOLE STRUCTURE">>).
