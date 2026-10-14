%% Reusable close/cancel capability for objects with one revolute moving part.
%% Compose these rules with quod_physics in the same ontology. Recipes are
%% explicitly pinned; supported mechanics and observation custody stay shared.
physics_hinged_definition(local(Name,Version),Definition) :-
    physics_hinged_class(Name,Version,Definition).
physics_hinged_definition(class_ref(Ns,Anchor,Name,Version),Definition) :-
    Ns::(current_ontology_identity(Ns,Anchor),physics_hinged_class(Name,Version,Definition)).

can_close_physics_hinged(_,_,_) :- fail.
can_cancel_physics_hinged(_,_,_) :- fail.

physics_add_hinged(W,D,F,Source,Pose,Structure) :-
    term_variables([W,D,F,Source,Pose,Structure], []),
    transaction((current_principal(P), can_edit_physics(W,P),
        physics_structure(W,Structure), D \= F,
        physics_reserve_body_ids(W,[D,F]),
        \+ physics_body_definition(W,D,_,_,_,_),
        \+ physics_body_definition(W,F,_,_,_,_),
        physics_hinged_definition(Source,hinged(FixedShape,MovingShape,Density,Axis,Anchors,Limits,Baseline,Command)),
        physics_required_allowances(W,limits(_,_,_,Coordinate,_),_,_,_),
        physics_checked_body(D,dynamic,Pose,MovingShape,Density,Coordinate),
        physics_checked_body(F,fixed,Pose,FixedShape,Density,Coordinate),
        (physics_valid_hinge(Axis,Anchors,Limits,Baseline,Coordinate) -> true
        ; fail_with_reason(invalid_hinge_definition)),
        (Command = position(_,_,_), physics_valid_joint_command(Command,Limits) -> true
        ; fail_with_reason(invalid_hinge_command)),
        physics_body_capacity(W,2), physics_advance_structure(W,Next),
        assertz(physics_body_definition(W,F,Next,fixed,Pose,owned(FixedShape,Density))),
        assertz(physics_body_definition(W,D,Next,dynamic,Pose,owned(MovingShape,Density))),
        assertz(physics_joint(W,hinge(body(D,Next),Next,body(F,Next),Axis,Anchors,Limits,Baseline))),
        assertz(physics_hinged_source(W,D,Source)),
        assertz(physics_hinged_control(W,D,Command)),
        assertz(physics_hinged(W,D,0,idle)))).

physics_hinged_references(W,D,hinge(D,J),[joint(D,J),body(D,DR),body(F,FR)]) :-
    physics_joint(W,hinge(body(D,DR),J,body(F,FR),_,_,_,_)),
    physics_body_definition(W,D,DR,dynamic,_,_), physics_body_definition(W,F,FR,fixed,_,_).

physics_activity(W,Key,Request,Command,Custody) :-
    physics_hinged(W,D,_,State), physics_hinged_references(W,D,Key,_),
    (State = closing(R) -> Request = R, physics_hinged_control(W,D,Command)
    ; Request = none, Command = hold),
    physics_hinged_custody(W,D,Custody).

physics_hinged_custody(W,D,Custody) :-
    findall(R,physics_hinged_request(W,D,R),Rows),
    (Rows = [] -> Custody = none ; Rows = [Custody]).

physics_close_hinged(W,D,Sequence,Id) :-
    term_variables([W,D,Sequence,Id], []), agent_identifier(Id),
    transaction((current_principal(P), can_close_physics_hinged(W,D,P),
        physics_hinged(W,D,Sequence,Before), Before \= closing(_), physics_enabled(W,_),
        physics_hinged_references(W,D,_,References), physics_hinged_custody(W,D,Prior),
        (Before = finished(R,_) -> Lifecycle = finished(R) ; Lifecycle = Before),
        (physics_observation_replaceable(Prior,Lifecycle,References) -> true
        ; fail_with_reason(hinged_custody_held(D))),
        physics_joint(W,hinge(body(D,_),_,_,_,_,Limits,_)),
        physics_hinged_control(W,D,Command), Command = position(_,_,_),
        physics_valid_joint_command(Command,Limits),
        retract(physics_hinged(W,D,Sequence,Before)), Next is Sequence+1,
        assertz(physics_hinged(W,D,Next,closing(close(Next,Id)))),
        physics_remove_hinged_request(W,D))).

physics_cancel_hinged(W,D,Request) :-
    term_variables([W,D,Request], []),
    transaction((current_principal(P), can_cancel_physics_hinged(W,D,P),
        retract(physics_hinged(W,D,Sequence,closing(Request))),
        assertz(physics_hinged(W,D,Sequence,cancelled(Request))))).

%% The complete envelope, including selected command, is bound to both the
%% authenticated event and the eventual signed request. Public events confer
%% no measurement authority.
react_on(observed(Sample),physics_finish_hinged(Sample,Result)) :-
    physics_observation(Sample), physics_hinged_measurement(Sample,Result),
    prepare_signed_request(Bytes,Signature,
        physics_store_hinged_request(Sample,Result,Bytes,Signature)).

physics_store_hinged_request(Sample,Result,Bytes,Signature) :-
    term_variables([Sample,Result,Bytes,Signature], []),
    transaction((physics_hinged_measurement(Sample,Result),
        Sample = physics_sample(physics_frame(world_ref(_,_,W),_,_,_,_,_),
            activity(hinge(D,_),R,_),revisions(References),_,_,_), physics_actor(W),
        physics_hinged_custody(W,D,Prior),
        physics_observation_replaceable(Prior,closing(R),References), physics_newer_sample(Prior,Sample),
        signed_physics_request(physics_finish_hinged(Sample,Result),Bytes,Signature),
        physics_remove_hinged_request(W,D),
        assertz(physics_hinged_request(W,D,request(Sample,Result,Bytes,Signature))))).

physics_finish_hinged(Sample,Result) :-
    term_variables([Sample,Result], []),
    transaction((physics_hinged_measurement(Sample,Result),
        Sample = physics_sample(physics_frame(world_ref(_,_,W),_,_,G,_,_),
            activity(hinge(D,J),R,_),revisions([joint(D,J),Moving,Fixed]),Tick,_,joint_position_mrad(Angle,_)),
        physics_actor(W), physics_hinged_request(W,D,request(Sample,Result,Bytes,Signature)),
        current_signed_request(Bytes,Signature),
        retract(physics_hinged(W,D,Sequence,closing(R))),
        assertz(physics_hinged(W,D,Sequence,finished(R,Result))),
        physics_remove_hinge_checkpoint(W,D),
        assertz(physics_checkpoint(W,hinge(D,J,Moving,Fixed,G,Tick,Angle))),
        findall(Goal,physics_hinged_consequence(W,D,R,Result,Goal),Consequences),
        physics_hinged_consequences(Consequences),
        trigger_event(physics_hinged_finished(W,D,R,Result)))).

%% Application rules may compose receiver writes into this SAME transaction.
%% This is ordinary Prolog goal composition, with the usual ACLs and rollback.
physics_hinged_consequence(_,_,_,_,_) :- fail.
physics_hinged_consequences([]).
physics_hinged_consequences([Goal|Rest]) :- call(Goal), physics_hinged_consequences(Rest).

physics_hinged_measurement(Sample,Result) :-
    Sample = physics_sample(_,activity(Key,R,Command),revisions(References),_,_,joint_position_mrad(Angle,Contact)),
    physics_valid_sample(Sample,W), Key = hinge(D,_),
    physics_hinged_references(W,D,Key,References), physics_hinged(W,D,_,closing(R)),
    physics_hinged_control(W,D,Command),
    physics_joint(W,hinge(body(D,_),_,body(F,_),_,_,Limits,_)),
    Limits = limits(Lower,Upper), integer(Angle), Angle >= Lower, Angle =< Upper,
    physics_valid_joint_command(Command,Limits),
    Command = position(Target,_,stop(Tolerance,target_or_contact)),
    physics_hinged_result(W,D,F,Angle,Target,Tolerance,Contact,Result).
physics_hinged_result(W,D,F,_,_,_,contact(Other,Revision),blocked(Other)) :-
    Other \= D, Other \= F, physics_body_definition(W,Other,Revision,_,_,_).
physics_hinged_result(_,_,_,Angle,Target,Tolerance,clear,closed) :-
    Angle >= Target-Tolerance, Angle =< Target+Tolerance.

physics_remove_hinged_request(W,D) :-
    physics_hinged_custody(W,D,C), (C = none -> true ; retract(physics_hinged_request(W,D,C))).

%% A support and all its attached hinged members move as one authored group.
%% Every member is checked before commit; an unsupported member rolls it all
%% back. Original custody remains resolvable while the edit fences its finish.
physics_move_hinged(W,D,Sequence,Structure,Pose) :-
    term_variables([W,D,Sequence,Structure,Pose], []),
    transaction((current_principal(P), can_edit_physics(W,P), physics_structure(W,Structure),
        physics_hinged(W,D,Sequence,_),
        physics_joint(W,hinge(body(D,_),_,body(F,FR),_,_,_,_)),
        physics_body_definition(W,F,FR,fixed,Before,Definition),
        physics_resolve_definition(W,Definition,Shape,Density),
        physics_required_allowances(W,limits(_,_,_,Coordinate,_),_,_,_),
        physics_checked_body(F,fixed,Pose,Shape,Density,Coordinate),
        findall(J,(physics_joint(W,J),J = hinge(_,_,body(F,_),_,_,_,_)),Joints),
        physics_advance_structure(W,Next),
        retract(physics_body_definition(W,F,FR,fixed,Before,Definition)),
        assertz(physics_body_definition(W,F,Next,fixed,Pose,Definition)),
        physics_move_hinged_members(Joints,W,FR,Next,Pose,Coordinate))).

physics_move_hinged_members([],_,_,_,_,_).
physics_move_hinged_members([Joint|Rest],W,FR,Next,Pose,Coordinate) :-
    Joint = hinge(body(D,DR),_,body(F,FR),Axis,Anchors,Limits,Baseline),
    findall(state(S,T),physics_hinged(W,D,S,T),[state(Sequence,State)]),
    physics_body_definition(W,D,DR,dynamic,Before,Definition),
    physics_resolve_definition(W,Definition,Shape,Density),
    physics_checked_body(D,dynamic,Pose,Shape,Density,Coordinate),
    retract(physics_body_definition(W,D,DR,dynamic,Before,Definition)),
    assertz(physics_body_definition(W,D,Next,dynamic,Pose,Definition)),
    retract(physics_joint(W,Joint)),
    assertz(physics_joint(W,hinge(body(D,Next),Next,body(F,Next),Axis,Anchors,Limits,Baseline))),
    physics_remove_hinge_checkpoint(W,D),
    retract(physics_hinged(W,D,Sequence,State)),
    (State = closing(R) -> After = cancelled(R) ; After = State),
    assertz(physics_hinged(W,D,Sequence,After)),
    physics_move_hinged_members(Rest,W,FR,Next,Pose,Coordinate).
