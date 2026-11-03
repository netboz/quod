%% Shared GUI framework mechanics. No application facts, entry grants or
%% mutable lifecycle state are installed here. Each executing ontology supplies
%% its own pinned vocabulary, forms, fields, policy and authored continuation.
%% Descriptor values are data; a colon never requests argument following.

no_follow(gui_schema/3).
no_follow(gui_definition/5).
no_follow(gui_definition/6).
no_follow(gui_compile/6).
no_follow(gui_submission/4).
no_follow(gui_results/3).
no_follow(gui_bind_values/5).
no_follow(gui_component_tree/5).
no_follow(gui_class_basis/2).
no_follow(gui_component_children/5).
no_follow(gui_tree_component/5).
no_follow(gui_field_declarations/4).
no_follow(gui_variables_bound/2).
no_follow(gui_values/3).
no_follow(gui_initial_values/4).
no_follow(gui_project_values/5).
no_follow(gui_initial_queries/4).
no_follow(gui_fixed_values/4).
no_follow(gui_bind/5).
no_follow(gui_bind_fields/4).
no_follow(gui_match_fixed/2).
no_follow(gui_tree_active/2).
no_follow(gui_local_id/1).
no_follow(gui_semantic_tree/2).
no_follow(gui_semantic_children/2).

gui_schema(Form, Revision, Tree) :-
    gui_definition(Form, Revision, Tree, _, _).

gui_definition(Form, Revision, Tree, Fields, Submit) :-
    gui_definition(Form, Revision, Tree, Fields, Submit, question).

gui_definition(Form, Revision, Tree, Fields, Submit, Contract) :-
    once('$quod_state_check'(gui_compile(Form, Current, Compiled, Bindings,
                                       Submission, Authored))),
    Revision = Current, Tree = Compiled, Fields = Bindings,
    Submit = Submission, Contract = Authored.

gui_compile(Form, Revision, Tree, Fields, Submit, Contract) :-
    gui_local_id(Form),
    findall(ontology_ref(N, A), gui_vocabulary(N, A), [ontology_ref(Ns, Anchor)]),
    findall(binding(F, S), gui_form(Form, F, S), [binding(Fields, Declaration)]),
    gui_submission(Declaration, Submit, Contract, Results),
    gui_component_tree(Form, Ns, [], _, RawTree),
    in_ontology(Ns,Anchor, gui_tree_schema(RawTree, Tree, Inputs)),
    Tree = component(Form, form, _, _),
    %% These capabilities belong to the existing proof/source controllers,
    %% which own their edits and catalogues. A submitted form has no such owner.
    \+ (gui_tree_component(Tree, _, Kind, _, _),
        member(Kind, [editor, bindings, catalogue_selection])),
    Submit = submit(Control, Continuation),
    gui_local_id(Control),
    gui_tree_component(Tree, Control, button, _, _),
    gui_field_declarations(Fields, Inputs, [], FieldIds),
    sort(Inputs, Expected), sort(FieldIds, Expected),
    %% Inputs and named outputs are separate. Questions declare no outputs.
    gui_results(Results, [], _),
    term_variables(Fields, InputsUsed), term_variables(Results, Outputs),
    \+ (member(Output, Outputs), member_eq(Output, InputsUsed)),
    term_variables(Continuation, Used),
    term_variables(Fields-Results, Variables), gui_variables_bound(Used, Variables),
    gui_variables_bound(Outputs, Used),
    (Contract = operation(Permission, _) ->
        '$quod_callable'(Permission), term_variables(Permission, Parameters),
        gui_variables_bound(Parameters, InputsUsed)
    ; true),
    '$quod_callable'(Continuation),
    gui_fixed_values(Fields, Form, Tree, Fixed),
    findall(C, gui_validation_context(Form, C), Contexts),
    term_variables(Contexts, []), sort(Contexts, Context),
    gui_semantic_tree(Tree, Semantic),
    variant_digest(schema(1, ontology_ref(Ns, Anchor), Semantic,
                          binding(Fields, Declaration), Fixed, Context), Revision).

%% Appearance changes invalidate the installed projection, never a valid
%% submission baseline. Every behavioral property remains in this digest.
gui_semantic_tree(component(Id, Kind, Properties, Children),
                  component(Id, Kind, Semantic, Descendants)) :-
    findall(property(Key, Value),
            (member(property(Key, Value), Properties), Key \== appearance), Semantic),
    gui_semantic_children(Children, Descendants).
gui_semantic_children([], []).
gui_semantic_children([Child | Rest], [Semantic | Tail]) :-
    gui_semantic_tree(Child, Semantic), gui_semantic_children(Rest, Tail).

gui_submission(submit(Control, Goal), submit(Control, Goal), question, []).
gui_submission(submit(Control, Goal, operation(Permission, Results)),
               submit(Control, Goal), operation(Permission, Results), Results).

gui_results(Results, Seen, Names) :-
    nonvar(Results),
    (Results = [] -> Names = []
    ; Results = [Result | Rest], nonvar(Result), Result = result(Name, _),
      atom(Name), \+ member_eq(Name, Seen), Names = [Name | Tail],
      gui_results(Rest, [Name | Seen], Tail)).

gui_component_tree(Id, Ns, Seen, All, component(Id, Classes, Attributes, Children)) :-
    gui_local_id(Id), \+ member_eq(Id, Seen),
    findall(attribute(Key, Value), attribute(Id, Key, Value), Attributes),
    findall(C, instance_of(C, Id), DirectClasses),
    term_variables(DirectClasses, []),
    findall(Local, (member(Class, DirectClasses),
                    gui_class_basis(Class, Parent),
                    '$quod_owner_name'(Parent, Owner, Local),
                    ontology_name(Owner, Ns)), Raw),
    sort(Raw, Classes),
    findall(C, gui_children(Id, C), ChildDeclarations),
    (ChildDeclarations = [] -> ChildIds = []
    ; ChildDeclarations = [ChildIds]),
    term_variables(ChildIds, []),
    gui_component_children(ChildIds, Ns, [Id | Seen], All, Children).

%% The vocabulary resolves its own class closure in one selected call. Only
%% application-local subclasses need a traversal before that call; expanding
%% every foreign ancestor here would repeatedly ask for the same hierarchy.
gui_class_basis(Class, Class) :- nonvar(Class), Class = _:_, !.
gui_class_basis(Class, Parent) :- isa(Class, Parent).

gui_component_children([], _, Seen, Seen, []).
gui_component_children([Id | Rest], Vocabulary, Seen, All, [Child | Children]) :-
    gui_component_tree(Id, Vocabulary, Seen, Next, Child),
    gui_component_children(Rest, Vocabulary, Next, All, Children).

gui_tree_component(component(Id, Kind, Properties, Children), Id, Kind, Properties, Children).
gui_tree_component(component(_, _, _, Children), Id, Kind, Properties, Descendants) :-
    member(Child, Children), gui_tree_component(Child, Id, Kind, Properties, Descendants).

gui_field_declarations(Fields, Inputs, Seen, Ids) :-
    nonvar(Fields),
    (Fields = [] -> Ids = Seen
    ; Fields = [Field | Rest], nonvar(Field), Field = field(Id, _),
      gui_local_id(Id), \+ member_eq(Id, Seen),
      member_eq(Id, Inputs),
      gui_field_declarations(Rest, Inputs, [Id | Seen], Ids)).

gui_variables_bound([], _).
gui_variables_bound([Variable | Rest], Variables) :-
    member_eq(Variable, Variables), gui_variables_bound(Rest, Variables).

%% Initial values are a separate projection. Reading them never instantiates
%% the form's submitted variables and never changes its semantic revision.
gui_values(Form, ValuesToken, Values) :-
    gui_definition(Form, _, Tree, Fields, _),
    gui_initial_values(Fields, Form, Tree, Values),
    term_digest(Values, ValuesToken).

gui_initial_values(Fields, Form, Tree, Values) :-
    gui_project_values(editing, Fields, Form, Tree, Values).

gui_project_values(_, [], _, _, []) :- !.
gui_project_values(Mode, Fields, Form, Tree, Values) :-
    gui_initial_queries(Fields, Form, Tree, Queries),
    gui_vocabulary(Ns, Anchor),
    in_ontology(Ns,Anchor, gui_initial_projection(Mode, Queries, Values)).

gui_initial_queries([], _, _, []).
gui_initial_queries([field(Id, _) | Rest], Form, Tree,
                    [initial(Id, Kind, Properties, Declared) | Queries]) :-
    once(gui_tree_component(Tree, Id, Kind, Properties, [])),
    findall(V, gui_initial(Form, Id, V), Declared),
    term_variables(Declared, []),
    gui_initial_queries(Rest, Form, Tree, Queries).

%% Values frozen by readonly/disabled controls are validation inputs, so they
%% participate in the revision. Ordinary editable defaults remain separate.
gui_fixed_values(Fields, Form, Tree, Fixed) :-
    findall(field(Id, frozen),
        (member(field(Id, _), Fields), once(gui_tree_component(Tree, Id, _, Properties, [])),
         (member(property(readonly, true), Properties) -> true; \+ gui_tree_active(Tree, Id))),
        Frozen),
    gui_project_values(frozen, Frozen, Form, Tree, Fixed).

%% Construct only the authored continuation. This pure helper is called by
%% question submission/completion; it does not execute a client-supplied goal.
gui_bind(Form, Revision, Control, Values, Continuation) :-
    term_variables(Form-Revision-Control-Values, []),
    gui_local_id(Form), gui_local_id(Control),
    gui_definition(Form, Revision, Tree, Fields, submit(Control, Continuation)),
    gui_bind_values(Form, Tree, Fields, Control, Values),
    term_variables(Continuation, []).

gui_bind_values(Form, Tree, Fields, Control, Values) :-
    gui_tree_active(Tree, Control),
    gui_bind_fields(Fields, Values, Tree, Checks),
    gui_fixed_values(Fields, Form, Tree, Fixed),
    gui_match_fixed(Fixed, Values),
    gui_vocabulary(Ns, Anchor),
    in_ontology(Ns,Anchor, gui_valid_values(Checks)).

gui_bind_fields([], [], _, []).
gui_bind_fields([field(Id, Value) | Rest], Values, Tree,
                [value(Kind, Properties, Value) | Checks]) :-
    %% The compiled tree and field declarations have unique identities. Once
    %% an exact submitted field is selected, later validation must not explore
    %% alternative list decompositions across the rest of a large form.
    once((delete(Values, field(Id, Value), Remaining),
          gui_tree_component(Tree, Id, Kind, Properties, []))),
    gui_bind_fields(Rest, Remaining, Tree, Checks).

gui_match_fixed([], _).
gui_match_fixed([Field | Rest], Values) :-
    member_eq(Field, Values), gui_match_fixed(Rest, Values).

gui_tree_active(component(Node, _, Properties, Children), Id) :-
    member(property(enabled, true), Properties),
    (Node == Id -> true; member(Child, Children), gui_tree_active(Child, Id)).

%% The source ontology owns form/control identities. Parameterized local
%% identities are allowed; foreign forms are entered through anchored ::.
gui_local_id(Id) :- term_variables(Id, []), \+ (Id = _:_) .

%% Offered operations interpret the same forms and class recipe selections.
%% This base advertises no ontology interfaces and grants no invocation rights.
gui_operation_classes(Classes) :-
    '$quod_state_check'((
        current_ontology_identity(Ns, Anchor),
        findall(Class, (isa(Class, Class),
            class_eidolons([Class], operation(class), _, Choices),
            member(eidolon(_,Name,_),Choices),
            gui_operation_form(class_ref(Ns,Anchor,Class), Name, _, _, _)), Raw),
        sort(Raw, Classes))).

no_follow(gui_operations/2).
no_follow(gui_operation/6).
no_follow(gui_operation_view/3).
no_follow(gui_operation_definition/8).
no_follow(gui_operation_form/5).
no_follow(gui_operation_subject/4).
no_follow(gui_operation_bind/7).
no_follow(gui_operation_binding/7).
no_follow(gui_operation_guard/7).
no_follow(gui_operation_availability/3).

gui_operations(Subject, Operations) :-
    term_variables(Subject, []),
    '$quod_state_check'((
        gui_operation_subject(Subject, _, Classes, Mode),
        class_eidolons(Classes, operation(Mode), _, Recipes),
        findall(Name, member(eidolon(_, Name, _), Recipes), Raw), sort(Raw, Names),
        findall(View, (member(Name, Names), gui_operation_view(Subject, Name, View)), Operations))).

gui_operation_view(Subject, Name,
        operation_view(Name, Subject, Revision, Tree, Token, Values, Control, Names, Availability)) :-
    gui_operation_definition(Subject, Name, Revision, Form, Tree, Fields,
                             submit(Control, _), operation(Local, Permission, Results)),
    gui_initial_values(Fields, Form, Tree, Values), term_digest(Values, Token),
    gui_results(Results, [], Names),
    gui_operation_availability(Local, Permission, Availability).

%% A recipe selects a local form for this exact subject. The form, its fixed
%% values, output sharing and permission parameters all enter the revision.
%% Existing recipe selection retains most-specific/ambiguous-class semantics.
gui_operation_definition(Subject, Name, Revision, Form, Tree, Fields, Submit,
                         operation(Local, Permission, Results)) :-
    gui_operation_form(Subject, Name, Local, Recipe, Form),
    gui_definition(Form, Schema, Tree, Fields, Submit, operation(Permission, Results)),
    variant_digest(offered_operation(Subject, Name, Recipe, Form, Schema), Revision).

gui_operation_form(Subject, Name, Local, recipe(Ns,Anchor,Recipe), Form) :-
    gui_operation_subject(Subject, Local, Classes, Mode),
    class_eidolons(Classes, operation(Mode), Name,
                   [eidolon(operation(Mode), Name, recipe(Ns, Anchor, Recipe))]),
    current_ontology_identity(Here, History), Target = ontology_ref(Here, History),
    findall(F, in_ontology(Ns,Anchor,
                    eidolon(Recipe, subject(Target, Local), operation(F))), [Form]).

gui_operation_subject(class_ref(Ns, Anchor, Class), class(Class), [Class], class) :-
    current_ontology_identity(Ns, Anchor), isa(Class, Class).
gui_operation_subject(entity_ref(Ns, Anchor, Entity), instance(Entity), Classes, instance) :-
    current_ontology_identity(Ns, Anchor),
    findall(Class, instance_of(Class, Entity), Raw), sort(Raw, Classes), Classes \== [].

%% These are output arguments, never an accepted executable continuation.
%% Result variables remain shared with the authored goal, outside input fields.
gui_operation_bind(Subject, Name, Revision, Control, Values, Goal, Results) :-
    var(Goal), var(Results),
    gui_operation_binding(Subject, Name, Revision, Control, Values, Authored, Results),
    Goal = (gui_operation_guard(Subject, Name, Revision, Control, Values, Authored, Results), Authored).

%% Ordinary Prolog composition keeps the executable binding local. The same
%% binder and guard remain authoritative for callers transporting a bound goal.
gui_operation(Subject, Name, Revision, Control, Values, Results) :-
    gui_operation_bind(Subject, Name, Revision, Control, Values, Goal, Results), call(Goal).

gui_operation_binding(Subject, Name, Revision, Control, Values, Goal, Results) :-
    term_variables([Subject, Name, Revision, Control, Values], []),
    '$quod_state_check'((
        gui_operation_definition(Subject, Name, Revision, Form, Tree, Fields,
                                 submit(Control, Goal), operation(Local, Permission, Results)),
        gui_bind_values(Form, Tree, Fields, Control, Values),
        operation_authorized(Local, Permission))).

%% The returned ordinary goal checks the current declaration and permission
%% again at execution. Compare variants without unifying: prebinding or adding
%% output aliases must not change creation into existing-instance classification.
gui_operation_guard(Subject, Name, Revision, Control, Values, Goal, Results) :-
    gui_operation_binding(Subject, Name, Revision, Control, Values, Authored, Outputs),
    variant_digest(binding(Authored, Outputs), Digest),
    variant_digest(binding(Goal, Results), Digest).

gui_operation_availability(Subject, Permission, Availability) :-
    (term_variables(Permission, []) ->
        (operation_authorized(Subject, Permission) -> Availability = available
        ; Availability = unavailable)
    ; Availability = requires_input).

