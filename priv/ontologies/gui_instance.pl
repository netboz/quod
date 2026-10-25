%% Descriptor and binding helpers interpret data locally. A colon in an
%% input value is never a request to follow that value into another ontology.
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
no_follow(gui_validate_submission/6).
no_follow(gui_continue/1).
no_follow(gui_application_active/1).
no_follow(gui_submission_entry/2).
no_follow(gui_form_projection/4).

%% Reusable form behavior, composed at founding or by an authorized source
%% edit, just like agent_instance.pl. The application supplies gui_vocabulary/2,
%% component instances, attributes, gui_children/2 and gui_form/3. This file
%% grants narrow submission/continuation entries under gui_question_policy/3;
%% it owns no separate execution mechanism.

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
    Ns::(current_ontology_identity(Ns, Anchor), gui_tree_schema(RawTree, Tree, Inputs)),
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
    variant_digest(schema(1, ontology_ref(Ns, Anchor), Tree,
                          binding(Fields, Declaration), Fixed, Context), Revision).

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
    gui_bind_values(Form, Tree, Fields, Control, Values),
    term_variables(Continuation, []).

gui_bind_values(Form, Tree, Fields, Control, Values) :-
    gui_tree_active(Tree, Control),
    gui_bind_fields(Fields, Values, Tree, Checks),
    gui_fixed_values(Fields, Form, Tree, Fixed),
    gui_match_fixed(Fixed, Values),
    gui_vocabulary(Ns, Anchor),
    Ns::(current_ontology_identity(Ns, Anchor), gui_valid_values(Checks)).

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
gui_submission_entry(gui_form_projection(Form, Human, Actor, _), Human) :-
    gui_question_policy(Form, Human, Actor).
gui_submission_entry(gui_continue(_), Actor) :- gui_question_policy(_, _, Actor).
gui_submission_entry(gui_application_active(_), Actor) :- gui_question_policy(_, _, Actor).

gui_validate_submission(Form, Human, Actor, Revision, Control, Fields) :-
    term_variables([Form, Human, Actor, Revision, Control, Fields], []),
    current_principal(Human), gui_question_policy(Form, Human, Actor),
    gui_bind(Form, Revision, Control, Fields, _).

%% Schema and defaults come from one compilation in the selected source scope.
%% The continuation stays in the ontology; a client receives only its control.
gui_form_projection(Form, Human, Actor,
                    form_view(Revision, Tree, ValuesToken, Values, Control)) :-
    term_variables([Form, Human, Actor], []),
    current_principal(Human), gui_question_policy(Form, Human, Actor),
    gui_definition(Form, Revision, Tree, Fields, submit(Control, _)),
    gui_initial_values(Fields, Form, Tree, Values),
    term_digest(Values, ValuesToken).

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

%% One occurrence, one original atomic request. The shared responder transition
%% owns the HUD consequence; authors only declare policy and the continuation.
no_follow(gui_open/2).
no_follow(gui_open_definition/5).
gui_submission_entry(gui_open(Form, _), Caller) :-
    gui_question_policy(Form, Human, Actor), (Caller = Human; Caller = Actor).
gui_submission_entry(gui_open_definition(Form, Human, Actor, _, _), Caller) :-
    gui_question_policy(Form, Human, Actor), (Caller = Human; Caller = Actor).

gui_open(Form, Reference) :-
    term_variables(Form, []),
    transaction((
        current_principal(Caller),
        findall(pair(H, A), (gui_question_policy(Form, H, A), (Caller = H; Caller = A)),
                [pair(Human, Actor)]),
        gui_open_definition(Form, Human, Actor, Reference, View),
        current_ontology_identity(SourceNs, SourceAnchor),
        Source = form_ref(SourceNs, SourceAnchor, Form),
        Actor = agent_instance_ref(ActorNs, ActorAnchor, Instance),
        ActorNs::(current_ontology_identity(ActorNs, ActorAnchor),
                  gui_responder_for(Instance, Source, Human, Hosting)),
        Human = agent_instance_ref(HumanNs, HumanAnchor, HumanInstance),
        HumanNs::(current_ontology_identity(HumanNs, HumanAnchor),
                  gui_receiver_accept(HumanInstance, Receiver, Capacity)),
        gui_vocabulary(GuiNs, GuiAnchor),
        Opening = gui_opening(ontology_ref(GuiNs, GuiAnchor), Reference, Source, Human, Actor,
                              View, Receiver, Hosting, Capacity),
        GuiNs::(current_ontology_identity(GuiNs, GuiAnchor), gui_prepare_question(Opening)),
        ActorNs::(current_ontology_identity(ActorNs, ActorAnchor), gui_accept_question(Opening)))).

gui_open_definition(Form, Human, Actor, question_ref(ActorNs, ActorAnchor, question(Id)),
                    form_view(Revision, Tree, ValuesToken, Values, Control)) :-
    term_variables([Form, Human, Actor], []),
    current_principal(Caller), (Caller = Human; Caller = Actor),
    gui_question_policy(Form, Human, Actor),
    current_ontology_identity(Ns, Anchor), current_request_operation(Operation),
    Actor = agent_instance_ref(ActorNs, ActorAnchor, _),
    term_digest(gui_question(Operation, form_ref(Ns, Anchor, Form), Human, Actor), Id),
    gui_definition(Form, Revision, Tree, Fields, submit(Control, _)),
    gui_initial_values(Fields, Form, Tree, Values), term_digest(Values, ValuesToken).
