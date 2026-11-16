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
    (quod:space::space_instance(entity_ref(Ns,Anchor,Space), space),
     findall(Scene, quod:space::world_view(entity_ref(Ns,Anchor,Space), Mode, Scene), [Marks]),
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
    ((Name == unnamed; Name == <<"">>) -> Label = unlabelled
    ; Label = label(Name,<<"above">>)).

client_view_dependencies([]).
client_view_dependencies([dependency(Ns, Anchor, _) | Rest]) :-
    Ns::current_ontology_identity(Ns, Anchor),
    client_view_dependencies(Rest).

client_space_selection(Space, Marks, Selection) :-
    current_ontology_identity(Store,Anchor), Subject = entity_ref(Store,Anchor,Space),
    (quod:space::space_simulation_domain(Subject,world_ref(Ns,A,W),_,Path) ->
        (Ns::(current_ontology_identity(Ns,A),physics_client_view(W,Marks,Physical),
               physics_view_frames(W,Path,Frames),physics_scene_frames(W,Marks,BodyFrames)),
         client_simulation_frame(Space,Frames,BodyFrames,Physical,Selection) -> true
        ; Selection = unavailable)
    ; quod:space::space_instance(Subject, physical_space) ->
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
isa(ontology, quod:space:space).
instance_of(ontology, ontology_ref(Namespace, Anchor)) :-
    current_ontology_identity(Namespace, Anchor).

%% Reflected instances are ordinary local terms. Their source catalogue remains
%% authoritative, including interpreted empty definitions; reads create no state.
isa(predicate, thing).
instance_of(predicate, predicate(Indicator)) :-
    ontology_inspect(predicates(Indicator), Indicators), member(Indicator, Indicators).
ontology_predicate(Indicator, Index) :-
    ontology_inspect(predicate(Indicator), Entries), member(predicate(Indicator,Index), Entries).
ontology_inspect(Query, Result) :-
    current_ontology_identity(Namespace, Anchor),
    quod:root::system_ontology(<<"quod:gui">>, ToolsAnchor),
    in_ontology(<<"quod:gui">>, ToolsAnchor,
        prolog_inspect(ontology_ref(Namespace, Anchor), Query, Result)).

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
    ontology_predicate(Indicator, Index),
    X is (Index mod 16) * 1200, Y is -(Index // 16) * 800,
    Pose = transform(X,Y,0,0,0,0),
    entity_eidolons(predicate(Indicator),Mode,solid,Eidolons).
eidolon(predicate_model,predicate(Indicator),
        [part(<<"predicate">>,box(800,500,200),transform(0,0,0,0,0,0),
              surface(<<"#6A90D9">>,0,700,0,1000,[]),label(Label,<<"above">>),depicts_nothing)]) :-
    instance_of(predicate,predicate(Indicator)),
    '$quod_program_source'([Indicator],Source), binary_codes(Source,Codes),
    append(LabelCodes,[46,10],Codes), binary_codes(Label,LabelCodes).

%% These are display members, never containing-space assignments or grants.
space_member(ontology_ref(Ns,A),entity_ref(Ns,A,predicate(Indicator))) :-
    current_ontology_identity(Ns,A), instance_of(predicate,predicate(Indicator)).
attribute(ontology_ref(Ns,A),transform,transform(0,0,0,0,0,0)) :- current_ontology_identity(Ns,A).
attribute(ontology_ref(Ns,A),exterior,contents) :- current_ontology_identity(Ns,A).
attribute(ontology_ref(Ns,A),dimensions,infinite) :- current_ontology_identity(Ns,A).

class_eidolon(thing, prolog, source, recipe(Namespace, Anchor, prolog_editor)) :-
    Namespace = <<"quod:gui">>,
    quod:root::system_ontology(Namespace, Anchor).

class_eidolon(ontology, inspection, Name, recipe(Namespace, Anchor, Name)) :-
    member(Name, [policy, interfaces, routes]),
    Namespace = <<"quod:gui">>,
    quod:root::system_ontology(Namespace, Anchor).

class_eidolon(ontology, workspace, workbench, recipe(Namespace, Anchor, workbench)) :-
    Namespace = <<"quod:gui">>, quod:root::system_ontology(Namespace, Anchor).

class_eidolon(ontology,Mode,contents,recipe(Ns,A,ontology_contents)) :-
    member(Mode,[playing,edition]), current_ontology_identity(Ns,A).
attribute(eidolon(ontology,playing,contents),label,<<"Contents">>).
attribute(eidolon(ontology,playing,contents),image,Icon) :- menu_icon(contents,Icon).
eidolon(ontology_contents,subject(ontology_ref(Ns,A),Space),contents(Exposure)) :-
    current_ontology_identity(Ns,A), ontology_inspect(predicates(_),_),
    quod:space::space_contents_projection(entity_ref(Ns,A,Space),Exposure).

%% Menus are class-selected Eidolons like views. The pinned GUI vocabulary
%% supplies every thing's default pie; a class overrides it with its own
%% `menu` recipe through the ordinary most-specific-class rule.
class_eidolon(thing, menu, default, recipe(Ns, Anchor, default_menu)) :-
    menu_vocabulary(Ns, Anchor).

%% Forms already pin their GUI vocabulary; otherwise the installed system
%% GUI ontology supplies menus, as it does for scene vocabulary.
menu_vocabulary(Ns, Anchor) :-
    findall(ontology_ref(N, H), gui_vocabulary(N, H), Pins),
    (Pins = [] -> Ns = <<"quod:gui">>, quod:root::system_ontology(Ns, Anchor)
    ; Pins = [ontology_ref(Ns, Anchor)]).

no_follow(menu_icon/2).
menu_icon(Name, Icon) :-
    menu_vocabulary(Gui, Anchor), in_ontology(Gui, Anchor, gui_icon(Name, Icon)).

%% One signed read per pie: the subject's single selected menu recipe.
client_menu(Subject, View) :-
    term_variables(Subject, []),
    (Subject = class_ref(_,_,_) -> gui_operation_subject(Subject,class(Entity),_,class)
    ; Entity = Subject),
    entity_eidolons(Entity, menu, _, Choices),
    (Choices = [Choice] -> client_eidolon(Entity, Choice, View)
    ; Choices = [] -> View = none
    ; fail_with_reason(ambiguous_menu(Entity))).

entity_eidolons(Entity,Eidolons) :- entity_eidolons(Entity,_,_,Eidolons).
entity_eidolons(Entity,Purpose,Name,Eidolons) :-
    findall(Direct,(instance_of(Direct,Entity); Direct = Entity, isa(Direct,Direct)),Raw),
    sort(Raw,Classes), class_eidolons(Classes,Purpose,Name,Offered),
    findall(eidolon(Mode,Kind,Recipe),
        (member(eidolon(Mode,Kind,Recipe),Offered), entity_eidolon_mode(Entity,Mode)), Eidolons).

entity_eidolon_mode(Entity,operation(class)) :- !, once(isa(Entity,Entity)).
entity_eidolon_mode(Entity,operation(instance)) :- !, once(instance_of(_,Entity)).
entity_eidolon_mode(_,_).

%% Authored instance scenes override inherited class behavior. Each class
%% owner is read once with the exact storing subject; the selected recipe may
%% belong to another ontology. Conflicting inherited answers remain visible.
no_follow(client_entity_scene/3).
client_entity_scene(Entity, Mode, Scene) :-
    findall(S, entity_scene(Entity, Mode, S), Local),
    (Local \== [] -> member(Scene, Local)
    ; current_ontology_identity(Here, History),
      entity_classes(Entity, Classes),
      findall(owner(Class, Ns), (member(Class, Classes),
          '$quod_owner_name'(Class, Name, _), ontology_name(Name, Ns)), Owners),
      findall(Ns, member(owner(_, Ns), Owners), Names), sort(Names, Unique),
      findall(candidate(Class, S), (member(Ns, Unique),
          Ns::entity_scene(subject(ontology_ref(Here, History), Entity), Mode, S),
          member(owner(Class, Ns), Owners)), Candidates),
      findall(Class, member(candidate(Class, _), Candidates), Declaring),
      findall(S, (member(candidate(Class, S), Candidates),
          \+ '$quod_stricter_class'(Class, Declaring)), Raw),
      sort(Raw, Scenes), member(Scene, Scenes)).

%% Which Eidolon a viewer sees: their own choice, else the instance's, else
%% the class default. The viewer's choice lives in their own ontology and
%% changes only what they see; physics and other readers of
%% client_entity_scene/3 keep the instance's. A choice naming an Eidolon the
%% thing's classes no longer list counts as none. No viewer, or no choice, is
%% an ordinary no.
viewer_eidolon(Entity, Purpose, Name, Eidolons) :-
    current_ontology_identity(Ns, A),
    quod:user::shown_as(entity_ref(Ns, A, Entity), Purpose, Name),
    entity_eidolons(Entity, Purpose, Name, Eidolons), Eidolons \== [].
viewer_scene(Entity, Mode, Scene) :-
    client_entity_scene(Entity, Mode, Declared),
    (Declared = appearance(Id, _, Context, Layout, _),
     viewer_eidolon(Entity, Mode, Name, Eidolons) ->
        Scene = appearance(Id, Name, Context, Layout, Eidolons)
    ; Scene = Declared).
eidolon_seen(Entity, Purpose, Name, Eidolons) :-
    (viewer_eidolon(Entity, Purpose, Name, Eidolons) -> true
    ; once(client_entity_scene(Entity, Purpose, appearance(_, Name, _, _, Eidolons)))).

%% A choice is data from this exact subject's authored associations, not an
%% executable client continuation. The recipe and its reads retain their own
%% anchored authorization and dependency tracking.
client_eidolon(Entity,Choice,View) :-
    term_variables([Entity,Choice],[]),
    Choice = eidolon(Purpose,Name,recipe(Ns,A,Recipe)),
    entity_eidolons(Entity,Purpose,Name,Choices), member_eq(Choice,Choices),
    current_ontology_identity(Here,History), Target = ontology_ref(Here,History),
    (client_scene_purpose(Purpose,Shown) ->
        client_entity_scene(Entity,Shown,appearance(_,_,Context,Layout,_)),
        in_ontology(Ns,A,eidolon(Recipe,Context,Model)),
        client_eidolon_scene(Entity,Purpose,Name,Layout,Model,View)
    ; in_ontology(Ns,A,eidolon(Recipe,subject(Target,Entity),View))).

%% Each shown thing has a mode, display by default. A class may also offer a
%% `selected` Eidolon; it adds to the thing as displayed, so it shares the
%% display scene's context and place. None is required.
client_scene_purpose(playing,playing).
client_scene_purpose(edition,edition).
client_scene_purpose(selected,playing).

client_eidolon_scene(Entity,Mode,_,_,contents(Exposure),
        eidolon_scene(Subject,Marks,Selection,Exposures)) :- !,
    current_ontology_identity(Ns,A), Subject = entity_ref(Ns,A,Entity),
    Exposure = exposure(Subject,_,_),
    quod:space::space_exposure_projection(Exposure,Mode,Marks,Exposures),
    client_space_selection(Entity,Marks,Selection).
client_eidolon_scene(Entity,_,_,Layout,Model,
        eidolon_scene(entity_ref(Ns,A,Entity),Marks,nonphysical,[])) :-
    current_ontology_identity(Ns,A), scene_vocabulary(MNs,MA),
    in_ontology(MNs,MA,place_model(<<"selected">>,Layout,depicts(Ns,A,Entity),Model,Parts)),
    in_ontology(MNs,MA,model(Parts,Marks)).

class_eidolons(Classes,Eidolons) :- class_eidolons(Classes,_,_,Eidolons).
%% For a class another ontology owns, every isa/2 answer is a proof in that
%% ontology. Each class's ancestors are therefore read once, and the test that
%% keeps only the most specific recipe compares those lists.
class_eidolons(Classes,Purpose,Name,Eidolons) :-
    findall(candidate(Class,Purpose,Name,Recipe),
        (member(Direct,Classes), class_ancestors(Direct,Above), member(Class,Above),
         class_eidolon(Class,Purpose,Name,Recipe)), Candidates),
    findall(Class, member(candidate(Class,_,_,_),Candidates), Raw), sort(Raw, Declaring),
    findall(Class-Above, (member(Class,Declaring), class_ancestors(Class,Above)), Chains),
    findall(eidolon(Purpose,Name,Recipe),
        (member(Candidate,Candidates),
         Candidate = candidate(Class,Purpose,Name,Recipe),
         \+ (member(candidate(Other,Purpose,Name,_),Candidates),
             class_below(Other,Class,Chains), \+ class_below(Class,Other,Chains)),
         \+ local_recipe_overrides(Candidate,Candidates)), Choices),
    sort(Choices, Eidolons).

%% A class with every class above it, itself included, as canonical names.
class_ancestors(Class,Above) :-
    findall(Name,((C = Class; isa(Class,C)), '$quod_name_normalize'(C,Name)),Raw), sort(Raw,Above).
%% Whether Sub is Super or below it, from the ancestors already read.
class_below(Sub,Super,Chains) :- member(Class-Above,Chains), Class == Sub, !, member_eq(Super,Above).

%% A locally authored recipe of the same class, purpose, Eidolon and recipe
%% replaces an imported copy. Other imported choices remain alternatives.
local_recipe_overrides(candidate(Class,Purpose,Name,recipe(OtherNs,_,Recipe)),Candidates) :-
    current_ontology_identity(Ns,A), OtherNs \== Ns,
    member(candidate(Class,Purpose,Name,recipe(Ns,A,Recipe)),Candidates).

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
    (Requested = instance(Instance), '$quod_construction'(Instance, Class, Inputs),
     instance_of(Class, Instance) ->
        Subject = construction(Class, Instance, Inputs)
    ; Subject = Requested),
    current_principal(Actor),
    '$quod_committed_check'(operation_policy(Actor, Subject, Operation)).

operation_policy(Actor, Subject, Operation) :-
    term_variables(Actor-Subject-Operation, []),
    functor(Operation, Name, _), atom(Name),
    operation_classes(Subject, Classes), Classes \== [], term_variables(Classes, []),
    findall(requirement(Class, Check), (member(Class, Classes),
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
operation_requirements([requirement(Class, Check) | Rest], Actor, Subject, Operation) :-
    atom(Check), '$quod_class_predicate'(Class, Check, Owned),
    operation_check(Owned, Actor, Subject, Operation),
    operation_requirements(Rest, Actor, Subject, Operation).

%% Checks are named Prolog predicates of arity three, receiving the exact
%% actor, subject and operation (including parameters). Missing checks fail.
operation_check(Check, Actor, Subject, Operation) :-
    ('$quod_owner_name'(Check, Ns, Name) ->
        Goal =.. [Name, Actor, Subject, Operation], Ns::Goal
    ; atom(Check), Goal =.. [Check, Actor, Subject, Operation], call(Goal)).

'$quod_class_predicate'(Class, Check, Owned) :-
    ('$quod_owner_name'(Class, Ns, _) -> Owned = Ns:Check; Owned = Check).

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
        findall(candidate(Class, Grant), (member(candidate(Class, Grant), Candidates),
                       \+ '$quod_stricter_class'(Class, Declaring)), Selected)
    ; findall(candidate(local, Grant), member(Grant, Overrides), Selected)),
    term_variables(Selected, []), operation_grants(Selected, Grants),
    sort(Grants, [Grant]),
    permission_allows(Grant, Actor, Subject, Operation).

%% Validate authored grants before attaching the class owner's check identity.
%% Equal check names at different owners are different defaults.
operation_grants([], []).
operation_grants([candidate(Class, Grant) | Rest], [Owned | Grants]) :-
    permission_grant(Grant),
    (Grant = check(Check) ->
        '$quod_class_predicate'(Class, Check, Predicate), Owned = check(Predicate)
    ; Owned = Grant),
    operation_grants(Rest, Grants).

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

%% Instance policy stays in the storing ontology. Qualified class declarations
%% follow their owner; an unqualified local class never selects another owner.
no_follow(operation_authorized/2).
no_follow(operation_policy/3).
no_follow(operation_classes/2).
no_follow(operation_requirements/4).
no_follow(operation_check/4).
no_follow('$quod_class_predicate'/3).
no_follow(operation_grant/5).
no_follow(operation_grants/2).
no_follow(operation_override/3).
no_follow(permission_grant/1).
no_follow(permission_allows/4).
no_follow(set_instance_permission/3).
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
public_source_query(client_entity_scene(_, _, _)).
public_source_query(viewer_eidolon(_, _, _, _)).
public_source_query(viewer_scene(_, _, _)).
public_source_query(eidolon_seen(_, _, _, _)).
public_source_query(client_menu(_, _)).
public_source_query(gui_menu_source(_, _)).

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
    prolog_introspection(predicates(_), Indicators).
prolog_introspection(predicates(Indicator), Indicators) :-
    findall(Indicator, current_predicate(Indicator), Unsorted),
    sort(Unsorted, Indicators).
%% Exact membership and layout use the same source-authorized sorted catalogue;
%% keep the catalogue inside its owner instead of transferring it per subject.
prolog_introspection(predicate(Indicator), Entries) :-
    prolog_introspection(predicates, Indicators),
    (term_variables(Indicator,[]) ->
        (once(append(Before,[Indicator|_],Indicators)) ->
            length(Before,Index), Entries = [predicate(Indicator,Index)]
        ; Entries = [])
    ; findall(predicate(Indicator,Index),
        (append(Before,[Indicator|_],Indicators), length(Before,Index)), Entries)).
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
%% Class traversal qualifies owner answers itself, including the starting
%% class; generic argument following would lose the parents' owner.
no_follow(isa/2).
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
    ('$quod_owner_name'(Subclass, _, _) ->
        '$quod_isa_path'(Subclass, Superclass, [])
    ; '$quod_isa_requires_closure'(Subclass, Superclass),
      '$quod_direct_isa'(Subclass, Parent),
      \+ member_eq(Parent, [Subclass]),
      '$quod_isa_path'(Parent, Superclass, [Parent, Subclass])).

%% A fully-ground direct query should reach its authored clause without first
%% walking the rest of the hierarchy. Open queries still enumerate closure
%% answers, while a ground non-edge takes the transitive path.
'$quod_isa_requires_closure'(Subclass, _) :- var(Subclass).
'$quod_isa_requires_closure'(_, Superclass) :- var(Superclass).
'$quod_isa_requires_closure'(Subclass, Superclass) :-
    \+ '$quod_direct_isa'(Subclass, Superclass).

%% Once a path reaches a foreign class, ask its owning ontology for the rest
%% of the public `isa/2` relation and qualify every answer back into the
%% caller's graph. '$quod_direct_isa'/2 selects only authored immediate edges.
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
no_follow(class_ancestors/2).
no_follow(class_below/3).
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

%% A composed vocabulary is an explicit owner pin. Otherwise the installed
%% system GUI vocabulary supplies the common presentation policy and geometry.
scene_vocabulary(Ns,A) :-
    findall(ontology_ref(N,H),modelling_vocabulary(N,H),Pins),
    (Pins = [] -> quod:root::system_ontology(<<"quod:gui">>,A), Ns = <<"quod:gui">>
    ; Pins = [ontology_ref(Ns,A)]).
