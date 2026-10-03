%% Common Prolog predicates loaded into every Quod ontology.
%%
%% This file contains framework mechanics only. Domain rules belong in the
%% ontology that owns them.

%% Code is an eidolon of every class. The root catalogue supplies the exact
%% recipe identity; an absent editing ontology simply offers no such recipe.
%% This is a recipe association, never permission to change the target.
class_eidolon(Class, prolog, source, recipe(Namespace, Anchor, prolog_editor)) :-
    nonvar(Class),
    Namespace = <<"quod:prolog:eidolons">>,
    quod:root::system_ontology(Namespace, Anchor).

entity_eidolons(Entity, Eidolons) :-
    findall(Class, (instance_of(Class, Entity); Class = Entity, isa(Class, Class)), Raw),
    sort(Raw, Classes),
    findall(eidolon(Purpose, Style, Recipe), (member(Class, Classes),
            class_eidolon(Class, Purpose, Style, Recipe)), Choices),
    sort(Choices, Eidolons).

ontology_eidolons(Eidolons) :-
    findall(eidolon(Purpose, Style, Recipe),
            class_eidolon(ontology, Purpose, Style, Recipe), Choices),
    sort(Choices, Eidolons).

%% isa(?Subclass, ?Superclass).
%%
%% `isa/2` is Quod's Web Ontology subclass relation. Ontologies declare its
%% immediate edges as ordinary `isa/2` facts or rules; these shared rules add
%% the reflexive and transitive answers. `clause/2` deliberately selects
%% declarations rather than recursively asking the derived relation. The
%% private semantic rules are filtered out, cycles terminate, and multiple
%% inheritance remains ordinary Prolog backtracking.
isa(Class, Class) :-
    '$quod_known_class'(Class).
isa(Subclass, Superclass) :-
    '$quod_transitive_isa'(Subclass, Superclass).

%% Return every most-specific applicable candidate, not an arbitrary winner.
%% Subjects may have several classes. Equivalent cyclic classes and unrelated
%% parents remain alternatives; sorting removes duplicates, never chooses one.
most_specific_classes(Subjects, Candidates, Selected) :-
    term_variables(Subjects-Candidates, []), sort(Candidates, Classes),
    findall(Class, (member(Class, Classes), member(Subject, Subjects),
                   isa(Subject, Class)), RawApplicable),
    sort(RawApplicable, Applicable),
    findall(Class, (member(Class, Applicable),
                   \+ '$quod_stricter_class'(Class, Applicable)), Selected).

'$quod_stricter_class'(Class, Classes) :-
    member(Other, Classes), isa(Other, Class), \+ isa(Class, Other).

%% Reflexivity applies to declared classes, not to every arbitrary Prolog term.
%% Ground checks avoid enumerating the complete local taxonomy. Open queries
%% enumerate each declared class once even when it occurs in several edges.
'$quod_known_class'(Class) :-
    nonvar(Class),
    !,
    ('$quod_direct_isa'(Class, _); '$quod_direct_isa'(_, Class)),
    !.
'$quod_known_class'(Class) :-
    findall(C, '$quod_declared_class'(C), Raw),
    sort(Raw, Classes),
    member(Class, Classes).

'$quod_declared_class'(Class) :- '$quod_direct_isa'(Class, _).
'$quod_declared_class'(Class) :- '$quod_direct_isa'(_, Class).

'$quod_transitive_isa'(Subclass, Superclass) :-
    '$quod_isa_requires_closure'(Subclass, Superclass),
    '$quod_direct_isa'(Subclass, Parent),
    \+ member_eq(Parent, [Subclass]),
    '$quod_isa_path'(Parent, Superclass, [Parent, Subclass]).

%% A fully-ground direct query should reach its authored clause without first
%% walking the rest of the hierarchy. Open queries still enumerate closure
%% answers, while a ground non-edge takes the transitive path.
'$quod_isa_requires_closure'(Subclass, _) :- var(Subclass).
'$quod_isa_requires_closure'(_, Superclass) :- var(Superclass).
'$quod_isa_requires_closure'(Subclass, Superclass) :-
    \+ '$quod_direct_isa'(Subclass, Superclass).

%% Once a path reaches a foreign class, ask its owning ontology for the rest
%% of the public `isa/2` relation and qualify every answer back into the
%% caller's graph. Generated argument-following clauses are routing machinery,
%% not authored immediate class declarations, so '$quod_direct_isa'/2 excludes
%% them below.
'$quod_isa_path'(Ns:Class, Superclass, Seen) :-
    Ns::isa(Class, RemoteSuperclass),
    '$quod_qualified_class'(Ns, RemoteSuperclass, QualifiedSuperclass),
    \+ member_eq(QualifiedSuperclass, Seen),
    Superclass = QualifiedSuperclass.
'$quod_isa_path'(Class, Superclass, Seen) :-
    '$quod_direct_isa'(Class, Superclass),
    \+ member_eq(Superclass, Seen).
'$quod_isa_path'(Class, Superclass, Seen) :-
    '$quod_direct_isa'(Class, Parent),
    \+ member_eq(Parent, Seen),
    '$quod_isa_path'(Parent, Superclass, [Parent | Seen]).

'$quod_direct_isa'(Subclass, Superclass) :-
    clause(isa(Subclass, Superclass), Body),
    \+ '$quod_isa_semantics'(Body),
    call(Body).

'$quod_isa_semantics'('$quod_transitive_isa'(_, _)).
'$quod_isa_semantics'('$quod_known_class'(_)).
'$quod_isa_semantics'((nonvar(_), (_, '$quod_follow_unique'(_)))).

'$quod_qualified_class'(_, Ns:Class, Ns:Class) :- !.
'$quod_qualified_class'(Ns, Class, Ns:Class).

%% action(Transition, Prerequisites, DesiredState).
%%
%% `goal/1` is target-driven: an already-true state needs no transition. When
%% the state is false, every action that can reach it is tried in declaration
%% order. Each candidate has an internal proof savepoint, so a failed
%% transition or postcondition leaves no staged facts, events or effects behind.
%% Candidate rollback does not choose atomic versus independent commit intent.
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
    '$quod_action_candidate'(Transition, Prerequisites, DesiredState,
                             [DesiredState | Visited]),
    !.

%% A governed public bridge allocates `Handle` and enters this same action
%% relation.  Declarations use the private transition shape below so the
%% public functor never calls itself recursively and an ontology cannot invoke
%% the continuation without the exact proof-local handle.
run_declared_action(Action, Handle) :-
    Transition = '$quod_stage_ontology'(Handle, Action, DesiredState),
    action(Transition, Prerequisites, DesiredState),
    '$quod_action_shape'(Transition, Prerequisites, DesiredState),
    run_declared_candidate(Transition, Prerequisites, DesiredState).

run_declared_candidate(_Transition, _Prerequisites, DesiredState) :-
    '$quod_state_check'(DesiredState),
    !.
run_declared_candidate(Transition, Prerequisites, DesiredState) :-
    '$quod_action_candidate'(Transition, Prerequisites, DesiredState,
                             [DesiredState]).

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

%% proof_draw(+Salt, +N, -I).
%%
%% The proof-bound draw (quod_common_primitives): 0 =< I < N, fixed by the
%% running proof's identity and Salt. Same proof and salt, same I, wherever in
%% the proof it is asked; a retried request is a new proof and draws afresh.
%% Fails plainly outside a proof. Deterministic selection, not randomness.
proof_draw(Salt, N, I) :- '$quod_draw'(Salt, N, I).
