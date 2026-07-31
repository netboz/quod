%% Common Prolog predicates loaded into every Quod ontology.
%%
%% This file contains framework mechanics only. Domain rules belong in the
%% ontology that owns them.

goal(Goal) :- goal(Goal, []).

%% A term already being resolved cannot recursively resolve itself.
goal(Goal, Visited) :- member_eq(Goal, Visited), !, fail.

%% Forward lookup by declared action name.
goal(Goal, Visited) :-
    action(Goal, Prerequisites, Effect),
    satisfy_prereq(Prerequisites, [Goal | Visited]),
    assert_effect(Effect).

%% Reverse lookup by a specific declared effect.
goal(Goal, Visited) :-
    reverse_goal_allowed(Goal),
    action(Action, Prerequisites, Goal),
    Action \= Goal,
    \+ is_catchall_action(Action),
    satisfy_prereq(Prerequisites, [Goal | Visited]),
    assert_effect(Goal).

%% Reverse lookup through the generic fact actions, after specific actions.
goal(Goal, Visited) :-
    reverse_goal_allowed(Goal),
    action(Action, Prerequisites, Goal),
    Action \= Goal,
    is_catchall_action(Action),
    satisfy_prereq(Prerequisites, [Goal | Visited]),
    assert_effect(Goal).

%% A declared action is forward-only. `true` is the no-op action effect and is
%% handled only by the direct fallback, never by reverse action lookup.
reverse_goal_allowed(Goal) :-
    Goal \= true,
    \+ action(Goal, _, _).

%% Bare Prolog goals remain usable through goal/1.
goal(Goal, _Visited) :- call(Goal).

member_eq(X, [Y | _]) :- X == Y, !.
member_eq(X, [_ | Rest]) :- member_eq(X, Rest).

%% Prerequisites are raw checks and effects, evaluated in declaration order.
satisfy_prereq([], _Visited).
satisfy_prereq([Prerequisite | Rest], Visited) :-
    call(Prerequisite),
    satisfy_prereq(Rest, Visited).

assert_effect(true) :- !.
assert_effect(retract(Term)) :- !, retract(Term).
assert_effect(Effect) :- assertz(Effect).

%% Generic fact actions are deliberately last in reverse lookup.
action(assert_fact(Fact), [\+ Fact], Fact).
action(remove_fact(Fact), [Fact], retract(Fact)).

is_catchall_action(assert_fact(_)).
is_catchall_action(remove_fact(_)).
