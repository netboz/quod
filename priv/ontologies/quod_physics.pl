%% First mechanical profile: one optional world per containing ontology.
%% Space policy supplies every allowance and hosting/signing grant.
%% Distances are millimetres, time microseconds, density kg/m3.

agent_hosting_suspended(I) :- physics_space(_, disabled, I).

%% A domain supplies one local view and its ordinary principal policy. Marks
%% name occurrences; only body_pose/2 names their physical source. Live samples
%% never validate a durable transaction.
can_view_physics(_, _) :- fail.
physics_view(_, _) :- fail.
can_read_physics_body(_, _, _) :- fail.
can_query_physics_motion(_, _, _, _) :- fail.
physics_query_allowances(_, _, _) :- fail.

%% A signer's ontology may instead author an exact foreign reference here.
%% This is view selection, not permission to control anything in that world.
physics_client_world(ontology_ref(Ns, Anchor)) :-
    current_principal(P), physics_space(W, enabled, _), can_view_physics(W, P),
    current_ontology_identity(Ns, Anchor).

%% The live bridge enters this policy in an immutable read-only proof. The
%% returned frame names committed authority; only its installed owner can
%% supply the corresponding current pose.
physics_body_read_projection(W, Body, Frame, Revision) :-
    current_principal(Principal), can_read_physics_body(W, Principal, Body),
    physics_body_projection(W, Body, Frame, Revision).

physics_motion_read_projection(W, Body, Query, Frame, Revision,
        query_limits(Skin, Tolerance, Slides, Checks)) :-
    current_principal(Principal), can_query_physics_motion(W, Principal, Body, Query),
    physics_required_configuration(Q, physics_query_allowances(W, Principal, Q),
        query_allowances(Skin, Tolerance, Slides, Checks, Travel, Turn),
        query_allowances_missing(W)),
    integer(Skin), Skin > 0, integer(Tolerance), Tolerance >= 0, Tolerance < Skin,
    integer(Slides), Slides > 0, integer(Checks), Checks > 0,
    integer(Travel), Travel > 0, integer(Turn), Turn > 0,
    physics_required_allowances(W, limits(_, _, _, Coordinate, _), _, _, _),
    physics_query_input(Query, Coordinate, Travel, Turn),
    physics_body_projection(W, Body, Frame, Revision).

physics_required_allowances(W, Limits, Step, Gravity, Budget) :-
    physics_required_configuration(allowances(L,S,G,B), physics_allowances(W,L,S,G,B),
        allowances(Limits,Step,Gravity,Budget), allowances_missing(W)).

physics_required_configuration(Template, Goal, Requested, Missing) :-
    findall(Template, Goal, Rows),
    (Rows = [] -> fail_with_reason(Missing) ; member(Requested, Rows)).

physics_query_input(place(pose(Position, rotation(X,Y,Z))), Coordinate, _, Turn) :-
    physics_query_vector(Position, Coordinate), physics_query_vector(vector(X,Y,Z), Turn).
physics_query_input(travel(Translation, angular(X,Y,Z)), _, Travel, Turn) :-
    physics_query_vector(Translation, Travel), physics_query_vector(vector(X,Y,Z), Turn).
physics_query_input(landing(Position, Reach, Drop, Up), Coordinate, Travel, _) :-
    physics_query_vector(Position, Coordinate),
    physics_landing_parameters(Reach, Drop, Up), Reach =< Travel, Drop =< Travel.
physics_landing_parameters(Reach, Drop, Up) :-
    integer(Reach), Reach > 0, integer(Drop), Drop > 0,
    integer(Up), Up > 0, Up =< 1000.
physics_query_vector(vector(X,Y,Z), Limit) :-
    physics_coordinate(X, Limit), physics_coordinate(Y, Limit), physics_coordinate(Z, Limit).

physics_body_projection(W, Body,
        physics_frame(world_ref(Ns, Anchor, W), agent_instance_ref(Ns, Anchor, I),
                      Epoch, Generation, Token, Structure), Revision) :-
    current_ontology_identity(Ns, Anchor), physics_space(W, enabled, I),
    agent_hosted(I, _, Epoch, _), physics_run(W, Generation, Token), Generation > 0,
    physics_structure(W, Structure), physics_body(W, Body, Revision, _, _, _, _).

%% Physical agents and viewpoints are domain definitions. Binding a principal
%% selects an existing agent; it never creates a body or changes the signer.
physics_agent(_, _, _, _, _) :- fail.
physics_viewpoint(_, _, _, _, _, _) :- fail.
physics_control(_, _, _, _) :- fail.
can_control_physics_agent(_, _, _) :- fail.

physics_control_state(W, Principal, Epoch, Selection) :-
    findall(control(E, S), physics_control(W, Principal, E, S), Rows),
    (Rows = [] -> Epoch = 0, Selection = none
    ; Rows = [control(E, S)] -> Epoch = E, Selection = S
    ; fail_with_reason(ambiguous_control(W))).

physics_control_agent(W, ExpectedEpoch, ExpectedSelection, Selection) :-
    term_variables([W, ExpectedEpoch, ExpectedSelection, Selection], []),
    integer(ExpectedEpoch), ExpectedEpoch >= 0,
    transaction((current_principal(Principal), physics_space(W, _, _),
        physics_control_state(W, Principal, Epoch, Current),
        (Epoch = ExpectedEpoch, Current = ExpectedSelection -> true
        ; fail_with_reason(control_conflict(Epoch))),
        physics_control_choice(W, Principal, Selection),
        (ExpectedEpoch = 0, ExpectedSelection = none,
         \+ physics_control(W, Principal, _, _) -> true
        ; retract(physics_control(W, Principal, ExpectedEpoch, ExpectedSelection))),
        Next is ExpectedEpoch + 1,
        assertz(physics_control(W, Principal, Next, Selection)))).

physics_control_choice(_, _, none).
physics_control_choice(W, Principal, controlled(Agent, Viewpoint)) :-
    physics_agent_configuration(W, Principal, Agent, Viewpoint, _),
    (\+ (physics_control(W, Other, _, controlled(Agent, _)),
        Other \== Principal) -> true ; fail_with_reason(agent_controlled(Agent))).

%% Exact singleton definitions fail closed on ambiguous authored configuration.
%% Pose/motion schema and supported mechanics are checked by the installing
%% adapter, never inferred from an Eidolon or the human's device dimensions.
physics_agent_configuration(W, Principal, Agent, Viewpoint, Configuration) :-
    Configuration = controlled_agent(Agent, _, _, _, _, viewpoint(Viewpoint, _, _)),
    can_control_physics_agent(W, Principal, Agent),
    once((instance_of(Class, Agent), (Class = agent ; isa(Class, agent)))),
    (findall(definition(R, B, M), physics_agent(W, Agent, R, B, M),
            [definition(Revision, Body, Motion)]),
     findall(A, physics_agent(W, A, _, Body, _), [Agent]),
     findall(R, physics_body(W, Body, R, _, _, _, _), [BodyRevision]),
     findall(mount(B, Pose, Track), physics_viewpoint(W, Agent, Viewpoint, B, Pose, Track),
            [mount(Body, LocalPose, Tracking)]) -> true
    ; fail_with_reason(ambiguous_agent(Agent))),
    integer(Revision), Revision > 0,
    term_variables([Agent, Viewpoint, Body, Motion, LocalPose, Tracking], []),
    Configuration = controlled_agent(Agent, Revision, Body, BodyRevision, Motion,
                                    viewpoint(Viewpoint, LocalPose, Tracking)).

physics_control_configuration(W, Principal, Epoch, Configuration) :-
    physics_control_state(W, Principal, Epoch, controlled(Agent, Viewpoint)),
    integer(Epoch), Epoch > 0,
    physics_agent_configuration(W, Principal, Agent, Viewpoint, Configuration).

%% This signed read describes domain selection, not native readiness. The
%% simulation endpoint still has to bind the installed run and owner.
physics_client_control(W, control(Epoch,
        controlled_agent(agent_instance_ref(Ns, Anchor, Agent), R, B, BR, Motion, View))) :-
    current_principal(Principal), can_view_physics(W, Principal),
    current_ontology_identity(Ns, Anchor),
    physics_control_configuration(W, Principal, Epoch, controlled_agent(Agent, R, B, BR, Motion, View)).

%% A signed control proof reads committed policy and stages one live input.
%% Camera/tracking offsets never enter this motion descriptor.
physics_input_projection(W, control_frame(Frame, Registration), Epoch, Sequence, Input, Control, Lease, Limits) :-
    agent_identifier(Registration), integer(Sequence), Sequence >= 0, current_principal(Principal),
    physics_input_control(W, Principal, Epoch, Configuration),
    physics_input_limits(W, Principal, Configuration, Frame, Input, Lease, Limits),
    Control = control(Principal, Epoch, Configuration).

physics_input_limits(W, _, Configuration, Frame, Input, Lease, Limits) :-
    Configuration = controlled_agent(_, _, Body, Revision, Motion, _),
    Motion = motion(Mode, Speed, Turn, Lease, Limits, Capabilities),
    physics_motion_mode(Mode), physics_motion_capabilities(Capabilities, []),
    integer(Speed), Speed > 0, integer(Turn), Turn > 0,
    integer(Lease), Lease > 0,
    Limits = query_limits(Skin, Tolerance, Slides, Checks),
    integer(Skin), Skin > 0, integer(Tolerance), Tolerance >= 0, Tolerance < Skin,
    integer(Slides), Slides > 0, integer(Checks), Checks > 0,
    physics_allowed_input(Input, Mode, Speed, Turn, Capabilities),
    physics_required_allowances(W, limits(_, _, _, Coordinate, _), _, _, _),
    physics_absolute_input(Input, Coordinate),
    physics_body_projection(W, Body, Frame, Revision),
    physics_body(W, Body, Revision, controlled, _, _, _).

physics_input_control(W, Principal, Epoch, Configuration) :-
    physics_control_state(W, Principal, Current, Selection),
    (Selection = controlled(Agent, Viewpoint) -> true ; fail_with_reason(no_control(W))),
    (Epoch = Current -> true ; fail_with_reason(control_conflict(Current))),
    physics_agent_configuration(W, Principal, Agent, Viewpoint, Configuration).

can_push_physics_body(_, _, _) :- fail.
physics_push_allowances(_, _, _, _) :- fail.

physics_push_configuration(W, Principal, Body, Revision, MaxImpulse, MaxSpeed) :-
    can_push_physics_body(W, Principal, Body),
    physics_free_body(W, Body, Revision),
    physics_required_configuration(P, physics_push_allowances(W, Principal, Body, P),
        push_limits(MaxImpulse, MaxSpeed), push_allowances_missing(Body)),
    integer(MaxImpulse), MaxImpulse > 0, integer(MaxSpeed), MaxSpeed > 0.

physics_free_body(W, Body, Revision) :-
    physics_body(W, Body, Revision, dynamic, _, _, _),
    \+ physics_joint(W, hinge(Body, _, _, _, _, _)),
    \+ physics_joint(W, hinge(_, _, Body, _, _, _)).

physics_input_limits(W, Principal, Configuration, Frame,
        push(body(Body, Revision), vector(X,Y,Z)), Lease,
        push_limits(Body, Revision, MaxImpulse, MaxSpeed)) :-
    Configuration = controlled_agent(_, _, _, _, motion(_, _, _, Lease, _, _), _),
    integer(Lease), Lease > 0,
    physics_push_configuration(W, Principal, Body, Revision, MaxImpulse, MaxSpeed),
    physics_query_vector(vector(X,Y,Z), MaxImpulse),
    X*X+Y*Y+Z*Z > 0, X*X+Y*Y+Z*Z =< MaxImpulse*MaxImpulse,
    physics_body_projection(W, Body, Frame, Revision).

physics_motion_mode(free).
physics_motion_mode(grounded(Up)) :- integer(Up), Up > 0, Up =< 1000.
physics_motion_capabilities([], _).
physics_motion_capabilities([teleport(Reach, Drop, Up) | Rest], Seen) :-
    \+ member(teleport, Seen), physics_landing_parameters(Reach, Drop, Up),
    physics_motion_capabilities(Rest, [teleport | Seen]).
physics_motion_capabilities([snap(Step) | Rest], Seen) :-
    \+ member(snap, Seen), integer(Step), Step > 0, Step =< 3141,
    physics_motion_capabilities(Rest, [snap | Seen]).
physics_motion_capabilities([reposition | Rest], Seen) :-
    \+ member(reposition, Seen), physics_motion_capabilities(Rest, [reposition | Seen]).
physics_absolute_input(reposition(Pose), Coordinate) :-
    physics_query_input(place(Pose), Coordinate, Coordinate, Coordinate).
physics_absolute_input(teleport(Position), Coordinate) :- physics_query_vector(Position, Coordinate).
physics_absolute_input(drive(_, _), _).
physics_absolute_input(snap(_), _).
physics_allowed_input(drive(vector(X,Y,Z), angular(Ax,Ay,Az)), Mode, Speed, Turn, _) :-
    physics_query_vector(vector(X,Y,Z), Speed),
    physics_query_vector(vector(Ax,Ay,Az), Turn),
    X*X+Y*Y+Z*Z =< Speed*Speed, Ax*Ax+Ay*Ay+Az*Az =< Turn*Turn,
    (Mode = grounded(_) -> Y = 0 ; true).
physics_allowed_input(teleport(vector(X,Y,Z)), grounded(_), _, _, Capabilities) :-
    integer(X), integer(Y), integer(Z),
    member(teleport(Reach, Drop, Up), Capabilities), physics_landing_parameters(Reach, Drop, Up).
physics_allowed_input(snap(Angle), _, _, _, Capabilities) :-
    integer(Angle), member(snap(Step), Capabilities),
    integer(Step), Step > 0, Step =< 3141, (Angle = Step ; Angle =:= -Step).
%% Explicit corrective relocation is a separate authored capability. It tests
%% occupancy but may leave an invalid initial placement without a travel path.
%% Like locomotion, it changes live pose; it does not rewrite a durable baseline.
physics_allowed_input(reposition(_), _, _, _, Capabilities) :- member(reposition, Capabilities).

physics_client_view(simulation_view(world_ref(Ns, Anchor, W),
        agent_instance_ref(Ns, Anchor, I), Epoch, Generation, Token, Structure, Marks, Control)) :-
    current_principal(P), physics_space(W, enabled, I), can_view_physics(W, P),
    physics_view(W, Marks), current_ontology_identity(Ns, Anchor),
    agent_hosted(I, _, Epoch, _), physics_run(W, Generation, Token),
    Generation > 0, physics_structure(W, Structure),
    physics_required_allowances(W, limits(_, MaxPoses, _, _, _), _, _, _),
    length(Marks, Count), Count =< MaxPoses,
    physics_view_bodies(Marks, W, Ns, Anchor, []),
    physics_control_state(W, P, Binding, Selection),
    (Selection = none -> Control = none
    ; physics_control_configuration(W, P, Binding, Configuration),
      Control = control(P, Binding, Configuration)).

physics_view_bodies([], _, _, _, _).
physics_view_bodies([mark(Id, _, _, body_pose(B, R), _, _, depicts(Ns, Anchor, Entity)) | Rest],
                    W, Ns, Anchor, Seen) :-
    binary_codes(Id, [_ | _]), term_variables(Entity, []), \+ member(Id, Seen),
    physics_body(W, B, R, _, _, _, _),
    physics_view_bodies(Rest, W, Ns, Anchor, [Id | Seen]).

physics_projection(Node, Rows) :-
    findall(world(W, I, Epoch, Key, Generation, RunToken, Custody, Structure,
                  Limits, StepUs, Gravity, Bodies, Budget,
                  baseline(Checkpoints, Joints, Activities, control_selection(Bindings, Controls))),
      (physics_space(W, enabled, I), agent_hosted(I, Node, Epoch, Key),
       physics_run(W, Generation, RunToken), physics_structure(W, Structure),
       physics_required_allowances(W, Limits, StepUs, Gravity, Budget),
       physics_custody(W, Custody),
       findall(C, physics_recovery_checkpoint(W, C), Checkpoints),
       findall(J, physics_joint(W, J), Joints),
       findall(door(D, Sequence, State, Request),
               (physics_door(W,D,Sequence,State), physics_door_custody(W,D,Request)), Doors),
       findall(rest(D, Sequence, State, Request),
               (physics_rest(W,D,Sequence,State), physics_rest_custody(W,D,Request)), Rests),
       append(Doors, Rests, Activities),
       findall(binding(Principal, BindingEpoch, Selection),
               physics_control(W, Principal, BindingEpoch, Selection), Bindings),
       findall(control(Principal, ControlEpoch, Configuration),
               (physics_control(W, Principal, _, controlled(_, _)),
                physics_control_configuration(W, Principal, ControlEpoch, Configuration)), AgentControls),
       findall(push(Principal, Body, Revision, MaxImpulse, MaxSpeed),
               (physics_control(W, Principal, _, controlled(_, _)),
                physics_push_configuration(W, Principal, Body, Revision, MaxImpulse, MaxSpeed)), Pushes),
       append(AgentControls, Pushes, Controls),
       findall(body(Id, Rev, Kind, Pose, Shape, Density),
               physics_body(W, Id, Rev, Kind, Pose, Shape, Density), Bodies)), Rows).

physics_custody(W, Custody) :-
    findall(R, physics_request(W, R), Requests),
    (Requests = [] -> Custody = none ; Requests = [Custody]).

physics_actor(W) :-
    physics_space(W, enabled, I), current_ontology_identity(Ns, Anchor),
    current_principal(agent_instance_ref(Ns, Anchor, I)),
    agent_hosted(I, _, _, _).

%% The original signed activation is durable before submission. Its exact
%% request remains available after actor, runtime or host loss. This is domain
%% work in the existing ontology transaction lane, not a local outbox.
physics_store_request(W, Generation, Prior, Token, Bytes, Signature) :-
    transaction((physics_actor(W), physics_run(W, Generation, _),
        physics_custody(W, Prior), physics_previous_complete(Prior, Generation), agent_identifier(Token),
        signed_physics_request(physics_activate(W, Generation, Token), Bytes, Signature),
        \+ physics_cancelled_request(W, request(Token, Generation, Bytes, Signature)),
        (Prior = none -> true ; retract(physics_request(W, Prior))),
        assertz(physics_request(W, request(Token, Generation, Bytes, Signature))))).

physics_activate(W, Generation, Token) :-
    transaction((physics_actor(W), physics_run(W, Generation, Previous),
        physics_request(W, request(Token, Generation, Bytes, Signature)),
        current_signed_request(Bytes, Signature),
        retract(physics_run(W, Generation, Previous)), Next is Generation + 1,
        assertz(physics_run(W, Next, Token)))).

%% A pending request cannot be overwritten merely because its result is late.
physics_previous_complete(none, _).
physics_previous_complete(request(_, Previous, _, _), Generation) :- Generation > Previous.

%% An explicit policy action, never inferred from elapsed time. Removing this
%% exact custody invalidates the old activation's ordinary OCC read dependency.
%% The original bytes remain available; cancelled does not assert an operation
%% outcome for a request that may still be in flight.
can_cancel_physics_activation(_, _) :- fail.
physics_cancel_activation(W, Generation, Request) :-
    term_variables([W, Generation, Request], []),
    transaction((current_principal(Principal), can_cancel_physics_activation(W, Principal),
        physics_run(W, Generation, _),
        Request = request(_, Generation, _, _), physics_custody(W, Request),
        retract(physics_request(W, Request)),
        assertz(physics_cancelled_request(W, Request)))).

%% Durable domain status is derived from the same atomic transition, not a
%% separately maintained sent flag. Pending includes never-sent and uncertain.
physics_activation_status(W, Request, pending) :-
    physics_request(W, Request), Request = request(_, Generation, _, _),
    physics_run(W, Generation, _).
physics_activation_status(W, Request, activated) :-
    physics_request(W, Request), Request = request(Token, Previous, _, _),
    Generation is Previous + 1, physics_run(W, Generation, Token).
physics_activation_status(W, Request, cancelled) :- physics_cancelled_request(W, Request).

%% Effective geometry is materialized by an authorized action, never by the
%% runtime's local-only selector. A shared definition binds its exact history.
physics_door_definition(local(Name, Version), Definition) :-
    physics_door_class(Name, Version, Definition).
physics_door_definition(class_ref(Ns, Anchor, Name, Version), Definition) :-
    Ns::(current_ontology_identity(Ns, Anchor), physics_door_class(Name, Version, Definition)).

can_edit_physics(_, _) :- fail.
can_close_physics_door(_, _, _) :- fail.
can_cancel_physics_door(_, _, _) :- fail.

physics_add_door(W, Door, Frame, Source, Position, Structure) :-
    term_variables([W, Door, Frame, Source, Position, Structure], []),
    transaction((current_principal(P), can_edit_physics(W, P),
        physics_structure(W, Structure), Door \= Frame,
        \+ physics_body(W, Door, _, _, _, _, _),
        \+ physics_body(W, Frame, _, _, _, _, _),
        physics_door_definition(Source, door(FrameBox, LeafBox, Density, Angle, Motor)),
        physics_required_allowances(W, limits(MaxBodies, _, _, Coordinate, _), _, _, _),
        physics_valid_body(Door, Position, LeafBox, Density, Coordinate),
        physics_valid_body(Frame, Position, FrameBox, Density, Coordinate),
        physics_valid_motor(Angle, Motor),
        findall(Id, physics_body(W, Id, _, _, _, _, _), Bodies),
        length(Bodies, Count), Count + 2 =< MaxBodies,
        Next is Structure + 1,
        retract(physics_structure(W, Structure)), assertz(physics_structure(W, Next)),
        assertz(physics_body(W, Frame, Next, fixed, Position, FrameBox, Density)),
        assertz(physics_body(W, Door, Next, dynamic, Position, LeafBox, Density)),
        assertz(physics_joint(W, hinge(Door, Next, Frame, vector(0,0,0), Angle, Motor))),
        assertz(physics_door_source(W, Door, Source)),
        assertz(physics_door(W, Door, 0, idle)))).

physics_valid_body(Id, vector(X,Y,Z), box(Hx,Hy,Hz), Density, Coordinate) :-
    integer(Id), Id >= 0, Id < 18446744073709551616,
    integer(Density), Density > 0,
    physics_coordinate(X, Coordinate), physics_coordinate(Y, Coordinate), physics_coordinate(Z, Coordinate),
    physics_coordinate(Hx, Coordinate), Hx > 0,
    physics_coordinate(Hy, Coordinate), Hy > 0,
    physics_coordinate(Hz, Coordinate), Hz > 0.
physics_coordinate(X, Limit) :- integer(X), X >= -Limit, X =< Limit.
physics_valid_motor(Angle, motor(Stiffness, Damping, Torque, Tolerance)) :-
    integer(Angle), Angle > 0, Angle < 3142,
    integer(Stiffness), Stiffness > 0, integer(Damping), Damping > 0,
    integer(Torque), Torque > 0, integer(Tolerance), Tolerance > 0, Tolerance < Angle.

%% The sequence belongs to the activity, not to body or authored revisions.
%% A caller cannot reuse an old request by recycling its human-chosen id.
physics_close_door(W, D, Sequence, Id) :-
    term_variables([W,D,Sequence,Id], []), agent_identifier(Id),
    transaction((current_principal(P), can_close_physics_door(W,D,P),
        physics_door(W,D,Sequence,Before), Before \= closing(_),
        physics_space(W,enabled,_), physics_joint(W,hinge(D,_,_,_,_,_)),
        retract(physics_door(W,D,Sequence,Before)), Next is Sequence + 1,
        assertz(physics_door(W,D,Next,closing(close(Next,Id)))),
        physics_remove_door_request(W,D))).

physics_cancel_door(W,D,Request) :-
    term_variables([W,D,Request], []),
    transaction((current_principal(P), can_cancel_physics_door(W,D,P),
        retract(physics_door(W,D,Sequence,closing(Request))),
        assertz(physics_door(W,D,Sequence,cancelled(Request))))).

physics_door_custody(W,D,Custody) :-
    findall(R, physics_door_request(W,D,R), Rows),
    (Rows = [] -> Custody = none ; Rows = [Custody]).

%% Authenticated owner metadata exists only during read-only reaction matching.
%% The selected signed action contains the entire frozen sample.
react_on(observed(Sample), physics_finish_door(Sample, Result)) :-
    physics_observation(Sample),
    Sample = door_sample(W,D,_,_,_,_,_,_,_,_,_,_,_,_),
    physics_door_measurement(Sample, Result), physics_door_custody(W,D,Prior),
    prepare_signed_request(Bytes, Signature,
        physics_store_door_request(Sample, Result, Prior, Bytes, Signature)).

physics_store_door_request(Sample, Result, Prior, Bytes, Signature) :-
    term_variables([Sample,Result,Prior,Bytes,Signature], []),
    transaction((physics_door_measurement(Sample,Result),
        Sample = door_sample(W,D,_,_,_,_,_,_,_,_,_,_,_,_), physics_actor(W),
        physics_door_custody(W,D,Prior), physics_door_replaceable(Prior,Sample),
        signed_physics_request(physics_finish_door(Sample,Result), Bytes, Signature),
        physics_remove_door_request(W,D),
        assertz(physics_door_request(W,D,request(Sample,Result,Bytes,Signature))))).

physics_door_replaceable(none,_).
physics_door_replaceable(request(Previous,_,Bytes,Signature),Sample) :-
    Previous = door_sample(_,_,_,_,_,OldGeneration,_,_,_,_,OldTick,_,_,_),
    Sample = door_sample(_,_,_,_,_,Generation,_,_,_,_,Tick,_,_,_),
    (Generation > OldGeneration ; Generation = OldGeneration, Tick > OldTick),
    physics_request_rejected(Bytes,Signature).

physics_finish_door(Sample,Result) :-
    term_variables([Sample,Result], []),
    transaction((physics_door_measurement(Sample,Result),
        Sample = door_sample(W,D,R,_,_,Generation,_,_,Revision,_,Tick,Angle,_,_),
        physics_actor(W), physics_door_request(W,D,request(Sample,Result,Bytes,Signature)),
        current_signed_request(Bytes,Signature),
        retract(physics_door(W,D,Sequence,closing(R))),
        assertz(physics_door(W,D,Sequence,finished(R,Result))),
        physics_remove_door_checkpoint(W,D),
        assertz(physics_checkpoint(W,hinge(D,Revision,Generation,Tick,Angle))),
        trigger_event(physics_door_finished(W,D,R,Result)))).

physics_door_measurement(
    door_sample(W,D,R,Authority,Epoch,Generation,Token,Structure,Revision,FrameRevision,
                Tick,Angle,Contact,validity(At,Expiry)), Result) :-
    physics_space(W,enabled,I), current_ontology_identity(Ns,Anchor),
    Authority = agent_instance_ref(Ns,Anchor,I), agent_hosted(I,_,Epoch,_),
    physics_run(W,Generation,Token), physics_structure(W,Structure),
    physics_door(W,D,_,closing(R)), physics_body(W,D,Revision,dynamic,_,_,_),
    physics_joint(W,hinge(D,Revision,Frame,_,Baseline,motor(_,_,_,Tolerance))),
    physics_body(W,Frame,FrameRevision,fixed,_,_,_),
    integer(Tick), Tick > 0, Tick < 18446744073709551616, integer(Angle), Angle >= -Baseline, Angle =< Baseline,
    physics_required_allowances(W,_,_,_,Budget),
    integer(At), integer(Expiry), Expiry > At, Expiry - At =< Budget,
    current_request_expiry(RequestExpiry), RequestExpiry > At, RequestExpiry =< Expiry,
    physics_door_result(W,D,Frame,Angle,Tolerance,Contact,Result).
physics_door_result(W,D,Frame,_,_,contact(Other,Revision),blocked(Other)) :-
    Other \= D, Other \= Frame, physics_body(W,Other,Revision,_,_,_,_).
physics_door_result(_,_,_,Angle,Tolerance,clear,closed) :-
    Angle >= -Tolerance, Angle =< Tolerance.

physics_remove_door_request(W,D) :-
    physics_door_custody(W,D,C), (C = none -> true ; retract(physics_door_request(W,D,C))).
physics_remove_door_checkpoint(W,D) :-
    findall(C, (physics_checkpoint(W,C), C = hinge(D,_,_,_,_)), Rows),
    (Rows = [] -> true ; Rows = [Old], retract(physics_checkpoint(W,Old))).


%% A free obstacle edit advances the conservative whole-world fence. Door
%% activity remains pending; a pre-edit observation cannot finish it.
physics_move_body(W,D,Revision,Structure,Position) :-
    term_variables([W,D,Revision,Structure,Position], []),
    transaction((current_principal(P), can_edit_physics(W,P),
        physics_structure(W,Structure), physics_body(W,D,Revision,Kind,Old,Shape,Density),
        \+ physics_joint(W,hinge(D,_,_,_,_,_)),
        \+ physics_joint(W,hinge(_,_,D,_,_,_)),
        physics_required_allowances(W,limits(_,_,_,Coordinate, _),_,_,_),
        physics_query_vector(Position,Coordinate), physics_relocated_pose(Old,Position,Pose),
        Next is Structure + 1,
        retract(physics_structure(W,Structure)), assertz(physics_structure(W,Next)),
        retract(physics_body(W,D,Revision,Kind,Old,Shape,Density)),
        assertz(physics_body(W,D,Next,Kind,Pose,Shape,Density)),
        physics_remove_rest_checkpoint(W,D),
        physics_cancel_rest_edit(W,D))).

physics_relocated_pose(vector(_,_,_),Position,Position).
physics_relocated_pose(pose(_,Rotation),Position,pose(Position,Rotation)).

%% A structural edit resets the whole supported joint group. It also cancels
%% its active objective; restoration cannot reinstate a pre-edit closed state.
physics_move_door(W,D,Sequence,Structure,Position) :-
    term_variables([W,D,Sequence,Structure,Position], []),
    transaction((current_principal(P), can_edit_physics(W,P), physics_structure(W,Structure),
        physics_door(W,D,Sequence,State),
        physics_joint(W,hinge(D,Revision,F,Pivot,Angle,Motor)),
        physics_body(W,D,Revision,dynamic,LeafPosition,LeafBox,Density),
        physics_body(W,F,Revision,fixed,FramePosition,FrameBox,Density),
        physics_required_allowances(W,limits(_,_,_,Coordinate, _),_,_,_),
        physics_valid_body(D,Position,LeafBox,Density,Coordinate), Next is Structure + 1,
        retract(physics_structure(W,Structure)), assertz(physics_structure(W,Next)),
        retract(physics_body(W,D,Revision,dynamic,LeafPosition,LeafBox,Density)),
        retract(physics_body(W,F,Revision,fixed,FramePosition,FrameBox,Density)),
        assertz(physics_body(W,D,Next,dynamic,Position,LeafBox,Density)),
        assertz(physics_body(W,F,Next,fixed,Position,FrameBox,Density)),
        retract(physics_joint(W,hinge(D,Revision,F,Pivot,Angle,Motor))),
        assertz(physics_joint(W,hinge(D,Next,F,Pivot,Angle,Motor))),
        physics_remove_door_checkpoint(W,D),
        retract(physics_door(W,D,Sequence,State)),
        (State = closing(R) -> After = cancelled(R) ; After = idle),
        assertz(physics_door(W,D,Sequence,After)))).

% Replacement custody requires exact terminal evidence captured in the proof's
% ordinary read set. Unknown or unpublished outcomes cannot prove rejection.
physics_request_rejected(Bytes, Signature) :-
    committed_operation_outcome(Bytes, Signature, Status),
    (Status = rejected ; Status = aborted).


%% Rest checkpoint requests are explicit policy actions, independent of hot
%% impulses. Their fulfilment uses the same owned observation/custody lane as
%% door consequences. The author baseline is never overwritten by a sample.
physics_rest(_, _, _, _) :- fail.
can_checkpoint_physics_body(_, _, _) :- fail.
physics_rest_policy(_, _, _) :- fail.

physics_checkpoint_body(W,D,Revision,Sequence,Id) :-
    term_variables([W,D,Revision,Sequence,Id], []), agent_identifier(Id),
    transaction((current_principal(P), can_checkpoint_physics_body(W,D,P), physics_space(W,enabled,_),
        (physics_free_body(W,D,Revision) -> true ; fail_with_reason(body_not_free(D))),
        (physics_rest_policy(W,D,_) -> true ; fail_with_reason(rest_policy_missing(D))),
        physics_rest_state(W,D,Current,Before),
        (Sequence = Current -> true ; fail_with_reason(checkpoint_conflict(D))),
        (Before \= waiting(_) -> true ; fail_with_reason(checkpoint_pending(D))),
        physics_rest_custody(W,D,Prior),
        (physics_rest_replaceable(Prior,W,D) -> true
        ; fail_with_reason(checkpoint_custody_held(D))),
        physics_remove_rest_state(W,D), Next is Sequence + 1,
        assertz(physics_rest(W,D,Next,waiting(rest(Next,Id)))),
        physics_remove_rest_request(W,D))).

physics_rest_state(W,D,Sequence,State) :-
    findall(rest(S,T), physics_rest(W,D,S,T), Rows),
    (Rows = [] -> Sequence = 0, State = idle
    ; Rows = [rest(S,T)] -> Sequence = S, State = T
    ; fail_with_reason(ambiguous_checkpoint(D))).
physics_rest_custody(W,D,C) :-
    findall(R, physics_rest_request(W,D,R), Rows),
    (Rows = [] -> C = none ; Rows = [R] -> C = R
    ; fail_with_reason(ambiguous_checkpoint_custody(D))).
%% An authored cancellation retires this activity, not its backend operation.
%% The changed revision makes its exact old finish permanently ineligible.
physics_rest_replaceable(none,_,_).
physics_rest_replaceable(request(Sample,_,Bytes,Signature),W,D) :-
    ((physics_rest(W,D,_,finished(Sample)) ;
      Sample = rest_sample(W,D,R,_,_,_,_,_,OldRevision,_,_,_),
      physics_rest(W,D,_,cancelled(R)), physics_free_body(W,D,Revision),
      Revision \= OldRevision) -> true ; physics_request_rejected(Bytes,Signature)).

react_on(observed(Sample), physics_finish_rest(Sample)) :-
    physics_observation(Sample), physics_rest_measurement(Sample),
    Sample = rest_sample(W,D,_,_,_,_,_,_,_,_,_,_), physics_rest_custody(W,D,Prior),
    prepare_signed_request(Bytes,Signature,physics_store_rest_request(Sample,Prior,Bytes,Signature)).

physics_store_rest_request(Sample,Prior,Bytes,Signature) :-
    term_variables([Sample,Prior,Bytes,Signature], []),
    transaction((physics_rest_measurement(Sample),
        Sample = rest_sample(W,D,_,_,_,_,_,_,_,_,_,_), physics_actor(W),
        physics_rest_custody(W,D,Prior),
        (Prior = none -> true ; Prior = request(_,_,B,S), physics_request_rejected(B,S)),
        signed_physics_request(physics_finish_rest(Sample),Bytes,Signature),
        physics_remove_rest_request(W,D),
        assertz(physics_rest_request(W,D,request(Sample,rest,Bytes,Signature))))).

physics_finish_rest(Sample) :-
    term_variables(Sample, []),
    transaction((physics_rest_measurement(Sample),
        Sample = rest_sample(W,D,R,Authority,Epoch,G,Token,Structure,Revision,Tick,Pose,_),
        physics_actor(W), physics_rest_request(W,D,request(Sample,rest,Bytes,Signature)),
        current_signed_request(Bytes,Signature),
        retract(physics_rest(W,D,Sequence,waiting(R))),
        assertz(physics_rest(W,D,Sequence,finished(Sample))),
        physics_remove_rest_checkpoint(W,D),
        assertz(physics_checkpoint(W,rest_v1(D,Revision,
            source(Authority,Epoch,G,Token,Structure,Tick),world_mm_quaternion_million,Pose,zero_velocity))),
        trigger_event(physics_body_checkpointed(W,D,R)))).

physics_rest_measurement(rest_sample(W,D,R,Authority,Epoch,G,Token,Structure,Revision,Tick,Pose,
                                     validity(At,Expiry))) :-
    physics_space(W,enabled,I), current_ontology_identity(Ns,Anchor),
    Authority = agent_instance_ref(Ns,Anchor,I), agent_hosted(I,_,Epoch,_),
    physics_run(W,G,Token), physics_structure(W,Structure),
    physics_free_body(W,D,Revision), physics_rest(W,D,_,waiting(R)),
    physics_rest_policy(W,D,recovery(Tolerance,Checks)),
    integer(Tolerance), Tolerance >= 0, integer(Checks), Checks > 0,
    physics_required_allowances(W,limits(_,_,_,Coordinate,_),_,_,Budget),
    Pose = pose(Position,quaternion(X,Y,Z,Q)), physics_query_vector(Position,Coordinate),
    physics_coordinate(X,1000000), physics_coordinate(Y,1000000),
    physics_coordinate(Z,1000000), physics_coordinate(Q,1000000),
    Norm is X*X+Y*Y+Z*Z+Q*Q, Norm >= 999996000000, Norm =< 1000004000000,
    integer(Tick), Tick > 0, Tick < 18446744073709551616,
    integer(At), integer(Expiry), Expiry > At, Expiry-At =< Budget,
    current_request_expiry(RequestExpiry), RequestExpiry > At, RequestExpiry =< Expiry,
    \+ (physics_checkpoint(W,rest_v1(D,_,source(_,_,OldG,_,_,OldTick),_,_,_)),
        (OldG > G ; OldG = G, OldTick >= Tick)).

physics_remove_rest_state(W,D) :-
    findall(rest(S,T),physics_rest(W,D,S,T),Rows),
    (Rows = [] -> true ; Rows = [rest(S,T)], retract(physics_rest(W,D,S,T))).
physics_cancel_rest_edit(W,D) :-
    physics_rest_state(W,D,Sequence,State),
    (State = waiting(R) -> physics_remove_rest_state(W,D),
        assertz(physics_rest(W,D,Sequence,cancelled(R))) ; true).
physics_remove_rest_request(W,D) :-
    physics_rest_custody(W,D,C), (C = none -> true ; retract(physics_rest_request(W,D,C))).
physics_remove_rest_checkpoint(W,D) :-
    findall(C,(physics_checkpoint(W,C),C = rest_v1(D,_,_,_,_,_)),Rows),
    (Rows = [] -> true ; Rows = [C], retract(physics_checkpoint(W,C))).

physics_recovery_checkpoint(W,C) :- physics_checkpoint(W,C), C \= rest_v1(_,_,_,_,_,_).
physics_recovery_checkpoint(W,rest(C,Policy)) :-
    physics_checkpoint(W,C), C = rest_v1(D,_,_,_,_,_),
    findall(P,physics_rest_policy(W,D,P),Policies),
    (Policies = [Policy] -> true ; Policy = invalid).
