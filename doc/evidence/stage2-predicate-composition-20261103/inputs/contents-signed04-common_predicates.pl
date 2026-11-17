%% Common Prolog predicates loaded into every Quod ontology.
%%
%% This file contains framework mechanics only. Domain rules belong in the
%% ontology that owns them.

%% Exact anchored scope entry. Keep the identity check inside the destination
%% and the ordinary invocation policy around the complete selected goal.
no_follow(in_ontology/3).
in_ontology(Namespace,Anchor,Goal) :-
    Namespace::(current_ontology_identity(Namespace,Anchor),Goal).

%% Cardinality over all answers, including duplicates. Callers leave selected
%% outputs fresh until this check finishes, so a bound output cannot hide an
%% alternative. findall retains ordinary proof/dependency and failure rules.
no_follow(unique_solution/1).
unique_solution(Goal) :-
    term_variables(Goal,Variables), findall(Variables,Goal,[Variables]).

%% Portable identifiers use the existing canonical digest and lower-case hex.
%% Both scene occurrences and physical frame receipts share this formatter.
no_follow(term_hex_digest/2).
term_hex_digest(Term,Id) :-
    term_digest(Term,Digest), binary_codes(Digest,Bytes),
    digest_hex_codes(Bytes,Codes), binary_codes(Id,Codes).
digest_hex_codes([],[]).
digest_hex_codes([Byte|Bytes],[High,Low|Codes]) :-
    H is Byte // 16, L is Byte mod 16,
    digest_hex_digit(H,High), digest_hex_digit(L,Low), digest_hex_codes(Bytes,Codes).
digest_hex_digit(N,Code) :- (N < 10 -> Code is N + 48; Code is N + 87).

%% One signed selection at the visible space. Navigation dependencies are
%% opened under ordinary scope ACLs; the client endpoint checks their exact
%% heights against the proof's retained dependency envelope before installation.
client_world_view(Space, Mode, Dependencies,
        world_view(entity_ref(Ns, Anchor, Space), Name, Marks, Selection)) :-
    term_variables([Space, Mode, Dependencies], []), atom(Mode),
    client_view_dependencies(Dependencies),
    current_ontology_identity(Ns, Anchor),
    client_subject_name(Space,Name),
    (space_instance(Space, space),
     findall(Scene, world_view(Space, Mode, Scene), [Marks]),
     term_variables(Marks, []),
     findall(ontology_ref(R, A), rendering_vocabulary(R, A),
             [ontology_ref(Rendering, RenderingAnchor)]),
     Rendering::(current_ontology_identity(Rendering, RenderingAnchor),
                 well_formed_scene(Marks)) ->
        client_space_selection(Space, Marks, Selection)
    ; Marks = [], Selection = unavailable).

%% Display names are ordinary governed source data, not identity or admission.
%% Absence is explicit; conflicting or ill-typed names invalidate presentation.
client_subject_name(Subject,Name) :-
    findall(Value,attribute(Subject,name,Value),Names),
    (Names = [] -> Name = unnamed
    ; Names = [Name], binary(Name) -> true
    ; fail_with_reason(invalid_subject_name(Subject))).
client_subject_label(Subject,Label) :-
    client_subject_name(Subject,Name),
    (Name == unnamed -> Label = unlabelled
    ; Label = label(Name,<<"above">>)).

client_view_dependencies([]).
client_view_dependencies([dependency(Ns, Anchor, _) | Rest]) :-
    Ns::current_ontology_identity(Ns, Anchor),
    client_view_dependencies(Rest).

client_space_selection(Space, Marks, Selection) :-
    (space_simulation_domain(Space,world_ref(Ns,A,W),_,Path) ->
        (Ns::(current_ontology_identity(Ns,A),physics_client_view(W,Marks,Physical),
               physics_view_frames(W,Path,Frames),physics_scene_frames(W,Marks,BodyFrames)),
         client_simulation_frame(Space,Frames,BodyFrames,Physical,Selection) -> true
        ; Selection = unavailable)
    ; space_instance(Space, physical_space) ->
        (findall(S, physics_client_view(Space, Marks, S), [Physical]),
         physics_scene_frames(Space,Marks,BodyFrames),
         client_simulation_frame(Space,[],BodyFrames,Physical,Selection) -> true
        ; Selection = unavailable)
    ; current_principal(Principal),
      findall(S, physics_control(Space, Principal, _, S), Bindings),
      (Bindings = [] -> Selection = nonphysical
      ; Bindings = [none] -> Selection = nonphysical
      ; Selection = unavailable)).

client_simulation_frame(Space,Frames,BodyFrames,
    simulation_view(World,Authority,Epoch,Generation,Token,Structure,Control),
    simulation_view(World,Authority,Epoch,Generation,Token,Structure,Control,
                    view_frame(entity_ref(Ns,A,Space),Frames,BodyFrames))) :-
    current_ontology_identity(Ns,A).
client_simulation_frame(_,_,_,Selection,Selection) :-
    member(Selection,[disabled,denied,recovering,unavailable]).

%% The thing class supplies the inherited source Eidolon. The root catalogue supplies the exact
%% recipe identity; an absent editing ontology simply offers no such recipe.
%% This is a recipe association, never permission to change the target.
isa(space, thing).
isa(ontology, space).
instance_of(ontology, ontology_ref(Namespace, Anchor)) :-
    current_ontology_identity(Namespace, Anchor).

%% Reflected instances are ordinary local terms. Their source catalogue remains
%% authoritative, including interpreted empty definitions; reads create no state.
isa(predicate, thing).
instance_of(predicate, predicate(Indicator)) :-
    ontology_predicates(Indicators), member(Indicator, Indicators).
ontology_predicates(Indicators) :-
    current_ontology_identity(Namespace, Anchor),
    quod:root::system_ontology(<<"quod:gui">>, ToolsAnchor),
    in_ontology(<<"quod:gui">>, ToolsAnchor,
        prolog_predicates(ontology_ref(Namespace, Anchor), Indicators)).

class_eidolon(predicate, prolog, source, recipe(Ns,A,predicate_source)) :-
    current_ontology_identity(Ns,A).
eidolon(predicate_source, subject(Target,predicate(Indicator)), View) :-
    instance_of(predicate,predicate(Indicator)),
    quod:root::system_ontology(<<"quod:gui">>,A),
    in_ontology(<<"quod:gui">>,A,
        eidolon(prolog_editor(Indicator),subject(Target,predicate(Indicator)),View)).
class_eidolon(predicate,Mode,solid,recipe(Ns,A,predicate_model)) :-
    member(Mode,[playing,edition]), current_ontology_identity(Ns,A).
entity_scene(predicate(Indicator),Mode,
        appearance(predicate(Indicator),solid,predicate(Indicator),Pose,Eidolons)) :-
    ontology_predicates(Indicators), predicate_position(Indicators,Indicator,0,Pose),
    entity_eidolons(predicate(Indicator),Mode,solid,Eidolons).
predicate_position([Indicator|_],Indicator,Index,transform(X,Y,0,0,0,0)) :-
    X is (Index mod 16) * 1200, Y is -(Index // 16) * 800.
predicate_position([_|Rest],Indicator,Index,Pose) :-
    Next is Index + 1, predicate_position(Rest,Indicator,Next,Pose).
eidolon(predicate_model,predicate(Indicator),
        [part(<<"predicate">>,box(800,500,200),transform(0,0,0,0,0,0),
              surface(<<"#6A90D9">>,0,700,0,[]),unlabelled,depicts_nothing)]) :-
    instance_of(predicate,predicate(Indicator)).

%% These are display members, never containing-space assignments or grants.
space_member(ontology_ref(Ns,A),entity_ref(Ns,A,predicate(Indicator))) :-
    current_ontology_identity(Ns,A), instance_of(predicate,predicate(Indicator)).
attribute(ontology_ref(Ns,A),transform,transform(0,0,0,0,0,0)) :- current_ontology_identity(Ns,A).
attribute(ontology_ref(Ns,A),exterior,contents) :- current_ontology_identity(Ns,A).
attribute(ontology_ref(Ns,A),dimensions,infinite) :- current_ontology_identity(Ns,A).

class_eidolon(thing, prolog, source, recipe(Namespace, Anchor, prolog_editor)) :-
    Namespace = <<"quod:gui">>,
    quod:root::system_ontology(Namespace, Anchor).

class_eidolon(ontology, inspection, Style, recipe(Namespace, Anchor, Style)) :-
    member(Style, [policy, interfaces, routes]),
    Namespace = <<"quod:gui">>,
    quod:root::system_ontology(Namespace, Anchor).

class_eidolon(ontology, workspace, workbench, recipe(Namespace, Anchor, workbench)) :-
    Namespace = <<"quod:gui">>, quod:root::system_ontology(Namespace, Anchor).

entity_eidolons(Entity,Eidolons) :- entity_eidolons(Entity,_,_,Eidolons).
entity_eidolons(Entity,Purpose,Style,Eidolons) :-
    findall(Direct,(instance_of(Direct,Entity); Direct = Entity, isa(Direct,Direct)),Raw),
    sort(Raw,Classes), class_eidolons(Classes,Purpose,Style,Offered),
    findall(eidolon(Mode,Kind,Recipe),
        (member(eidolon(Mode,Kind,Recipe),Offered), entity_eidolon_mode(Entity,Mode)), Eidolons).

entity_eidolon_mode(Entity,operation(class)) :- !, once(isa(Entity,Entity)).
entity_eidolon_mode(Entity,operation(instance)) :- !, once(instance_of(_,Entity)).
entity_eidolon_mode(_,_).

%% A choice is data from this exact subject's authored associations, not an
%% executable client continuation. The recipe and its reads retain their own
%% anchored authorization and dependency tracking.
client_eidolon(Entity,Choice,View) :-
    term_variables([Entity,Choice],[]),
    Choice = eidolon(Purpose,Style,recipe(Ns,A,Recipe)),
    entity_eidolons(Entity,Purpose,Style,Choices), member_eq(Choice,Choices),
    current_ontology_identity(Here,History), Target = ontology_ref(Here,History),
    (member(Purpose,[playing,edition]) ->
        entity_scene(Entity,Purpose,appearance(_,_,Context,Layout,_)),
        in_ontology(Ns,A,eidolon(Recipe,Context,Model)),
        client_eidolon_scene(Entity,Purpose,Style,Layout,Model,View)
    ; in_ontology(Ns,A,eidolon(Recipe,subject(Target,Entity),View))).

client_eidolon_scene(Entity,Mode,_,_,contents(Exposure),
        eidolon_scene(Subject,Marks,Selection,Exposures)) :- !,
    current_ontology_identity(Ns,A), Subject = entity_ref(Ns,A,Entity),
    Exposure = exposure(Subject,_,_),
    space_exposure_projection(Exposure,Mode,Marks,Exposures),
    client_space_selection(Entity,Marks,Selection).
client_eidolon_scene(Entity,_,_,Layout,Model,
        eidolon_scene(entity_ref(Ns,A,Entity),Marks,nonphysical,[])) :-
    current_ontology_identity(Ns,A), scene_vocabulary(MNs,MA),
    in_ontology(MNs,MA,place_model(<<"selected">>,Layout,depicts(Ns,A,Entity),Model,Parts)),
    in_ontology(MNs,MA,model(Parts,Marks)).

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
public_source_query(client_eidolon(_, _, _)).
public_source_query(entity_scene(_, _, _)).

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
%% The first workbench depicts authored ground facts, not the inferred closure
%% or executable rule bodies. It shares the ordinary full-source read boundary.
prolog_introspection(workbench, content(Parents, Members, Attributes)) :-
    findall(isa(C, P), (clause(isa(C, P), true), atom(C), atom(P)), P0), sort(P0, Parents),
    findall(instance_of(C, I), (clause(instance_of(C, I), true),
             atom(C), term_variables(I, [])), M0), sort(M0, Members),
    findall(attribute(I, K, V), (clause(attribute(I, K, V), true),
             term_variables([I, K, V], [])), A0), sort(A0, Attributes).
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

space_instance(Space, Class) :-
    %% Bind the more selective side of this join first. Open catalogues start
    %% at the requested ancestry; exact subjects need only their own classes.
    findall(instance(Space,Class),
        (nonvar(Space) -> instance_of(Direct,Space),isa(Direct,Class)
        ; isa(Direct,Class),instance_of(Direct,Space)),Raw),
    sort(Raw,Distinct),member(instance(Space,Class),Distinct).


space_contains(Space, Subject) :- space_member(Space, Subject).
space_contains(Space, Subject) :- space_placement(Space, Subject, _).

space_simulation_domain(_,_,_,_) :- fail.

%% Contents is a recipe result, not a substitute mesh. The source owns the
%% complete permitted subject set and physical bindings in its own frame.
eidolon(space_contents, Space, contents(Exposure)) :-
    space_contents_projection(Space,Exposure).

space_contents_projection(Space,exposure(Frame,Revision,Subjects)) :-
    space_instance(Space,space), current_ontology_identity(Ns,A),
    Frame = entity_ref(Ns,A,Space),
    findall(Subject,space_contains(Space,Subject),Raw), sort(Raw,Unique),
    space_exposed_subjects(Unique,Space,Subjects),
    variant_digest(contents(Frame,Subjects),Revision).
space_exposed_subjects([],_,[]).
space_exposed_subjects([Subject|Rest],Space,[exposed(Subject,Relation,Binding)|Subjects]) :-
    Subject = entity_ref(_,_,_), term_variables(Subject,[]),
    findall(R,space_placement(Space,Subject,R),Assignments),
    (Assignments = [] -> Relation = display
    ; Assignments = [Assignment], Relation = placement(Assignment)),
    space_subject_binding(Space,Subject,Selected),
    (Selected = body_pose(_,_), space_simulation_domain(Space,World,_,_) ->
        Binding = in_frame(World,Selected)
    ; Binding = Selected),
    space_exposed_subjects(Rest,Space,Subjects).

world_view(Space, Mode, Marks) :-
    space_projection(Space,Mode,Marks,_).

%% The ordinary view and portable exposure receipt use one projection. Budget
%% comes from the pinned scene policy; there is no recursion/depth constant.
space_projection(Space,Mode,scene(Marks,Exposures)) :-
    space_projection(Space,Mode,Marks,Exposures).
space_projection(Space,Mode,Marks,Exposures) :-
    space_contents_projection(Space,Exposure),
    space_exposure_projection(Exposure,Mode,Marks,Exposures).

%% Selected contents and the ordinary interior share exactly one recursive
%% projection. A selected recipe's permitted subjects are never replaced by
%% a client inventory or by another read of the default exterior.
space_exposure_projection(exposure(Frame,_,Subjects),Mode,Marks,Exposures) :-
    member(Mode,[playing,edition]),
    Frame = entity_ref(Here,History,Space), current_ontology_identity(Here,History),
    unique_solution(scene_vocabulary(Ns,A)),
    in_ontology(Ns,A,limit(<<"scene">>,Allowance)),
    integer(Allowance), Allowance >= 0,
    (space_simulation_domain(Space,World,_,_) -> true; World = none),
    space_scene_parts(Subjects,Mode,[interior(Frame)],
        [representation(Frame,contents(Mode))],none,role(physical,World),Allowance,_,Parts,Exposures),
    in_ontology(Ns,A,model(Parts,Marks)).

space_scene_parts([],_,_,_,_,_,Remaining,Remaining,[],[]).
space_scene_parts([exposed(Subject,Relation,Binding)|Rest],Mode,Path,Seen,Parent,Role,
                  Available,Remaining,Parts,Exposures) :-
    (Available > 0 -> Next is Available - 1
    ; fail_with_reason(space_exposure_allowance)),
    Subject = entity_ref(Ns,A,Entity),
    in_ontology(Ns,A,entity_scene(Entity,Mode,Scene)),
    (Scene = hidden -> Placed = [], Current = [], After = Next
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
      space_occurrence_model(Model,Mode,OccurrencePath,Seen,Occurrence,NextRole,Next,After,
                             Local,Children,Descendants,Frame,Allowed,Status),
      scene_vocabulary(MNs,MA),
      in_ontology(MNs,MA,
            place_model(Occurrence,At,depicts(Ns,A,Entity),Local,Here)),
      append(Here,Children,Placed),
      Current = [exposure(Occurrence,OccurrencePath,Subject,selected(Recipes,Revision,Use),
                          Frame,Allowed,Pose,Status)|Descendants]),
    space_scene_parts(Rest,Mode,Path,Seen,Parent,Role,After,Remaining,Tail,Others),
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
                       Available,Remaining,Local,Children,Exposures,Frame,Subjects,Status) :-
    Key = representation(Frame,contents(Mode)),
    (member_eq(Key,Seen) ->
        Status = cycle, Remaining = Available, Children = [], Exposures = [],
        space_eidolon_status(<<"Contents cycle">>,Local)
    ; Status = contents, Local = [],
      space_scene_parts(Subjects,Mode,Path,[Key|Seen],Occurrence,Role,Available,Remaining,Children,Exposures)).
space_occurrence_model(Model,_,_,_,_,_,Available,Available,Model,[],[],none,[],model) :-
    Model \= contents(_).

space_parent_pose(none,Pose,Pose).
space_parent_pose(Parent,Pose,relative(Parent,Pose)) :- Parent \== none.

space_subject_binding(Space,Subject,Binding) :-
    (space_placement(Space,Subject,Assignment), space_simulation_domain(Space,World,_,Path) ->
        World = world_ref(Ns,A,W),
        in_ontology(Ns,A,physics_scene_binding(W,Path,Subject,Assignment,Binding))
    ; space_placement(Space,Subject,Assignment), space_instance(Space,physical_space) ->
        findall(binding(B,R),physics_body_definition(Space,B,R,_,_,live(Subject,Assignment,_,_)),
                [binding(Body,Revision)]), Binding = body_pose(Body,Revision)
    ; Binding = source_layout).

space_entity_model([recipe(Ns,A,Recipe)],Context,Model) :-
    in_ontology(Ns,A,eidolon(Recipe,Context,Model)).
space_entity_model([],_,Parts) :- space_eidolon_status(<<"No matching eidolon">>,Parts).
space_entity_model([_,_|_],_,Parts) :- space_eidolon_status(<<"Choose an eidolon">>,Parts).
space_eidolon_status(Text,
    [part(<<"eidolon-status">>,group,transform(0,0,0,0,0,0),
          no_surface,label(Text,<<"above">>),depicts_nothing)]).

entity_scene(Space, Mode, appearance(Space, Style, Space, Transform, Eidolons)) :-
    space_instance(Space, space), attribute(Space, transform, Transform),
    attribute(Space, exterior, Style),
    member(Mode, [playing, edition]), entity_eidolons(Space, Mode, Style, Eidolons).

class_eidolon(space,Mode,contents,recipe(Ns,A,space_contents)) :-
    member(Mode,[playing,edition]), current_ontology_identity(Ns,A).

%% A composed vocabulary is an explicit owner pin. Otherwise the installed
%% system GUI vocabulary supplies the common presentation policy and geometry.
scene_vocabulary(Ns,A) :-
    findall(ontology_ref(N,H),modelling_vocabulary(N,H),Pins),
    (Pins = [] -> quod:root::system_ontology(<<"quod:gui">>,A), Ns = <<"quod:gui">>
    ; Pins = [ontology_ref(Ns,A)]).
