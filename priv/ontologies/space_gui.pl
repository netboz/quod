%% Authored Create forms. The shared GUI binder invokes the normal assertion;
%% the space constructor and committed class policy own every consequence.
class_eidolon(space, operation(class), create, recipe(Ns, A, space_create)) :-
    current_ontology_identity(Ns, A).
class_eidolon(space, operation(class), create_infinite, recipe(Ns, A, space_create_infinite)) :-
    current_ontology_identity(Ns, A).
eidolon(space_create, subject(ontology_ref(Ns, A), class(space)), operation(space_create(finite))) :-
    current_ontology_identity(Ns, A).
eidolon(space_create_infinite, subject(ontology_ref(Ns, A), class(space)), operation(space_create(infinite))) :-
    current_ontology_identity(Ns, A).

instance_of(quod:gui:form, space_create(Extent)) :- member(Extent, [finite, infinite]).
instance_of(quod:gui:text_box, space_name).
instance_of(quod:gui:selection, space_placement).
instance_of(quod:gui:number_input, space_length(Axis)) :- member(Axis, [width,height,depth]).
instance_of(quod:gui:selection, space_unit).
instance_of(quod:gui:button, space_create_submit).
attribute(space_create(finite), label, <<"Create space">>).
attribute(space_create(infinite), label, <<"Create infinite space">>).
attribute(space_name, label, <<"Name">>).
attribute(space_name, help, <<"The class default is supplied. Change it to use your own name.">>).
attribute(space_name, required, true).
attribute(space_placement, label, <<"Placement">>).
attribute(space_placement, options, Options) :-
    current_ontology_identity(Ns, A),
    findall(option(at(entity_ref(Ns,A,S),transform(0,0,0,0,0,0)), Label),
        (space_instance(S,space), attribute(S,name,Label)), Destinations),
    append([option(near_agent, <<"Near my agent, or unplaced when my agent is unplaced">>)], Destinations, Options).
attribute(space_length(width), label, <<"Width (X)">>).
attribute(space_length(height), label, <<"Height (Y)">>).
attribute(space_length(depth), label, <<"Depth (Z)">>).
attribute(space_length(_), range, range(1,1000000,1)).
attribute(space_unit, label, <<"Length unit">>).
attribute(space_unit, options, [option(<<"mm">>,<<"Millimetres">>),option(<<"cm">>,<<"Centimetres">>),
    option(<<"m">>,<<"Metres">>),option(<<"km">>,<<"Kilometres">>)]).
attribute(space_create_submit, label, <<"Create">>).
gui_children(space_create(Extent), Children) :-
    (Extent = finite -> Lengths = [space_length(width),space_length(height),space_length(depth),space_unit]
    ; Extent = infinite, Lengths = []),
    append([space_name|Lengths], [space_placement,space_create_submit], Children).
gui_initial(space_create(_), space_name, Name) :- have_attribute(space,name,binary,default(Name)).
gui_initial(space_create(_), space_placement, near_agent).
gui_initial(space_create(finite), space_unit, Unit) :-
    have_attribute(space,dimensions,space_dimensions,default(box(q(_,Unit),q(_,Unit),q(_,Unit)))).
gui_initial(space_create(finite), space_length(Axis), Value) :-
    have_attribute(space,dimensions,space_dimensions,default(box(q(W,_),q(H,_),q(D,_)))),
    member(Axis-Value, [width-W,height-H,depth-D]).
gui_form(space_create(Extent), Fields,
    submit(space_create_submit, (with_build_plan(Inputs, assert(instance_of(space, Space))), space_location(Space,Location)),
        operation(create(Inputs), [result(space,entity_ref(Ns,A,Space)),result(location,Location)]))) :-
    current_ontology_identity(Ns,A),
    (Extent = finite ->
        Dimensions = box(q(W,Unit),q(H,Unit),q(D,Unit)),
        Lengths = [field(space_length(width),W),field(space_length(height),H),field(space_length(depth),D),field(space_unit,Unit)]
    ; Extent = infinite, Dimensions = infinite, Lengths = []),
    append([field(space_name,Name)|Lengths], [field(space_placement,Placement)], Fields),
    Inputs = [attribute(name,Name),attribute(dimensions,Dimensions),attribute(placement,Placement)].
