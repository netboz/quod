%% Common Prolog predicates loaded into every Quod ontology.
%%
%% This file contains framework mechanics only. Domain rules belong in the
%% ontology that owns them.

%% One signed selection at the visible space. Navigation dependencies are
%% opened under ordinary scope ACLs; the client endpoint checks their exact
%% heights against the proof's retained dependency envelope before installation.
client_world_view(Space, Mode, Dependencies,
        world_view(entity_ref(Ns, Anchor, Space), Marks, Selection)) :-
    term_variables([Space, Mode, Dependencies], []), atom(Mode),
    client_view_dependencies(Dependencies),
    current_ontology_identity(Ns, Anchor),
    (space_instance(Space, space),
     findall(Scene, world_view(Space, Mode, Scene), [Marks]),
     term_variables(Marks, []),
     findall(ontology_ref(R, A), rendering_vocabulary(R, A),
             [ontology_ref(Rendering, RenderingAnchor)]),
     Rendering::(current_ontology_identity(Rendering, RenderingAnchor),
                 well_formed_scene(Marks)) ->
        client_space_selection(Space, Marks, Selection)
    ; Marks = [], Selection = unavailable).

client_view_dependencies([]).
client_view_dependencies([dependency(Ns, Anchor, _) | Rest]) :-
    Ns::current_ontology_identity(Ns, Anchor),
    client_view_dependencies(Rest).

client_space_selection(Space, Marks, Selection) :-
    (space_instance(Space, physical_space) ->
        (findall(S, physics_client_view(Space, Marks, S), [Selection]) -> true
        ; Selection = unavailable)
    ; current_principal(Principal),
      findall(S, physics_control(Space, Principal, _, S), Bindings),
      (Bindings = [] -> Selection = nonphysical
      ; Bindings = [none] -> Selection = nonphysical
      ; Selection = unavailable)).

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

%% Discovery grants no invocation or mutation authority.
%% Ontologies opting into public source discovery also expose their identity;
%% this permits an anchored dependency read without granting source access.
public_source_query(current_ontology_identity(_, _)).
public_source_query(ontology_eidolons(_)).
public_source_query(entity_eidolons(_, _)).

%% Targets admit only these exact source/read and administrator-edit shapes.
%% The root policy describes whole-ontology read access, never API visibility.
system_source_query(
    (current_ontology_identity(_, _), system_prolog_introspection(_, _))).
system_source_query(
    (current_ontology_identity(_, _), system_prolog_edit, transaction(_))).

system_prolog_introspection(Query, Result) :-
    current_ontology_identity(Namespace, Anchor),
    quod:root::(current_ontology_identity(<<"quod:root">>, _),
                system_source_access(ontology_ref(Namespace, Anchor), _)),
    prolog_introspection(Query, Result).

prolog_introspection(predicates, Indicators) :-
    findall(Indicator, current_predicate(Indicator), Unsorted),
    sort(Unsorted, Indicators).
prolog_introspection(source(Indicator), Source) :-
    '$quod_predicate_source'(Indicator, Source).
prolog_introspection(chunks(Bytes), Chunk) :-
    '$quod_source_chunk'(Bytes, Chunk).

system_prolog_edit :-
    current_ontology_identity(Namespace, Anchor),
    quod:root::(current_ontology_identity(<<"quod:root">>, _),
                system_source_access(ontology_ref(Namespace, Anchor), editable)).

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
'$quod_isa_path'(Reference, Superclass, Seen) :-
    '$quod_owner_name'(Reference, Ns, Class),
    Ns::isa(Class, RemoteSuperclass),
    '$quod_qualified_class'(Ns, RemoteSuperclass, QualifiedSuperclass),
    \+ member_eq(QualifiedSuperclass, Seen),
    '$quod_name_normalize'(Superclass, QualifiedSuperclass).
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
'$quod_isa_semantics'((nonvar(_), (_, (_, '$quod_follow_unique'(_))))).

%% A qualified name's final segment is local to its owner. Parentheses change
%% Prolog's term grouping, not that ownership: a:b:c and (a:b):c both select
%% ontology a:b and local name c. An unbound local name remains enumerable.
%% These manipulate name data locally; following their arguments would recurse
%% into the routing machinery they implement, including on backtracking.
no_follow('$quod_owner_name'/3).
no_follow('$quod_name_tail'/4).
no_follow('$quod_name_normalize'/2).
no_follow('$quod_name_join'/3).
no_follow('$quod_qualified_class'/3).
no_follow('$quod_stricter_class'/2).
no_follow('$quod_known_class'/1).
no_follow('$quod_declared_class'/1).
no_follow('$quod_transitive_isa'/2).
no_follow('$quod_isa_requires_closure'/2).
no_follow('$quod_isa_path'/3).
no_follow('$quod_direct_isa'/2).
no_follow('$quod_isa_semantics'/1).
no_follow(most_specific_classes/3).
no_follow(member_eq/2).

'$quod_owner_name'(Ns:Tail, Owner, Name) :-
    nonvar(Ns),
    '$quod_name_tail'(Tail, Ns, Owner, Name).

'$quod_name_tail'(Tail, Prefix, Owner, Name) :-
    nonvar(Tail), Tail = Segment:Rest, !,
    '$quod_name_tail'(Rest, Prefix:Segment, Owner, Name).
'$quod_name_tail'(Name, Owner, Owner, Name).

'$quod_qualified_class'(Ns, Class, Qualified) :-
    (nonvar(Class), Class = _:_ -> Reference = Class
    ; Reference = Ns:Class),
    '$quod_name_normalize'(Reference, Canonical),
    (var(Qualified) -> Qualified = Canonical
    ; '$quod_name_normalize'(Qualified, Canonical)).

'$quod_name_normalize'(Name, Canonical) :-
    nonvar(Name), Name = Left:Right, !,
    '$quod_name_normalize'(Left, L),
    '$quod_name_normalize'(Right, R),
    '$quod_name_join'(L, R, Canonical).
'$quod_name_normalize'(Name, Name).

'$quod_name_join'(Left, Right, Head:Tail) :-
    nonvar(Left), Left = Head:Rest, !,
    '$quod_name_join'(Rest, Right, Tail).
'$quod_name_join'(Left, Right, Left:Right).

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
