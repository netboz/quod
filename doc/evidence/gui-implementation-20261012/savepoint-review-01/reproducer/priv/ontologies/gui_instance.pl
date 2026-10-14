%% Descriptor and binding helpers interpret data locally. A colon in an
%% input value is never a request to follow that value into another ontology.
no_follow(gui_schema/3).
no_follow(gui_definition/5).
no_follow(gui_compile/5).
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
no_follow(gui_validate_submission/6).
no_follow(gui_continue/1).
no_follow(gui_application_active/1).
no_follow(gui_submission_entry/2).

%% Reusable form behavior, composed at founding or by an authorized source
%% edit, just like agent_instance.pl. The application supplies gui_vocabulary/2,
%% component instances, attributes, gui_children/2 and gui_form/3. This file
%% grants no authority and owns no separate state or execution mechanism.

gui_schema(Form, Revision, Tree) :-
    gui_definition(Form, Revision, Tree, _, _).

gui_definition(Form, Revision, Tree, Fields, Submit) :-
    once(gui_compile(Form, Current, Compiled, Bindings, Submission)),
    Revision = Current, Tree = Compiled, Fields = Bindings, Submit = Submission.

gui_compile(Form, Revision, Tree, Fields, Submit) :-
    gui_local_id(Form),
    findall(ontology_ref(N, A), gui_vocabulary(N, A), [ontology_ref(Ns, Anchor)]),
    findall(binding(F, S), gui_form(Form, F, S), [binding(Fields, Submit)]),
    gui_component_tree(Form, Ns, [], _, RawTree),
    Ns::(current_ontology_identity(Ns, Anchor), gui_tree_schema(RawTree, Tree)),
    Tree = component(Form, form, _, _),
    %% These capabilities belong to the existing proof/source controllers,
    %% which own their edits and catalogues. A submitted form has no such owner.
    \+ (gui_tree_component(Tree, _, Kind, _, _),
        member(Kind, [editor, bindings, catalogue_selection])),
    Submit = submit(Control, Continuation),
    gui_local_id(Control),
    gui_tree_component(Tree, Control, button, _, _),
    gui_field_declarations(Fields, Tree, [], FieldIds),
    findall(Id, (gui_tree_component(Tree, Id, Kind, _, _),
                 member(Kind, [text_box, selection, slider, rotary_knob])), Inputs),
    sort(Inputs, Expected), sort(FieldIds, Expected),
    %% Only declared field variables may remain unbound in the continuation.
    term_variables(Fields, Variables), term_variables(Continuation, Used),
    gui_variables_bound(Used, Variables),
    '$quod_callable'(Continuation),
    gui_fixed_values(Fields, Form, Tree, Fixed),
    findall(C, gui_validation_context(Form, C), Contexts),
    term_variables(Contexts, []), sort(Contexts, Context),
    variant_digest(schema(1, ontology_ref(Ns, Anchor), Tree,
                          binding(Fields, Submit), Fixed, Context), Revision).

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

gui_field_declarations(Fields, Tree, Seen, Ids) :-
    nonvar(Fields),
    (Fields = [] -> Ids = Seen
    ; Fields = [Field | Rest], nonvar(Field), Field = field(Id, _),
      gui_local_id(Id), \+ member_eq(Id, Seen),
      gui_tree_component(Tree, Id, Kind, _, []),
      member(Kind, [text_box, selection, slider, rotary_knob]),
      gui_field_declarations(Rest, Tree, [Id | Seen], Ids)).

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
    Ns::(current_ontology_identity(Ns, Anchor), gui_initial_projection(Mode, Queries, Values)).

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
    gui_tree_active(Tree, Control),
    gui_bind_fields(Fields, Values, Tree, Checks),
    gui_fixed_values(Fields, Form, Tree, Fixed),
    gui_match_fixed(Fixed, Values),
    gui_vocabulary(Ns, Anchor),
    Ns::(current_ontology_identity(Ns, Anchor), gui_valid_values(Checks)),
    term_variables(Continuation, []).

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

%% One application policy relates forms to humans and responsible actors.
%% Authors supply no event handlers or client-provided executable goals.
can_invoke(Goal, Principal, _, _) :- gui_submission_entry(Goal, Principal).
gui_submission_entry((current_ontology_identity(_, _), Goal), Principal) :-
    gui_submission_entry(Goal, Principal).
gui_submission_entry(gui_validate_submission(Form, Human, Actor, _, _, _), Human) :-
    gui_question_policy(Form, Human, Actor).
gui_submission_entry(gui_continue(_), Actor) :- gui_question_policy(_, _, Actor).
gui_submission_entry(gui_application_active(_), Actor) :- gui_question_policy(_, _, Actor).

gui_validate_submission(Form, Human, Actor, Revision, Control, Fields) :-
    term_variables([Form, Human, Actor, Revision, Control, Fields], []),
    current_principal(Human), gui_question_policy(Form, Human, Actor),
    gui_bind(Form, Revision, Control, Fields, _).

gui_continue(question_ref(Ns, Anchor, Q)) :-
    term_variables([Ns, Anchor, Q], []),
    transaction((
        current_principal(Actor),
        current_ontology_identity(SourceNs, SourceAnchor),
        Ns::(current_ontology_identity(Ns, Anchor),
             gui_answer(Q, form_ref(SourceNs, SourceAnchor, Form), Human, Revision, Control, Fields)),
        gui_question_policy(Form, Human, Actor),
        gui_bind(Form, Revision, Control, Fields, Continuation),
        Reference = question_ref(Ns, Anchor, Q),
        \+ gui_application_active(Reference),
        assertz(gui_application_active(Reference)),
        call(Continuation),
        Ns::(current_ontology_identity(Ns, Anchor), gui_consume(Q)),
        retract(gui_application_active(Reference)))).
