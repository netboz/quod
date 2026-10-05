%% First mechanical profile: one optional world per containing ontology.
%% Space policy supplies every allowance and hosting/signing grant.
%% Distances are millimetres, time microseconds, density kg/m3.

agent_hosting_suspended(I) :- physics_space(_, disabled, I).

physics_projection(Node, Rows) :-
    findall(world(W, I, Epoch, Key, Generation, RunToken, Custody, Structure,
                  Limits, StepUs, Gravity, Bodies, Budget, baseline(Checkpoints, Joints, Doors)),
      (physics_space(W, enabled, I), agent_hosted(I, Node, Epoch, Key),
       physics_run(W, Generation, RunToken), physics_structure(W, Structure),
       physics_allowances(W, Limits, StepUs, Gravity, Budget),
       physics_custody(W, Custody),
       findall(C, physics_checkpoint(W, C), Checkpoints),
       findall(J, physics_joint(W, J), Joints),
       findall(door(D, Sequence, State, Request),
               (physics_door(W,D,Sequence,State), physics_door_custody(W,D,Request)), Doors),
       findall(body(Id, Rev, Kind, Position, HalfExtents, Density),
               physics_body(W, Id, Rev, Kind, Position, HalfExtents, Density), Bodies)), Rows).

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
        physics_allowances(W, limits(MaxBodies, _, _, Coordinate), _, _, _),
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
    physics_allowances(W,_,_,_,Budget),
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
        physics_structure(W,Structure), physics_body(W,D,Revision,Kind,Old,Box,Density),
        \+ physics_joint(W,hinge(D,_,_,_,_,_)),
        \+ physics_joint(W,hinge(_,_,D,_,_,_)),
        physics_allowances(W,limits(_,_,_,Coordinate),_,_,_),
        physics_valid_body(D,Position,Box,Density,Coordinate), Next is Structure + 1,
        retract(physics_structure(W,Structure)), assertz(physics_structure(W,Next)),
        retract(physics_body(W,D,Revision,Kind,Old,Box,Density)),
        assertz(physics_body(W,D,Next,Kind,Position,Box,Density)))).

%% A structural edit resets the whole supported joint group. It also cancels
%% its active objective; restoration cannot reinstate a pre-edit closed state.
physics_move_door(W,D,Sequence,Structure,Position) :-
    term_variables([W,D,Sequence,Structure,Position], []),
    transaction((current_principal(P), can_edit_physics(W,P), physics_structure(W,Structure),
        physics_door(W,D,Sequence,State),
        physics_joint(W,hinge(D,Revision,F,Pivot,Angle,Motor)),
        physics_body(W,D,Revision,dynamic,LeafPosition,LeafBox,Density),
        physics_body(W,F,Revision,fixed,FramePosition,FrameBox,Density),
        physics_allowances(W,limits(_,_,_,Coordinate),_,_,_),
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
