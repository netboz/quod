%% Common Prolog predicates loaded into every Quod ontology.
%%
%% This file contains framework mechanics only. Domain rules belong in the
%% ontology that owns them.

%% action(Transition, Prerequisites, DesiredState).
%%
%% `goal/1` is target-driven: an already-true state needs no transition. When
%% the state is false, every action that can reach it is tried in declaration
%% order. Each candidate is transactional, so a failed transition or
%% postcondition leaves no staged assertions, retractions, or abolishes behind.
goal(DesiredState) :-
    goal(DesiredState, []).

goal(DesiredState, Visited) :-
    '$quod_callable'(DesiredState),
    resolve_goal(DesiredState, Visited).

%% State checks precede cycle detection: a recursively requested state that has
%% already been reached succeeds without attempting another transition.
resolve_goal(DesiredState, _Visited) :-
    '$quod_state_check'(DesiredState),
    !.
resolve_goal(DesiredState, Visited) :-
    \+ member_eq(DesiredState, Visited),
    action(Transition, Prerequisites, DesiredState),
    %% Validate the complete candidate before invoking even its first
    %% prerequisite. This keeps malformed declarations inert.
    '$quod_action_shape'(Transition, Prerequisites, DesiredState),
    transaction((satisfy_prerequisites(Prerequisites,
                                       [DesiredState | Visited]),
                 run_transition(Transition),
                 '$quod_state_check'(DesiredState))),
    !.

%% Prepare one exact node-local lifecycle declaration. Lifecycle IO remains in
%% the typed Erlang runner: this relation only selects and checks a declaration.
%% Unlike an ordinary action candidate, every prerequisite is checked strictly
%% read-only because speculative lifecycle preparation may not stage D writes.
prepare_lifecycle_action(Action, DesiredState, Mode) :-
    action(Action, Prerequisites, DesiredState),
    '$quod_action_shape'(Action, Prerequisites, DesiredState),
    prepare_lifecycle_candidate(DesiredState, Prerequisites, Mode).

prepare_lifecycle_candidate(DesiredState, _Prerequisites, already) :-
    '$quod_state_check'(DesiredState),
    !.
prepare_lifecycle_candidate(_DesiredState, Prerequisites, execute) :-
    check_prerequisites(Prerequisites).

check_prerequisites([]).
check_prerequisites([Prerequisite | Rest]) :-
    '$quod_state_check'(Prerequisite),
    check_prerequisites(Rest).

%% Explicit goal/1 prerequisites may themselves reach a state. Every other
%% prerequisite is a strict state check over the candidate's current staged
%% view. The selected-ontology form carries the same visited chain.
satisfy_prerequisites([], _Visited).
satisfy_prerequisites([goal(State) | Rest], Visited) :-
    !,
    goal(State, Visited),
    satisfy_prerequisites(Rest, Visited).
satisfy_prerequisites([Ns::goal(State) | Rest], Visited) :-
    !,
    Ns::goal(State, Visited),
    satisfy_prerequisites(Rest, Visited).
satisfy_prerequisites([Prerequisite | Rest], Visited) :-
    '$quod_state_check'(Prerequisite),
    satisfy_prerequisites(Rest, Visited).

run_transition([Transition | Rest]) :-
    !,
    call(Transition),
    run_transitions(Rest).
run_transition(Transition) :-
    call(Transition).

run_transitions([]).
run_transitions([Transition | Rest]) :-
    call(Transition),
    run_transitions(Rest).

%% Membership by term identity, not unification: distinct non-ground targets do
%% not become false cycle matches merely because they could unify.
member_eq(X, [Y | _]) :-
    X == Y,
    !.
member_eq(X, [_ | Rest]) :-
    member_eq(X, Rest).
