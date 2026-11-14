%% The class and its behavior live here. Instances, slots and ACLs remain in
%% their storing ontologies; every read and write uses their exact references.
can_invoke(Goal, _, _, _) :- space_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- space_query(Goal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).
space_query(isa(_, _)).
space_query(have_attribute(_, _, _, _)).
space_query(have_attribute(_, _, _)).
space_query('$quod_constructor_metadata'(_, _, _)).
space_query(attribute_value(Type, _)) :-
    member(Type, [binary,space_dimensions,space_owner,space_transform,space_exterior,space_interior]).
space_query(class_permission(_, _, _)).
space_query(class_requirement(_, _, _)).
space_query(class_eidolon(_, _, _, _)).
space_query(eidolon(_, _, _)).
space_query(gui_definition(_, _, _, _, _, _)).
space_query(gui_initial_values(_, _, _, _)).
space_query(gui_bind_values(_, _, _, _, _)).
space_query(gui_form_caption(_, _, _, _, _)).
space_query(space_instance(_, _)).
space_query(space_assignment(_, _, _)).
space_query(space_location(_, _)).
space_query(space_contains(_, _)).
space_query(space_projection(_, _, _)).
space_query(space_contents_projection(_, _)).
space_query(world_view(_, _, _)).
space_query(space_exposure_projection(_, _, _, _)).
space_query(space_simulation_domain(_, _, _, _)).
space_query(space_creator_owner(_, _)).
space_query(space_name(_, _)).
space_query(space_dimensions(_)).
space_query(space_owner(_)).
space_query(space_transform(_)).
space_query(space_exterior(_)).
space_query(space_interior(_)).
space_query(goal(inside(_, _, _))).
space_query(goal(unplaced(_))).
space_query(goal(shown_in(_, _))).
space_query(goal(not_shown_in(_, _))).
space_query(space_represent(_, _, _, _, _, _, _)).
space_query(space_form_placement(_, _, _)).
space_query(Goal) :- public_source_query(Goal).

isa(space, thing).
isa(physical_space, space).
class_permission(space, Operation, allow) :-
    member(Operation, [create,space_enter,space_admit,space_leave,space_remove,space_visit,space_represent]).
have_attribute(space, name, binary, default_from(space_name)).
have_attribute(space, dimensions, space_dimensions,
    default(box(q(10, <<"m">>), q(10, <<"m">>), q(10, <<"m">>)))).
have_attribute(space, owner, space_owner, default_from(space_creator_owner)).
have_attribute(space, transform, space_transform, default(transform(0,0,0,0,0,0))).
have_attribute(space, exterior, space_exterior, default(solid)).
have_attribute(space, interior, space_interior, default(none)).

space_dimensions(infinite).
space_dimensions(box(Width, Height, Depth)) :-
    unique_solution(measure_vocabulary(Ns,Anchor)),
    space_length(Ns, Anchor, Width), space_length(Ns, Anchor, Height),
    space_length(Ns, Anchor, Depth).
space_length(Ns, Anchor, q(Value, Unit)) :-
    binary(Unit), in_ontology(Ns,Anchor, convert(Value, Unit, <<"m">>, Metres)),
    (integer(Metres) -> Metres > 0
    ; Metres = N / D, integer(N), integer(D), N > 0, D > 0).
space_owner(agent_instance_ref(Ns, Anchor, Entity)) :-
    binary(Ns), binary(Anchor), term_variables(Entity, []).
space_creator_owner(_, Owner) :-
    quod:user::personal_agent_owner(Owner).
%% A space given no name takes a place name; quod:names owns the pools.
space_name(Instance, Name) :-
    quod:names::draw(<<"place">>, Instance, Name).
space_transform(transform(X, Y, Z, RX, RY, RZ)) :-
    integer(X), integer(Y), integer(Z), integer(RX), integer(RY), integer(RZ).

space_location(Subject, Location) :-
    Subject = entity_ref(Ns, Anchor, Entity),
    in_ontology(Ns,Anchor,instance_of(_, Entity)), space_assignment(Subject, _, Destination),
    (Destination == none -> Location = unplaced
    ; in_ontology(Ns,Anchor,unique_solution(attribute(Entity,transform,Transform))),
      space_transform(Transform), Location = placed(Destination, Transform)).

%% An omitted pose is resolved relative to the acting personal agent, at
%% the near distance along negative Z. On that line the new thing takes the
%% first free place, so it never lands on a thing already placed there and
%% never moves one.
placement_pose(Destination, Pose) :-
    (nonvar(Pose) -> space_transform(Pose)
    ; quod:user::personal_agent(Agent, _),
      Agent = agent_instance_ref(Ns,A,Entity),
      space_location(entity_ref(Ns,A,Entity), placed(Destination,transform(X,Y,Z,RX,RY,RZ))),
      space_near(Size, Near),
      NearZ is Z - Near,
      Destination = entity_ref(DNs,DA,D),
      in_ontology(DNs,DA,findall(Subject,space_placement(D,Subject,_),Placed)),
      findall(Taken,(member(Subject,Placed),space_location(Subject,placed(Destination,Taken))),Poses),
      space_free_place(0,X,Y,NearZ,Size,Poses,FreeX),
      Pose = transform(FreeX,Y,NearZ,RX,RY,RZ)).
%% Near: Yan's chosen two metres plus half the shared marker's depth, between
%% an agent and a thing in front of it. The marker stands for the space
%% outside, whatever it measures inside.
space_near(Size, Near) :-
    unique_solution(scene_vocabulary(Scene,Anchor)),
    in_ontology(Scene,Anchor,marker_size(Size)),
    Near is 2000 + Size // 2.
%% Candidates run straight ahead, then alternately right and left, one and a
%% half markers apart. A place is free when no placed thing whose location
%% can be read stands within one marker of it on every axis.
space_free_place(Index, X, Y, Z, Size, Poses, Free) :-
    Side is (Index + 1) // 2 * (Size * 3 // 2),
    (Index mod 2 =:= 1 -> Candidate is X + Side; Candidate is X - Side),
    (member(transform(TX,TY,TZ,_,_,_), Poses),
     abs(TX - Candidate) < Size, abs(TY - Y) < Size, abs(TZ - Z) < Size ->
        Next is Index + 1, space_free_place(Next, X, Y, Z, Size, Poses, Free)
    ; Free = Candidate).

space_subject(entity_ref(Ns, Anchor, Entity), Subject) :-
    in_ontology(Ns,Anchor,
        (instance_of(_, Entity) -> Subject = instance(Entity)
        ; isa(Entity, Entity), Subject = class(Entity))).
space_authorized(Reference, Name, Other, Mode) :-
    Reference = entity_ref(Ns, Anchor, _), space_subject(Reference, Subject),
    Operation =.. [Name, Reference, Other, Mode],
    in_ontology(Ns,Anchor,operation_authorized(Subject, Operation)).

space_assignment(entity_ref(Ns, Anchor, Entity), Revision, Destination) :-
    in_ontology(Ns,Anchor,findall(assignment(R,D),space_assignment_state(Entity,R,D),Rows)),
    (Rows = [] -> R0 = 0, D0 = none
    ; Rows = [assignment(R0,D0)] -> true
    ; fail_with_reason(ambiguous_space_assignment(Entity))),
    Revision = R0, Destination = D0.
inside(Space, Entity, Pose) :-
    Space = entity_ref(_,_,_),
    space_assignment(Entity, _, Space), Entity = entity_ref(Ns,A,Id),
    in_ontology(Ns,A,attribute(Id,transform,Pose)).
unplaced(Entity) :- space_assignment(Entity, _, none).
action(place(Space, Entity, Pose),
       [goal(unplaced(Entity)), placement_pose(Space, Pose),
        space_authorized(Entity, space_enter, Space, placement),
        space_authorized(Space, space_admit, Entity, placement)],
       inside(Space, Entity, Pose)).
action(withdraw(Entity),
       [space_assignment(Entity, _, Space), Space \== none,
        space_authorized(Entity,space_leave,Space,placement)],
       unplaced(Entity)).

place(Space, Entity, Pose) :-
    term_variables([Space,Entity,Pose],[]), Space \== Entity,
    space_instance(Space,space), space_assignment(Entity,Before,none),
    Entity = entity_ref(Ns,A,Id), Space = entity_ref(SNs,SA,S),
    Revision is Before + 1,
    in_ontology(Ns,A,(
        instance_of(_,Id),
        (Before = 0 -> true; retract(space_assignment_state(Id,Before,none))),
        findall(Old,attribute(Id,transform,Old),Poses),
        (Poses = [] -> true; Poses = [Old], retract(attribute(Id,transform,Old))),
        assertz(attribute(Id,transform,Pose)),
        assertz(space_assignment_state(Id,Revision,Space)))),
    space_change_physics(Space,Entity,admitted),
    in_ontology(SNs,SA,(\+ space_placement(S,Entity,_),assertz(space_placement(S,Entity,Revision)))).
withdraw(Entity) :-
    space_assignment(Entity,Before,Space), Space = entity_ref(SNs,SA,S),
    Entity = entity_ref(Ns,A,Id), Revision is Before + 1,
    in_ontology(Ns,A,(
        retract(space_assignment_state(Id,Before,Space)),
        assertz(space_assignment_state(Id,Revision,none)))),
    space_change_physics(Space,Entity,withdrawn),
    in_ontology(SNs,SA,retract(space_placement(S,Entity,Before))).

shown_in(entity_ref(Ns,A,Space), Entity) :- in_ontology(Ns,A,space_member(Space,Entity)).
not_shown_in(Space, Entity) :- \+ shown_in(Space,Entity).
action(show(Space,Entity),
       [space_instance(Space,space), Space \== Entity,
        space_authorized(Entity,space_enter,Space,display),
        space_authorized(Space,space_admit,Entity,display)], shown_in(Space,Entity)).
action(hide(Space,Entity),
       [space_removal_allowed(Space,Entity,display)], not_shown_in(Space,Entity)).
show(entity_ref(Ns,A,Space),Entity) :- in_ontology(Ns,A,assertz(space_member(Space,Entity))).
hide(entity_ref(Ns,A,Space),Entity) :- in_ontology(Ns,A,retract(space_member(Space,Entity))).
space_removal_allowed(Space,Entity,Mode) :-
    (space_authorized(Space,space_remove,Entity,Mode) -> true
    ; space_authorized(Entity,space_leave,Space,Mode)).

space_change_physics(Space, Subject, Change) :-
    Space = entity_ref(Ns,A,Id),
    ((space_instance(Space, physical_space); space_simulation_domain(Space,_,_,_)
      ; Change == withdrawn, in_ontology(Ns,A,physics_body_definition(Id,_,_,_,_,live(Subject,_,_,_)))) ->
        (space_physical_change(Space,Subject,Change) -> true
        ; fail_with_reason(space_physical_change_refused(Space,Change)))
    ; true).
space_physical_change(entity_ref(Ns,A,Space),Subject,Change) :-
    in_ontology(Ns,A,space_physical_change(Space,Subject,Change)).

space_represent(Subject,BeforeStyle,BeforePose,BeforeInterior,Style,Pose,Interior) :-
    term_variables([Subject,BeforeStyle,BeforePose,BeforeInterior,Style,Pose,Interior],[]),
    Subject = entity_ref(Ns,A,Space),
    transaction((space_instance(Subject,space),space_transform(Pose),space_interior(Interior),
        (Style == BeforeStyle -> true; space_exterior(Style)),
        space_authorized_representation(Subject,BeforeStyle,BeforePose,BeforeInterior,Style,Pose,Interior),
        in_ontology(Ns,A,unique_solution((attribute(Space,exterior,BeforeStyle),attribute(Space,transform,BeforePose)))),
        space_interior_of(Subject,BeforeInterior),
        in_ontology(Ns,A,attribute(Space,dimensions,Dimensions)),
        space_interior_available(Interior,Dimensions),
        (BeforeInterior == Interior -> true
        ; in_ontology(Ns,A,((BeforeInterior == none -> true; retract(attribute(Space,interior,BeforeInterior))),
                           (Interior == none -> true; assertz(attribute(Space,interior,Interior)))))),
        (BeforeStyle == Style, BeforePose == Pose -> true
        ; in_ontology(Ns,A,(
            retract(attribute(Space,exterior,BeforeStyle)),assertz(attribute(Space,exterior,Style)),
            retract(attribute(Space,transform,BeforePose)),assertz(attribute(Space,transform,Pose)))),
          space_assignment(Subject,_,Destination),
          (Destination == none -> true; space_representation_changed(Destination,Subject))))).
space_authorized_representation(entity_ref(Ns,A,Space),BeforeStyle,BeforePose,BeforeInterior,Style,Pose,Interior) :-
    in_ontology(Ns,A,operation_authorized(instance(Space),
        space_represent(BeforeStyle,BeforePose,BeforeInterior,Style,Pose,Interior))).
space_interior_of(entity_ref(Ns,A,Space),Interior) :-
    in_ontology(Ns,A,findall(I,attribute(Space,interior,I),Rows)),
    (Rows = [] -> Interior = none
    ; Rows = [Interior] -> true
    ; fail_with_reason(ambiguous_space_interior(Space))).
space_interior_boundary(Space,Recipe) :-
    space_interior_of(Space,Interior), space_interior_recipe(Interior,Recipe).
space_representation_changed(Space,Subject) :-
    Space = entity_ref(Ns,A,Id), in_ontology(Ns,A,space_placement(Id,Subject,Assignment)),
    space_assignment(Subject,Assignment,Space), space_change_physics(Space,Subject,represented).

%% The form goal asserts the instance and reaches its placement in one
%% transaction. The shared assertion hook supplies slots and class policy.
class_eidolon(space,operation(class),Name,recipe(Ns,A,Recipe)) :-
    space_creation_recipe(Name,Recipe,_), current_ontology_identity(Ns,A).
eidolon(Recipe,subject(Store,class(Class)),operation(space_create(Store,Extent))) :-
    current_ontology_identity(Ns,_),
    once((isa(Class,Parent), '$quod_qualified_class'(Ns,Parent,Owned),
          '$quod_owner_name'(Owned,Owner,space), ontology_name(Owner,Ns))),
    space_creation_recipe(_,Recipe,Extent).
space_creation_recipe(create,space_create,finite).
space_creation_recipe(create_exact,space_create_exact,exact).
space_creation_recipe(create_infinite,space_create_infinite,infinite).

instance_of(quod:gui:form, space_create(ontology_ref(_, _),Extent)) :- member(Extent, [finite, exact, infinite]).
instance_of(quod:gui:text_box, space_name).
instance_of(quod:gui:selection, space_placement(ontology_ref(_, _))).
instance_of(quod:gui:number_input, space_length(Axis)) :- member(Axis, [width,height,depth]).
instance_of(quod:gui:number_input, space_divisor(Axis)) :- member(Axis, [width,height,depth]).
instance_of(quod:gui:selection, space_unit).
instance_of(quod:gui:button, space_create_submit).
attribute(space_create(_,finite), label, <<"Create space">>).
attribute(space_create(_,exact), label, <<"Create space with rational lengths">>).
attribute(space_create(_,infinite), label, <<"Create infinite space">>).
attribute(space_create(_,finite), image, Icon) :- menu_icon(create_finite, Icon).
attribute(space_create(_,exact), image, Icon) :- menu_icon(create_exact, Icon).
attribute(space_create(_,infinite), image, Icon) :- menu_icon(create_infinite, Icon).
attribute(space_create(_,_), help, <<"The personal agent's human is the default owner, independently of the selected storage and placement. Creation does not enter the new space.">>).
attribute(space_name, label, <<"Name">>).
attribute(space_name, help, <<"A place name is suggested. Change it to use your own.">>).
attribute(space_name, required, false).
attribute(space_placement(_), label, <<"Placement">>).
attribute(space_placement(ontology_ref(Ns,A)), options, Options) :-
    findall(option(at(entity_ref(Ns,A,S),transform(0,0,0,0,0,0)), Label),
        (space_instance(entity_ref(Ns,A,S),space),in_ontology(Ns,A,attribute(S,name,Label))), Destinations),
    append([option(near_agent, <<"Near my agent, or unplaced when my agent is unplaced">>),
            option(unplaced, <<"Unplaced">>)], Destinations, Options).
attribute(space_length(width), label, <<"Width (X)">>).
attribute(space_length(height), label, <<"Height (Y)">>).
attribute(space_length(depth), label, <<"Depth (Z)">>).
attribute(space_length(_), range, range(1,1000000,1)).
attribute(space_divisor(Axis), label, Label) :-
    member(Axis-Label,[width - <<"Width divisor">>,height - <<"Height divisor">>,depth - <<"Depth divisor">>]).
attribute(space_divisor(_), help, <<"The length is the numerator divided by this positive integer, in the selected unit.">>).
attribute(space_divisor(_), range, range(1,1000000,1)).
attribute(space_unit, label, <<"Length unit">>).
attribute(space_unit, options, [option(<<"mm">>,<<"Millimetres">>),option(<<"cm">>,<<"Centimetres">>),
    option(<<"m">>,<<"Metres">>),option(<<"km">>,<<"Kilometres">>)]).
attribute(space_create_submit, label, <<"Create">>).
gui_children(space_create(Store,Extent), Children) :-
    space_form_lengths(Extent,Fields,_),
    findall(Role,member(field(Role,_),Fields),Lengths),
    append([space_name|Lengths], [space_placement(Store),space_create_submit], Children).
gui_initial(space_create(_,_), space_name, Name) :- quod:names::draw(<<"place">>, form, Name).
gui_initial(space_create(Store,_), space_placement(Store), near_agent).
gui_initial(space_create(_,Extent), space_unit, Unit) :-
    member(Extent,[finite,exact]),
    have_attribute(space,dimensions,space_dimensions,default(box(q(_,Unit),q(_,Unit),q(_,Unit)))).
gui_initial(space_create(_,Extent), space_length(Axis), Value) :-
    member(Extent,[finite,exact]),
    have_attribute(space,dimensions,space_dimensions,default(box(q(W,_),q(H,_),q(D,_)))),
    member(Axis-Value, [width-W,height-H,depth-D]).
gui_initial(space_create(_,exact), space_divisor(_), 1).
gui_form(space_create(Store,Extent), Fields,
    submit(space_create_submit,
        (current_ontology_identity(Ns,A),
         with_build_plan(Inputs, assert(instance_of(quod:space:space, Space))),
         quod:space::space_form_placement(entity_ref(Ns,A,Space),Placement,Location),attribute(Space,owner,Owner)),
        operation(create(Inputs), [result(space,entity_ref(Ns,A,Space)),result(location,Location),result(owner,Owner)]))) :-
    Store = ontology_ref(Ns,A),
    space_form_lengths(Extent,Lengths,Dimensions),
    append([field(space_name,Name)|Lengths], [field(space_placement(Store),Placement)], Fields),
    Inputs = [attribute(name,Name),attribute(dimensions,Dimensions)].
%% The form's choice selects the same ordinary placement action as any caller.
%% The instance was asserted by the form goal in its selected storing ontology.
space_form_placement(Subject, Requested, Location) :-
    (Requested = unplaced -> goal(unplaced(Subject))
    ; Requested = at(Destination,Pose) -> goal(inside(Destination,Subject,Pose))
    ; Requested = near_agent, quod:user::personal_agent(agent_instance_ref(Ns,A,Agent),_),
      space_location(entity_ref(Ns,A,Agent),AgentLocation),
      (AgentLocation = unplaced -> goal(unplaced(Subject))
      ; AgentLocation = placed(Destination,_), goal(inside(Destination,Subject,_)))),
    space_location(Subject,Location).
space_form_lengths(finite,
    [field(space_length(width),W),field(space_length(height),H),field(space_length(depth),D),field(space_unit,Unit)],
    box(q(W,Unit),q(H,Unit),q(D,Unit))).
space_form_lengths(exact,
    [field(space_length(width),W),field(space_divisor(width),WD),
     field(space_length(height),H),field(space_divisor(height),HD),
     field(space_length(depth),D),field(space_divisor(depth),DD),field(space_unit,Unit)],
    box(q(W/WD,Unit),q(H/HD,Unit),q(D/DD,Unit))).
space_form_lengths(infinite,[],infinite).

%% Entry is another exact-subject offered operation. Its frozen source slot
%% enters the ordinary form revision; a stale offer cannot move a newer slot.
class_eidolon(space,operation(instance),enter,recipe(Ns,A,space_enter)) :-
    current_ontology_identity(Ns,A).
class_eidolon(space,operation(instance),leave,recipe(Ns,A,space_leave)) :-
    current_ontology_identity(Ns,A).
eidolon(space_enter,subject(ontology_ref(Ns,A),instance(Space)),operation(Form)) :-
    space_travel_context(Agent,Revision,Before), Destination = entity_ref(Ns,A,Space),
    Before \== Destination,
    Form = space_travel_form(Agent,Revision,Before,placed(Destination,transform(0,0,0,0,0,0))).
eidolon(space_leave,subject(ontology_ref(Ns,A),instance(Space)),operation(Form)) :-
    space_travel_context(Agent,Revision,entity_ref(Ns,A,Space)),
    space_leave_to(entity_ref(Ns,A,Space),After),
    Form = space_travel_form(Agent,Revision,entity_ref(Ns,A,Space),After).
%% Leaving a space that stands in another returns to that one, where a
%% creator of the space stood: near in front of its marker, facing it. A
%% space that stands nowhere is left for nowhere. A parent that refuses the
%% agent refuses the leave; it never falls back to nowhere.
space_leave_to(Space,After) :-
    space_assignment(Space,_,Parent),
    (Parent == none -> After = unplaced
    ; space_location(Space,placed(Parent,transform(X,Y,Z,RX,RY,RZ))),
      space_near(_,Near), StandZ is Z + Near,
      After = parent(Parent,transform(X,Y,StandZ,RX,RY,RZ))).
space_travel_context(Agent,Revision,Before) :-
    quod:user::personal_agent(Agent,_),
    Agent = agent_instance_ref(Ns,A,Entity), space_assignment(entity_ref(Ns,A,Entity),Revision,Before).
instance_of(quod:gui:form,space_travel_form(_,_,_,_)).
instance_of(quod:gui:button,space_travel_submit).
attribute(space_travel_form(_,_,_,placed(_,_)),label,<<"Enter space">>).
attribute(space_travel_form(_,_,_,Left),label,<<"Leave space">>) :- space_leaving(Left).
attribute(space_travel_form(_,_,_,placed(_,_)),image,Icon) :- menu_icon(enter,Icon).
attribute(space_travel_form(_,_,_,Left),image,Icon) :- space_leaving(Left), menu_icon(leave,Icon).
attribute(space_travel_form(_,_,_,placed(_,_)),help,
    <<"Move the same personal agent into this space. Navigation follows the committed location.">>).
attribute(space_travel_form(_,_,_,parent(_,_)),help,
    <<"Go back to the space this one stands in, in front of it.">>).
attribute(space_travel_form(_,_,_,unplaced),help,
    <<"This space stands in no other: leaving makes the personal agent unplaced.">>).
space_leaving(unplaced).
space_leaving(parent(_,_)).
attribute(space_travel_submit,label,<<"Move">>).
gui_children(space_travel_form(_,_,_,_),[space_travel_submit]).
gui_form(space_travel_form(Agent,Expected,Before,After),[],
    submit(space_travel_submit,
        (quod:space::space_assignment(entity_ref(Source,Anchor,Entity),Expected,Before),
         Move,
         quod:space::space_assignment(entity_ref(Source,Anchor,Entity),Revision,Destination)),
        operation(space_visit(Agent,Destination),
            [result(agent,Agent),result(location,Location),result(revision,Revision)]))) :-
    Agent = agent_instance_ref(Source,Anchor,Entity),
    (After = unplaced -> Destination = none, Location = unplaced,
        Move = quod:space::goal(unplaced(entity_ref(Source,Anchor,Entity)))
    ; (After = placed(Destination,Pose) ; After = parent(Destination,Pose)), Location = placed(Destination,Pose),
      Move = quod:space::goal(inside(Destination,entity_ref(Source,Anchor,Entity),Pose))).

%% The space's own pie overrides the default. Fixed wedges keep paths
%% learnable: Create here at the top, Show as and Inspect clockwise, Leave on
%% the bottom wedge asking for a second press. "Go to" offers this storage's
%% contained spaces, so a far child stays reachable without pointing at it.
class_eidolon(space,menu,default,recipe(Ns,A,space_menu)) :- current_ontology_identity(Ns,A).
%% The class itself is not a space: it keeps the shared default pie, whose
%% leaves are its creation forms.
eidolon(space_menu,subject(ontology_ref(Ns,A),Class),View) :-
    in_ontology(Ns,A,isa(Class,Class)), !,
    menu_vocabulary(Gui,GuiAnchor),
    in_ontology(Gui,GuiAnchor,eidolon(default_menu,subject(ontology_ref(Ns,A),Class),View)).
eidolon(space_menu,subject(ontology_ref(Ns,A),Space),menu(Tree)) :-
    space_instance(entity_ref(Ns,A,Space),space),
    in_ontology(Ns,A,gui_menu_source(Space,menu_source(Name,Own))),
    in_ontology(Ns,A,gui_menu_source(quod:space:space,menu_source(_,Class))),
    in_ontology(Ns,A,gui_menu_source(ontology_ref(Ns,A),menu_source(_,Storage))),
    findall(Item,(member(Item,Own),space_menu_shows(Item)),Shows),
    findall(Item,(member(Offered,Own),\+ space_menu_shows(Offered),space_menu_action(Offered,Item)),Actions),
    findall(Item,space_menu_destination(Space,Ns,A,Item),Destinations),
    menu_icon(create_here,CreateIcon), menu_icon(show_as,ShowIcon), menu_icon(inspect,InspectIcon), menu_icon(go_to,GoIcon),
    append([group(<<"Create here">>,[slot(1),image(CreateIcon)],[operation(class)],Class),
            group(<<"Show as">>,[slot(2),image(ShowIcon)],[operation(instance)],Shows),
            group(<<"Inspect">>,[slot(3),image(InspectIcon)],[prolog,inspection,workspace],Storage)|Actions],
           [group(<<"Go to">>,[image(GoIcon)],[operation(instance)],Destinations)],Entries),
    (binary(Name), Name \== <<"">> -> Title = Name; Title = <<"Space">>),
    menu_vocabulary(Gui,GuiAnchor),
    in_ontology(Gui,GuiAnchor,menu_tree(menu(Title,<<"">>,[],Entries),Tree)).
space_menu_shows(item(choice(_,eidolon(operation(instance),Name,_)),_,_,_,_)) :- space_show_recipe(Name,_,_).
%% Leave takes the bottom wedge and a second press, keeping its form's icon.
space_menu_action(item(T,L,H,Av,Options),item(T,L,H,Av,[slot(5),confirm(true)|Options])) :-
    T = choice(_,eidolon(operation(instance),leave,_)), !.
space_menu_action(Item,Item) :- Item = item(choice(_,eidolon(operation(_),_,_)),_,_,_,_).
space_menu_destination(Space,Ns,A,item(T,Label,H,Av,Options)) :-
    space_contains(entity_ref(Ns,A,Space),entity_ref(CNs,CA,Child)),
    entity_ref(CNs,CA,Child) \== entity_ref(Ns,A,Space), space_instance(entity_ref(CNs,CA,Child),space),
    in_ontology(CNs,CA,gui_menu_source(Child,menu_source(ChildName,Items))),
    member(item(T,Offered,H,Av,Options),Items), T = choice(_,eidolon(operation(instance),enter,_)),
    (binary(ChildName), ChildName \== <<"">> -> Label = ChildName; Label = Offered).

%% Show as: this space's interior choices as offered actions without input
%% fields, each through the one representation operation.
class_eidolon(space,operation(instance),Name,recipe(Ns,A,Recipe)) :-
    space_show_recipe(Name,Recipe,_), current_ontology_identity(Ns,A).
space_show_recipe(show_none,space_show_none,none).
space_show_recipe(show_wireframe,space_show_wireframe,wireframe).
space_show_recipe(show_matrix,space_show_matrix,matrix).
eidolon(Recipe,subject(ontology_ref(Ns,A),instance(Space)),operation(space_show_form(entity_ref(Ns,A,Space),Style,Pose,Before,Interior))) :-
    space_show_recipe(_,Recipe,Interior), space_instance(entity_ref(Ns,A,Space),space),
    in_ontology(Ns,A,unique_solution((attribute(Space,exterior,Style),attribute(Space,transform,Pose)))),
    space_interior_of(entity_ref(Ns,A,Space),Before), Before \== Interior,
    in_ontology(Ns,A,attribute(Space,dimensions,Dimensions)), space_interior_available(Interior,Dimensions).
instance_of(quod:gui:form,space_show_form(_,_,_,_,_)).
instance_of(quod:gui:button,space_show_submit).
attribute(space_show_form(_,_,_,_,none),label,<<"No walls inside">>).
attribute(space_show_form(_,_,_,_,wireframe),label,<<"Wire box walls">>).
attribute(space_show_form(_,_,_,_,matrix),label,<<"Matrix walls">>).
attribute(space_show_form(_,_,_,_,none),image,Icon) :- menu_icon(show_none,Icon).
attribute(space_show_form(_,_,_,_,wireframe),image,Icon) :- menu_icon(wireframe,Icon).
attribute(space_show_form(_,_,_,_,matrix),image,Icon) :- menu_icon(matrix,Icon).
attribute(space_show_form(_,_,_,_,_),help,<<"Changes how this space looks from inside. Nothing moves.">>).
attribute(space_show_submit,label,<<"Show">>).
gui_children(space_show_form(_,_,_,_,_),[space_show_submit]).
gui_form(space_show_form(Space,Style,Pose,Before,After),[],
    submit(space_show_submit,quod:space::space_represent(Space,Style,Pose,Before,Style,Pose,After),
        operation(space_represent(Style,Pose,Before,Style,Pose,After),[]))).

%% Pure space depiction, composed with the space vocabulary and ordinary
%% entity Eidolons. Membership and physical bindings stay with their owners.
%% Seen from outside, a space is its permitted contents or the shared
%% fixed-size marker; its inner size never changes what stands for it.
class_eidolon(space,Mode,contents,recipe(Ns,A,space_contents)) :-
    member(Mode,[playing,edition]), current_ontology_identity(Ns,A).
class_eidolon(space,playing,solid,recipe(Ns,A,marker)) :- scene_vocabulary(Ns,A).
class_eidolon(space,edition,solid,recipe(Ns,A,space_edition)) :- current_ontology_identity(Ns,A).
space_exterior(solid).
space_exterior(contents).
space_interior(none).
space_interior(Walls) :- space_interior_recipe(Walls,_).
space_interior_recipe(wireframe,space_wireframe).
space_interior_recipe(matrix,space_matrix).
%% Walls stand at the space's real size, so they need a finite one.
space_interior_available(none,_).
space_interior_available(Walls,Dimensions) :-
    space_interior_recipe(Walls,_),
    (Dimensions = box(_,_,_) -> true
    ; fail_with_reason(space_interior_unavailable(Walls,Dimensions))).
eidolon(space_wireframe, Subject, Walls) :-
    space_extent(Subject,W,H,D), unique_solution(scene_vocabulary(Ns,A)),
    in_ontology(Ns,A,eidolon(extent(W,H,D),Subject,Walls)).
%% Matrix walls: the outline in emissive green over translucent near-black
%% faces, drawn from both sides so they read from in and out.
eidolon(space_matrix, Subject,
    [part(<<"walls">>, box(WI,HI,DI), transform(0,0,0,0,0,0),
          surface(<<"#030F08">>,0,900,80,220,[]), unlabelled, depicts_nothing) | Outline]) :-
    space_extent(Subject,W,H,D), unique_solution(scene_vocabulary(Ns,A)),
    in_ontology(Ns,A,eidolon(extent(W,H,D,<<"#3CFF7A">>),Subject,Outline)),
    space_whole_mm(W,WI), space_whole_mm(H,HI), space_whole_mm(D,DI).
%% Editing shows the marker with the real size written beneath it, as authored.
eidolon(space_edition, Subject, Parts) :-
    Subject = subject(ontology_ref(Store,History),Space),
    unique_solution(scene_vocabulary(Ns,A)),
    in_ontology(Ns,A,eidolon(marker,Subject,Marker)), in_ontology(Ns,A,marker_size(Size)),
    in_ontology(Store,History,attribute(Space,dimensions,Dimensions)),
    space_size_text(Dimensions,Text), Beneath is -(Size // 2),
    append(Marker,[part(<<"size">>,group,transform(0,Beneath,0,0,0,0),no_surface,
                        label(Text,<<"below">>),depicts_nothing)],Parts).
space_size_text(infinite,<<"Infinite">>).
space_size_text(box(W,H,D),Text) :-
    space_length_codes(W,WC), space_length_codes(H,HC), space_length_codes(D,DC),
    Times = [32,195,151,32],
    append(HC,Times,H1), append(H1,DC,Tail), append(WC,Times,W1), append(W1,Tail,Codes),
    binary_codes(Text,Codes).
space_length_codes(q(Value,Unit),Codes) :-
    '$quod_program_source'([Value],Source), binary_codes(Source,Written),
    append(Spaced,[46,10],Written), findall(Code,(member(Code,Spaced),Code =\= 32),Digits),
    binary_codes(Unit,UnitCodes), append(Digits,[32|UnitCodes],Codes).
space_extent(subject(ontology_ref(Store,History),Space),W,H,D) :-
    in_ontology(Store,History,attribute(Space,dimensions,box(X,Y,Z))),
    unique_solution(measure_vocabulary(Ns,Anchor)),
    space_millimetres(Ns,Anchor,X,W), space_millimetres(Ns,Anchor,Y,H), space_millimetres(Ns,Anchor,Z,D).
space_whole_mm(N/D,Whole) :- !, Rounded is (N + D // 2) // D, (Rounded < 1 -> Whole = 1; Whole = Rounded).
space_whole_mm(Length,Length).
space_millimetres(Ns,Anchor,q(Value,Unit),Length) :-
    in_ontology(Ns,Anchor,convert(Value,Unit,<<"mm">>,Length)).

space_instance(entity_ref(Ns,A,Space), Class) :-
    %% Keep the selective side of the membership/ancestry join first.
    in_ontology(Ns,A,findall(instance(Space,Class),
        (nonvar(Space) -> instance_of(Direct,Space),isa(Direct,quod:space:Class)
        ; isa(Direct,quod:space:Class),instance_of(Direct,Space)),Raw)),
    sort(Raw,Distinct),member(instance(Space,Class),Distinct).
space_contains(entity_ref(Ns,A,Space), Subject) :-
    in_ontology(Ns,A,(space_member(Space,Subject); space_placement(Space,Subject,_))).
space_simulation_domain(entity_ref(Ns,A,Space),World,Authority,Path) :-
    in_ontology(Ns,A,physics_domain(Space,World,Authority,Path)).

%% Contents is a recipe result, not a substitute mesh. The source owns the
%% complete permitted subject set and physical bindings in its own frame.
eidolon(space_contents, subject(ontology_ref(Ns,A),Space), contents(Exposure)) :-
    space_contents_projection(entity_ref(Ns,A,Space),Exposure).

space_contents_projection(Space,exposure(Frame,Revision,Subjects)) :-
    space_instance(Space,space), Frame = Space,
    findall(Subject,space_contains(Space,Subject),Raw), sort(Raw,Unique),
    space_exposed_subjects(Unique,Space,Subjects),
    variant_digest(contents(Frame,Subjects),Revision).
space_exposed_subjects([],_,[]).
space_exposed_subjects([Subject|Rest],Space,[exposed(Subject,Relation,Binding)|Subjects]) :-
    Subject = entity_ref(_,_,_), term_variables(Subject,[]),
    Space = entity_ref(Ns,A,Id),
    in_ontology(Ns,A,findall(R,space_placement(Id,Subject,R),Assignments)),
    (Assignments = [] -> Relation = display
    ; Assignments = [Assignment], Relation = placement(Assignment)),
    space_subject_binding(Space,Subject,Selected),
    (Selected = body_pose(_,_), space_simulation_domain(Space,World,_,_) ->
        Binding = in_frame(World,Selected)
    ; Binding = Selected),
    space_exposed_subjects(Rest,Space,Subjects).

world_view(Space, Mode, Marks) :-
    space_projection(Space,Mode,Marks,_).

%% The ordinary view and portable exposure receipt use one projection.
%% Exact ancestry detects cycles; the proof owner admits resource use.
space_projection(Space,Mode,scene(Marks,Exposures)) :-
    space_projection(Space,Mode,Marks,Exposures).
space_projection(Space,Mode,Marks,Exposures) :-
    space_instance(Space,space), Space = entity_ref(Ns,A,Id),
    in_ontology(Ns,A,entity_eidolons(Id,Mode,contents,Eidolons)),
    findall(Recipe,member(eidolon(Mode,contents,Recipe),Eidolons),Recipes),
    space_entity_model(Recipes,subject(ontology_ref(Ns,A),Id),contents(Exposure)),
    Exposure = exposure(Space,_,_),
    space_exposure_projection(Exposure,Mode,Marks,Exposures).

%% Selected contents and the ordinary interior share exactly one recursive
%% projection. A selected recipe's permitted subjects are never replaced by
%% a client inventory or by another read of the default exterior.
space_exposure_projection(exposure(Frame,_,Subjects),Mode,Marks,Exposures) :-
    member(Mode,[playing,edition]),
    Frame = entity_ref(_,_,_),
    unique_solution(scene_vocabulary(Ns,A)),
    (space_simulation_domain(Frame,World,_,_) -> true; World = none),
    space_scene_parts(Subjects,Mode,[interior(Frame)],
        [representation(Frame,contents(Mode))],none,role(physical,World),Contents,Exposures),
    space_boundary_parts(Frame,Ns,A,Contents,Parts),
    in_ontology(Ns,A,model(Parts,Marks)).

%% The viewed space's own boundary sits at its interior origin, after its
%% contents, depicting the space itself. It is not a contained subject.
space_boundary_parts(Frame,MNs,MA,Contents,Parts) :-
    Frame = entity_ref(Here,History,Space),
    (space_interior_boundary(Frame,Recipe) ->
        current_ontology_identity(Owner,Anchor),
        space_entity_model([recipe(Owner,Anchor,Recipe)],subject(ontology_ref(Here,History),Space),Model),
        term_hex_digest([interior(Frame),boundary],Occurrence),
        in_ontology(MNs,MA,place_model(Occurrence,transform(0,0,0,0,0,0),depicts(Here,History,Space),Model,Boundary)),
        append(Contents,Boundary,Parts)
    ; Parts = Contents).

space_scene_parts([],_,_,_,_,_,[],[]).
space_scene_parts([exposed(Subject,Relation,Binding)|Rest],Mode,Path,Seen,Parent,Role,
                  Parts,Exposures) :-
    Subject = entity_ref(Ns,A,Entity),
    in_ontology(Ns,A,client_entity_scene(Entity,Mode,Scene)),
    (Scene = hidden -> Placed = [], Current = []
    ; Scene = appearance(Id,Style,Context,Layout,Eidolons),
      append(Path,[edge(Subject,Id)],OccurrencePath),
      term_hex_digest(OccurrencePath,Occurrence),
      findall(Recipe,member(eidolon(Mode,Style,Recipe),Eidolons),Recipes),
      (Style == contents ->
          (Recipes = [Selected],
           space_entity_model([Selected],Context,contents(exposure(Subject,ContentRevision,Subjects))) ->
              Model = contents(exposure(Subject,ContentRevision,Subjects))
          ; fail_with_reason(space_contents_unavailable(Subject)))
      ; space_entity_model(Recipes,Context,Model)),
      variant_digest(selected(Recipes,Context,Model),Revision),
      Role = role(ParentUse,World),
      (ParentUse == physical, Relation = placement(_) -> Use = physical; Use = display),
      space_scene_pose(Use,World,Subject,Binding,Layout,Pose), NextRole = role(Use,World),
      space_parent_pose(Parent,Pose,At),
      space_occurrence_model(Model,Mode,OccurrencePath,Seen,Occurrence,NextRole,
                             Local,Children,Descendants,Frame,Allowed,Status),
      scene_vocabulary(MNs,MA),
      in_ontology(MNs,MA,
            place_model(Occurrence,At,depicts(Ns,A,Entity),Local,Here)),
      append(Here,Children,Placed),
      Current = [exposure(Occurrence,OccurrencePath,Subject,selected(Recipes,Revision,Use),
                          Frame,Allowed,Pose,Status)|Descendants]),
    space_scene_parts(Rest,Mode,Path,Seen,Parent,Role,Tail,Others),
    append(Placed,Tail,Parts), append(Current,Others,Exposures).

space_scene_pose(Use,World,_,in_frame(Selected,body_pose(B,R)),_,Pose) :-
    (Selected == World -> true; fail_with_reason(incompatible_physics_view(Selected,World))),
    (Use == physical -> Pose = body_pose(B,R)
    ; Use == display, Pose = body_frame_pose(B,R)).
space_scene_pose(physical,_,_,body_pose(B,R),_,body_pose(B,R)).
space_scene_pose(physical,_,_,source_layout,Layout,Layout).
space_scene_pose(display,World,Subject,source_layout,Layout,Pose) :-
    (World = world_ref(Ns,A,W) ->
        in_ontology(Ns,A,physics_appearance_binding(W,Subject,Binding)),
        (Binding = none -> Pose = Layout; Binding = body_pose(B,R),Pose = body_frame_pose(B,R))
    ; Pose = Layout).

space_occurrence_model(contents(exposure(Frame,_,Subjects)),Mode,Path,Seen,Occurrence,Role,
                       Local,Children,Exposures,Frame,Subjects,Status) :-
    Key = representation(Frame,contents(Mode)),
    (member_eq(Key,Seen) ->
        Status = cycle, Children = [], Exposures = [],
        space_eidolon_status(<<"Contents cycle">>,Local)
    ; Status = contents, Local = [],
      space_scene_parts(Subjects,Mode,Path,[Key|Seen],Occurrence,Role,Children,Exposures)).
space_occurrence_model(Model,_,_,_,_,_,Model,[],[],none,[],model) :-
    Model \= contents(_).

space_parent_pose(none,Pose,Pose).
space_parent_pose(Parent,Pose,relative(Parent,Pose)) :- Parent \== none.

space_subject_binding(Space,Subject,Binding) :-
    Space = entity_ref(Store,Anchor,Id),
    (in_ontology(Store,Anchor,space_placement(Id,Subject,Assignment)),
     space_simulation_domain(Space,World,_,Path) ->
        World = world_ref(Ns,A,W),
        in_ontology(Ns,A,physics_scene_binding(W,Path,Subject,Assignment,Binding))
    ; in_ontology(Store,Anchor,space_placement(Id,Subject,Assignment)),
      space_instance(Space,physical_space) ->
        in_ontology(Store,Anchor,
            findall(binding(B,R),physics_body_definition(Id,B,R,_,_,live(Subject,Assignment,_,_)),
                    [binding(Body,Revision)])), Binding = body_pose(Body,Revision)
    ; Binding = source_layout).

space_entity_model([recipe(Ns,A,Recipe)],Context,Model) :-
    in_ontology(Ns,A,eidolon(Recipe,Context,Model)).
space_entity_model([],_,Parts) :- space_eidolon_status(<<"No matching eidolon">>,Parts).
space_entity_model([_,_|_],_,Parts) :- space_eidolon_status(<<"Choose an eidolon">>,Parts).
space_eidolon_status(Text,
    [part(<<"eidolon-status">>,group,transform(0,0,0,0,0,0),
          no_surface,label(Text,<<"above">>),depicts_nothing)]).

entity_scene(subject(ontology_ref(Ns,A),Space), Mode,
        appearance(Space, Style, subject(ontology_ref(Ns,A),Space), Transform, Eidolons)) :-
    space_instance(entity_ref(Ns,A,Space), space), member(Mode, [playing, edition]),
    in_ontology(Ns,A,(attribute(Space,transform,Transform),attribute(Space,exterior,Stored),
                     (Stored == contents -> Style = contents; Style = solid),
                     entity_eidolons(Space,Mode,Style,Eidolons))).
