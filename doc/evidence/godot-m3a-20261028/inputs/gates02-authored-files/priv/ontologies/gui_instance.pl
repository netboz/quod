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
        in_ontology(Ns,Anchor,
             gui_answer(Q, form_ref(SourceNs, SourceAnchor, Form), Human, Revision, Control, Fields)),
        gui_question_policy(Form, Human, Actor),
        gui_bind(Form, Revision, Control, Fields, Continuation),
        Reference = question_ref(Ns, Anchor, Q),
        \+ gui_application_active(Reference),
        assertz(gui_application_active(Reference)),
        call(Continuation),
        in_ontology(Ns,Anchor, gui_consume(Q)),
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
        in_ontology(ActorNs,ActorAnchor,
                  gui_responder_for(Instance, Source, Human, Hosting)),
        Human = agent_instance_ref(HumanNs, HumanAnchor, HumanInstance),
        in_ontology(HumanNs,HumanAnchor,
                  gui_receiver_accept(HumanInstance, Receiver, Capacity)),
        gui_vocabulary(GuiNs, GuiAnchor),
        Opening = gui_opening(ontology_ref(GuiNs, GuiAnchor), Reference, Source, Human, Actor,
                              View, Receiver, Hosting, Capacity),
        in_ontology(GuiNs,GuiAnchor, gui_prepare_question(Opening)),
        in_ontology(ActorNs,ActorAnchor, gui_accept_question(Opening)))).

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

%% Offered operations compose the existing form compiler and class recipes.
%% No ACL, mutable state or executor is installed by this vocabulary.
ontology_interface(gui_operations/2, <<"explicit class or instance operations">>).
ontology_interface(gui_operation_bind/7, <<"bind typed inputs to an authored goal and named results">>).
ontology_interface(gui_operation/6, <<"call the bound operation and return only its named results">>).
ontology_interface(gui_operation_classes/1, <<"classes offering creation in this storage ontology">>).

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

%% Current question state, composed into the responsible actor's ontology.
%% Opening verifies the GUI scope's staged presentation and atomically creates
%% the question and human HUD reference through the existing transaction owner.
%% gui_question(Id, form_ref(Ns, Anchor, Form), Human, Actor, Revision, State).

no_follow(gui_submit/4).
no_follow(gui_complete/1).
no_follow(gui_consume/1).
no_follow(gui_cancel/1).
no_follow(gui_answer/6).
no_follow(gui_question_view/4).
no_follow(gui_question_form/2).
no_follow(gui_retirement/2).
no_follow(gui_question_entry/3).
no_follow(gui_consumption_entry/4).
no_follow(gui_question/6).
no_follow(gui_question_reference/2).
no_follow(gui_question_actor/2).
no_follow(gui_remove_hud/2).
no_follow(gui_retiring/2).
no_follow(gui_completion_request/4).
no_follow(gui_completion_allowance/2).
no_follow(gui_completion_signing/3).
no_follow(gui_visible_state/2).
no_follow(gui_cancelable/1).
no_follow(gui_question_status/2).

instance_of(quod:gui:question, Q) :- gui_question(Q, _, _, _, _, _).

%% Entry grants use committed local state. They never query another ontology
%% or consult a process while a validator checks authorization.
can_invoke(Goal, Principal, _, Ns) :- gui_question_entry(Goal, Principal, Ns).
can_invoke(Goal, Principal, Chain, Ns) :- gui_consumption_entry(Goal, Principal, Chain, Ns).
gui_consumption_entry((current_ontology_identity(_, _), Goal), Principal, Chain, Ns) :-
    gui_consumption_entry(Goal, Principal, Chain, Ns).
gui_consumption_entry(gui_consume(Q), agent_instance_ref(Ns, _, Actor), [SourceNs|_], Ns) :-
    SourceNs \= Ns,
    gui_question(Q, form_ref(SourceNs, _, _), _, Actor, _, submitted(_, _, _, _)).
gui_question_entry((current_ontology_identity(_, _), Goal), Principal, Ns) :-
    gui_question_entry(Goal, Principal, Ns).
gui_question_entry(gui_submit(Q, _, _, _), Human, _) :-
    gui_question(Q, _, Human, _, _, awaiting).
gui_question_entry(gui_cancel(Q), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
gui_question_entry(gui_question_status(Q, _), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
gui_question_entry(gui_question_view(Q, _, _, _), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
gui_question_entry(gui_question_form(Q, _), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
%% The existing hosted-agent owner asks to sign its retained completion via
%% this exact read. GUI composition supplies the narrow grant automatically.
gui_question_entry((agent_hosted(Actor, Node, Epoch, Key), sign_agent_request(Typed, _)), Node, Ns) :-
    Typed = agent_goal_v1(_, agent_instance_ref(Ns, _, Actor), _, Key, _, _, execute, 3, _),
    agent_hosted(Actor, Node, Epoch, Key),
    gui_completion_signing(Node, Actor, Typed).
gui_question_entry(gui_complete(Q), agent_instance_ref(Ns, _, Actor), Ns) :-
    gui_question(Q, _, _, Actor, _, submitted(_, _, _, _)).
gui_question_entry(gui_answer(Q, _, _, _, _, _), agent_instance_ref(Ns, _, Actor), Ns) :-
    gui_question(Q, _, _, Actor, _, submitted(_, _, _, _)).
gui_question_entry(gui_retirement(Q, Human), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
gui_question_entry(gui_retirement(Q, Human), agent_instance_ref(Ns, _, Actor), Ns) :-
    gui_question(Q, _, Human, Actor, _, submitted(_, _, _, _)).

gui_question_reference(Q, question_ref(Ns, Anchor, Q)) :-
    current_ontology_identity(Ns, Anchor).

gui_question_actor(Actor, agent_instance_ref(Ns, Anchor, Actor)) :-
    current_ontology_identity(Ns, Anchor).

%% A HUD reads the authoritative row under its human's identity. The source
%% reference and revision let any client obtain the ordinary component view;
%% accepted fields are returned only to the human who supplied them.
gui_question_view(Q, Source, Revision, State) :-
    term_variables(Q, []), current_principal(Human),
    gui_question(Q, Source, Human, _, Revision, Stored),
    gui_visible_state(Stored, State).

%% Reading a selected form follows its exact source under the human's identity.
%% Keep the accepted revision separate from the current form revision so clients
%% cannot silently apply a draft to a changed schema.
gui_question_form(Q, question_form(Source, Responsible, Revision, State, View)) :-
    term_variables(Q, []), current_principal(Human),
    gui_question(Q, Source, Human, Actor, Revision, Stored),
    gui_visible_state(Stored, State),
    gui_question_actor(Actor, Responsible),
    Source = form_ref(Ns, Anchor, Form),
    in_ontology(Ns,Anchor,
         gui_form_projection(Form, Human, Responsible, View)).

%% The submitted operation is authenticated context, never a client sequence.
%% Invalid values and source-policy changes leave the entire row unchanged.
gui_submit(Q, Revision, Control, Fields) :-
    term_variables([Q, Revision, Control, Fields], []),
    transaction((
        current_principal(Human), current_request_operation(Submission),
        gui_question(Q, Source, Human, Actor, Revision, awaiting),
        Source = form_ref(Ns, Anchor, Form),
        gui_question_actor(Actor, Responsible),
        in_ontology(Ns,Anchor,
             gui_validate_submission(Form, Human, Responsible, Revision, Control, Fields)),
        gui_completion_request(Q, Submission, Actor, Bytes),
        retract(gui_question(Q, Source, Human, Actor, Revision, awaiting)),
        assertz(gui_question(Q, Source, Human, Actor, Revision,
                             submitted(Submission, Control, Fields, Bytes))))).

%% This read grants no continuation from an event payload. The originating
%% application retrieves the exact accepted fields under the actor's identity.
gui_answer(Q, Source, Human, Revision, Control, Fields) :-
    term_variables(Q, []),
    gui_question(Q, Source, Human, Actor, Revision, submitted(_, Control, Fields, _)),
    gui_question_actor(Actor, Responsible), current_principal(Responsible).

gui_complete(Q) :-
    term_variables(Q, []),
    transaction((
        gui_question(Q, form_ref(Ns, Anchor, _), _, Actor, _, submitted(_, _, _, Bytes)),
        current_signed_request(Bytes),
        gui_question_actor(Actor, Responsible), current_principal(Responsible),
        gui_question_reference(Q, Reference),
        in_ontology(Ns,Anchor, gui_continue(Reference)))).

gui_consume(Q) :-
    term_variables(Q, []),
    transaction((
        gui_question(Q, Source, Human, Actor, Revision, Submitted),
        Submitted = submitted(_, _, _, Bytes),
        current_signed_request(Bytes),
        gui_question_actor(Actor, Responsible), current_principal(Responsible),
        gui_question_reference(Q, Reference),
        Source = form_ref(SourceNs, SourceAnchor, _),
        in_ontology(SourceNs,SourceAnchor,
                   gui_application_active(Reference)),
        assertz(gui_retiring(Q, Human)),
        gui_remove_hud(Human, Reference),
        retract(gui_question(Q, Source, Human, Actor, Revision, Submitted)),
        retract(gui_retiring(Q, Human)))).

gui_cancel(Q) :-
    term_variables(Q, []),
    transaction((
        current_principal(Human),
        gui_question(Q, Source, Human, Actor, Revision, State),
        gui_cancelable(State),
        gui_question_reference(Q, Reference),
        assertz(gui_retiring(Q, Human)),
        gui_remove_hud(Human, Reference),
        retract(gui_question(Q, Source, Human, Actor, Revision, State)),
        retract(gui_retiring(Q, Human)))).

gui_remove_hud(agent_instance_ref(Ns, Anchor, Instance), Reference) :-
    in_ontology(Ns,Anchor, gui_unlink(Instance, Reference)).

gui_retirement(Q, Human) :-
    gui_retiring(Q, Human),
    current_principal(Principal),
    (gui_question(Q, _, Human, _, _, _), Principal = Human
    ; gui_question(Q, _, Human, Actor, _, submitted(_, _, _, _)),
      gui_question_actor(Actor, Principal)).

%% Completion allowance is authored once for the responsible actor. Ambiguous
%% keys or policy refuse submission before any question state is replaced.
gui_completion_request(Q, Submission, Actor, Bytes) :-
    findall(K, agent_key(Actor, K, active), [Key]),
    findall(Ms, gui_completion_allowance(Actor, Ms), [Allowance]),
    integer(Allowance), Allowance > 0,
    current_request_expiry(SubmissionExpiry), Expiry is SubmissionExpiry + Allowance,
    gui_question_reference(Q, Reference),
    term_digest(gui_completion(Reference, Submission), Operation),
    gui_question_actor(Actor, Responsible),
    <<"quod:root">>::(current_ontology_identity(<<"quod:root">>, Network),
                       acl_sovereign(quod:root)),
    '$quod_program_source'([Actor], InstanceText),
    '$quod_program_source'([gui_complete(Q)], GoalText),
    agent_request_bytes(agent_goal_v1(Network, Responsible, InstanceText, Key,
                                     Operation, Expiry, execute, 3, GoalText), Bytes).

%% Accept only the exact current retained bytes and the fixed completion
%% goal. A row cannot turn this into permission to sign arbitrary actor work.
can_request_agent_signature(Node, Actor, Typed) :- gui_completion_signing(Node, Actor, Typed).
gui_completion_signing(Node, Actor, Typed) :-
    term_variables(Typed, []),
    Typed = agent_goal_v1(_, agent_instance_ref(_, _, Actor), _, Key, _, _, execute, 3, GoalText),
    agent_hosted(Actor, Node, _, Key),
    agent_request_bytes(Typed, Bytes),
    gui_question(Q, _, _, Actor, _, submitted(_, _, _, Bytes)),
    '$quod_program_source'([Completion], GoalText),
    term_variables(Completion, []), Completion = gui_complete(Q).

%% Only a real committed local assertion schedules the retained request. The
%% existing event owner suppresses duplicate source delivery; replay is inert.
react_on(assert(gui_question(Q, Source, Human, Actor, Revision, Submitted)), gui_complete(Q)) :-
    gui_completion_event(Q, Source, Human, Actor, Revision, Submitted).
gui_completion_event(Q, Source, Human, Actor, Revision, Submitted) :-
    Submitted = submitted(_, _, _, Bytes),
    me(agent_instance_ref(_, _, Actor)),
    gui_question(Q, Source, Human, Actor, Revision, Submitted),
    use_agent_request(Bytes).

gui_visible_state(awaiting, awaiting).
gui_visible_state(submitted(Submission, Control, Fields, _), submitted(Submission, Control, Fields)).

gui_question_status(Q, Status) :-
    term_variables(Q, []), current_principal(Human),
    gui_question(Q, _, Human, _, _, State),
    (State = awaiting -> Status = awaiting
    ; State = submitted(_, _, _, Bytes), committed_operation_outcome(Bytes, Status)).

gui_cancelable(awaiting).
gui_cancelable(submitted(_, _, _, Bytes)) :-
    committed_operation_outcome(Bytes, Status), member(Status, [rejected, aborted, expired]).

%% A responder's authored allowance is question capacity, not an Erlang queue
%% reservation. Native feasibility separately checks its installed handler.
no_follow(gui_responder_for/4).
no_follow(gui_responder_principal/5).
no_follow(gui_opening_entry/4).
no_follow(gui_native_handler/5).
no_follow(gui_accept_question/1).
no_follow(gui_accepting/1).
no_follow(gui_completion_event/6).
can_invoke(Goal, Principal, Chain, Ns) :- gui_opening_entry(Goal, Principal, Chain, Ns).
gui_opening_entry((current_ontology_identity(_, _), Goal), Principal, Chain, Ns) :-
    gui_opening_entry(Goal, Principal, Chain, Ns).
gui_opening_entry(gui_responder_for(Instance, Source, Human, _), Principal, _, Ns) :-
    gui_responder_principal(Instance, Source, Human, Principal, Ns).
gui_opening_entry(gui_native_handler(Instance, Source, Human, _, _), Principal, _, Ns) :-
    gui_responder_principal(Instance, Source, Human, Principal, Ns).
gui_opening_entry(gui_accept_question(Opening), Principal, [SourceNs|_], Ns) :-
    Opening = gui_opening(_, _, Source, Human, agent_instance_ref(Ns, _, Instance), _, _, _, _),
    Source = form_ref(SourceNs, _, _),
    gui_responder_principal(Instance, Source, Human, Principal, Ns).
gui_opening_entry(gui_accepting(Opening), Principal, _, Ns) :-
    Opening = gui_opening(_, _, Source, Human, agent_instance_ref(Ns, _, Instance), _, _, _, _),
    gui_responder_principal(Instance, Source, Human, Principal, Ns).
gui_responder_principal(Instance, Source, Human, Principal, Ns) :-
    gui_responder_policy(Instance, Source, Human),
    (Principal = Human; Principal = agent_instance_ref(Ns, _, Instance)).

gui_responder_for(Instance, Source, Human, hosted(Node, Epoch, Key)) :-
    term_variables([Instance, Source, Human], []),
    current_ontology_identity(Ns, Anchor), current_principal(Principal),
    gui_responder_principal(Instance, Source, Human, Principal, Ns),
    (Principal = Human; Principal = agent_instance_ref(Ns, Anchor, Instance)),
    findall(hosted(N, E, K), agent_hosted(Instance, N, E, K), [hosted(Node, Epoch, Key)]),
    findall(Limit, gui_pending_allowance(Instance, Limit), [Capacity]),
    integer(Capacity), Capacity > 0,
    findall(Q, gui_question(Q, _, _, Instance, _, _), Pending), length(Pending, Count), Count < Capacity,
    findall(Ms, gui_completion_allowance(Instance, Ms), [Allowance]), integer(Allowance), Allowance > 0.

gui_native_handler(Instance, Source, Human, hosted(Node, Epoch, Key), Token) :-
    gui_responder_for(Instance, Source, Human, hosted(Node, Epoch, Key)),
    Head = react_on(assert(gui_question(Q, S, H, A, R, Submitted)), gui_complete(Q)),
    Body = gui_completion_event(Q, S, H, A, R, Submitted),
    clause(Head, Body), installed_agent_reaction(Instance, Epoch, Key, (Head :- Body), Token).

gui_accept_question(Opening) :-
    term_variables(Opening, []),
    Opening = gui_opening(ontology_ref(GuiNs, GuiAnchor), question_ref(Ns, Anchor, Q), Source,
        Human, agent_instance_ref(Ns, Anchor, Actor), form_view(Revision, _, _, _, _), _, Hosting, _),
    current_ontology_identity(Ns, Anchor),
    transaction((
        gui_responder_for(Actor, Source, Human, Hosting),
        in_ontology(GuiNs,GuiAnchor, gui_prepared(Opening)),
        \+ gui_question(Q, _, _, _, _, _),
        assertz(gui_question(Q, Source, Human, Actor, Revision, awaiting)),
        Human = agent_instance_ref(HumanNs, HumanAnchor, _),
        in_ontology(HumanNs,HumanAnchor, gui_link_question(Opening)))).

gui_accepting(Opening) :-
    term_variables(Opening, []),
    Opening = gui_opening(ontology_ref(GuiNs, GuiAnchor), question_ref(Ns, Anchor, Q), Source,
        Human, agent_instance_ref(Ns, Anchor, Actor), form_view(Revision, _, _, _, _), _, _, _),
    current_ontology_identity(Ns, Anchor),
    gui_question(Q, Source, Human, Actor, Revision, awaiting),
    in_ontology(GuiNs,GuiAnchor, gui_prepared(Opening)).
