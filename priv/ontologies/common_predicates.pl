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
isa(ontology, thing).
instance_of(ontology, ontology_ref(Namespace, Anchor)) :-
    current_ontology_identity(Namespace, Anchor).

class_eidolon(Class, prolog, source, recipe(Namespace, Anchor, prolog_editor)) :-
    nonvar(Class),
    Namespace = <<"quod:prolog:eidolons">>,
    quod:root::system_ontology(Namespace, Anchor).

class_eidolon(ontology, inspection, Style, recipe(Namespace, Anchor, Style)) :-
    member(Style, [policy, interfaces, routes]),
    Namespace = <<"quod:prolog:eidolons">>,
    quod:root::system_ontology(Namespace, Anchor).

entity_eidolons(Entity,Eidolons) :- entity_eidolons(Entity,_,_,Eidolons).
entity_eidolons(Entity,Purpose,Style,Eidolons) :-
    findall(Direct,(instance_of(Direct,Entity); Direct = Entity, isa(Direct,Direct)),Raw),
    sort(Raw,Classes), class_eidolons(Classes,Purpose,Style,Offered),
    findall(eidolon(Mode,Kind,Recipe),
        (member(eidolon(Mode,Kind,Recipe),Offered), entity_eidolon_mode(Entity,Mode)), Eidolons).

entity_eidolon_mode(Entity,operation(class)) :- !, once(isa(Entity,Entity)).
entity_eidolon_mode(Entity,operation(instance)) :- !, once(instance_of(_,Entity)).
entity_eidolon_mode(_,_).

class_eidolons(Classes,Eidolons) :- class_eidolons(Classes,_,_,Eidolons).
class_eidolons(Classes,Purpose,Style,Eidolons) :-
    findall(candidate(Class,Purpose,Style,Recipe),
        (member(Direct,Classes), (Class = Direct; isa(Direct,Class)),
         class_eidolon(Class,Purpose,Style,Recipe)), Candidates),
    findall(eidolon(Purpose,Style,Recipe),
        (member(candidate(Class,Purpose,Style,Recipe),Candidates),
         \+ (member(candidate(Other,Purpose,Style,_),Candidates),
             isa(Other,Class), \+ isa(Class,Other))), Choices),
    sort(Choices, Eidolons).

entity_classes(Entity, Classes) :-
    findall(Class, ((instance_of(Direct,Entity); Direct = Entity, isa(Direct,Direct)),
                   (Class = Direct; isa(Direct,Class))), Raw),
    sort(Raw,Classes).

%% The same guard belongs at each operation's mutation boundary, including
%% direct calls. Discovery may ask it with complete inputs, but never executes
%% the operation. Identity comes from the proof; all policy comes from its
%% committed base. Creation uses class(Class), create(BuildPlan).
operation_authorized(Requested, Operation) :-
    term_variables(Requested-Operation, []),
    (Requested = class(_); Requested = instance(_)),
    (Requested = instance(Instance), '$quod_construction'(Instance, Class, Inputs) ->
        Subject = construction(Class, Instance, Inputs)
    ; Subject = Requested),
    current_principal(Actor),
    '$quod_committed_check'(operation_policy(Actor, Subject, Operation)).

operation_policy(Actor, Subject, Operation) :-
    term_variables(Actor-Subject-Operation, []),
    functor(Operation, Name, _), atom(Name),
    operation_classes(Subject, Classes), Classes \== [], term_variables(Classes, []),
    findall(Check, (member(Class, Classes),
                   class_requirement(Class, Name, Check)), Checks),
    operation_requirements(Checks, Actor, Subject, Operation),
    operation_grant(Actor, Subject, Operation, Name, Classes).

operation_classes(class(Class), Classes) :-
    findall(C, (C = Class; isa(Class, C)), Raw), sort(Raw, Classes).
operation_classes(construction(Class, Instance, _), Classes) :-
    \+ instance_of(_, Instance), operation_classes(class(Class), Classes).
operation_classes(instance(Instance), Classes) :-
    findall(C, (instance_of(Direct, Instance), (C = Direct; isa(Direct, C))), Raw),
    sort(Raw, Classes).

operation_requirements([], _, _, _).
operation_requirements([Check | Rest], Actor, Subject, Operation) :-
    operation_check(Check, Actor, Subject, Operation),
    operation_requirements(Rest, Actor, Subject, Operation).

%% Checks are named Prolog predicates of arity three, receiving the exact
%% actor, subject and operation (including parameters). Missing checks fail.
operation_check(Check, Actor, Subject, Operation) :-
    atom(Check), Goal =.. [Check, Actor, Subject, Operation], call(Goal).

%% Editing grants is an owner/administrator operation, never a grant that can
%% delegate itself. Requirements for set_permission still apply above.
operation_grant(Actor, Subject, set_permission(Name, Grant),
                set_permission, _) :-
    !, Subject = instance(Instance), atom(Name), Name \== set_permission,
    (Grant == inherit; permission_grant(Grant)),
    (findall(Owner, attribute(Instance, owner, Owner), Owners),
     term_variables(Owners, []), sort(Owners, [Actor]);
     permission_administrator(Instance, Actor)).
operation_grant(Actor, Subject, Operation, Name, Classes) :-
    operation_override(Subject, Name, Overrides),
    (Overrides == [] ->
        findall(candidate(Class, Grant),
                (member(Class, Classes), class_permission(Class, Name, Grant)), Candidates),
        findall(Class, member(candidate(Class, _), Candidates), Declaring),
        findall(Grant, (member(candidate(Class, Grant), Candidates),
                       \+ '$quod_stricter_class'(Class, Declaring)), Grants)
    ; Grants = Overrides),
    term_variables(Grants, []), sort(Grants, [Grant]), permission_grant(Grant),
    permission_allows(Grant, Actor, Subject, Operation).

operation_override(class(_), _, []).
operation_override(construction(_, _, _), _, []).
operation_override(instance(Instance), Name, Grants) :-
    findall(Grant, instance_permission(Instance, Name, Grant), Grants).

permission_grant(allow).
permission_grant(deny).
permission_grant(check(Check)) :- atom(Check).
permission_allows(allow, _, _, _).
permission_allows(check(Check), Actor, Subject, Operation) :-
    operation_check(Check, Actor, Subject, Operation).

set_instance_permission(Instance, Name, Grant) :-
    operation_authorized(instance(Instance), set_permission(Name, Grant)),
    findall(Previous, retract(instance_permission(Instance, Name, Previous)), _),
    (Grant == inherit -> true; assertz(instance_permission(Instance, Name, Grant))).

%% Policy data is local to the target. Argument-following must not turn a
%% denied/missing local grant into a foreign alternative.
no_follow(operation_authorized/2).
no_follow(operation_policy/3).
no_follow(operation_classes/2).
no_follow(operation_requirements/4).
no_follow(operation_check/4).
no_follow(operation_grant/5).
no_follow(operation_override/3).
no_follow(permission_grant/1).
no_follow(permission_allows/4).
no_follow(set_instance_permission/3).
no_follow(class_requirement/3).
no_follow(class_permission/3).
no_follow(instance_permission/3).
no_follow(permission_administrator/2).

%% Discovery grants no invocation or mutation authority.
%% Ontologies opting into public source discovery also expose their identity;
%% this permits an anchored dependency read without granting source access.
public_source_query(current_ontology_identity(_, _)).
public_source_query(instance_of(ontology, ontology_ref(_, _))).
public_source_query(entity_eidolons(_, _)).
public_source_query(class_eidolons(_, _)).
public_source_query(class_eidolons(_, _, _, _)).
public_source_query(entity_eidolons(_, _, _, _)).

%% Targets admit only these exact source/read and administrator-edit shapes.
%% The root policy describes whole-ontology read access, never API visibility.
system_source_query(
    (current_ontology_identity(_, _), system_prolog_introspection(_, _))).
system_source_query(
    (current_ontology_identity(_, _), system_prolog_edit, transaction(_))).

system_prolog_introspection(Query, Result) :-
    current_ontology_identity(Namespace, Anchor),
    quod:root::(current_ontology_identity(<<"quod:root">>, _),
                system_source_access(ontology_ref(Namespace, Anchor), Access)),
    (Query == presentation -> Result = Access ; prolog_introspection(Query, Result)).

prolog_introspection(predicates, Indicators) :-
    findall(Indicator, current_predicate(Indicator), Unsorted),
    sort(Unsorted, Indicators).
prolog_introspection(source(Indicator), Source) :-
    '$quod_predicate_source'(Indicator, Source).
prolog_introspection(chunks(Bytes), Chunk) :-
    '$quod_source_chunk'(all, Bytes, Chunk).
prolog_introspection(identity, ontology_ref(Namespace, Anchor)) :-
    current_ontology_identity(Namespace, Anchor).
prolog_introspection(policy_chunks(Bytes), Chunk) :-
    findall(Indicator, ontology_acl_indicator(Indicator), Indicators),
    '$quod_source_chunk'(predicates(Indicators), Bytes, Chunk).
prolog_introspection(interface_chunks(Bytes), Chunk) :-
    '$quod_source_chunk'(predicates([ontology_interface/2]), Bytes, Chunk).
prolog_introspection(route_chunks(Bytes), Chunk) :-
    '$quod_ontology_routes'(Routes),
    '$quod_source_chunk'(terms(Routes), Bytes, Chunk).
%% Presentation is advisory and shares the target's existing ownership rules.
%% No declaration means a read-only view; ambiguity never selects a grant.
prolog_introspection(presentation, Mode) :-
    findall(M, (current_predicate(ontology_source_mode/1),
                ontology_source_mode(M)), Raw),
    sort(Raw, Modes),
    ontology_presentation_mode(Modes, Mode).

ontology_presentation_mode([], read_only).
ontology_presentation_mode([Mode], Mode) :-
    term_variables(Mode, []), member(Mode, [read_only, editable]).

ontology_acl_indicator(can_invoke/4).
ontology_acl_indicator(can_join/3).
ontology_acl_indicator(acl_sovereign/1).

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
'$quod_isa_path'(Class, Superclass, _) :-
    %% A directly declared qualified parent may use the other parenthesis
    %% grouping. It is already the requested endpoint, not another graph edge.
    nonvar(Class), nonvar(Superclass), Class \== Superclass,
    '$quod_name_normalize'(Class, Canonical),
    '$quod_name_normalize'(Superclass, Canonical).
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

%% A governed bridge supplies its private transition, including its exact
%% proof-local handle. The common action relation owns prerequisites and
%% rollback independently of which native operation is being prepared.
run_declared_action(Transition) :-
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
