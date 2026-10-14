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
    term_variables(Form, []),
    findall(ontology_ref(N, A), gui_vocabulary(N, A), [ontology_ref(Ns, Anchor)]),
    Ns::current_ontology_identity(Ns, Anchor),
    findall(binding(F, S), gui_form(Form, F, S), [binding(Fields, Submit)]),
    gui_component_tree(Form, ontology_ref(Ns, Anchor), [], _, Tree),
    Tree = component(Form, form, _, _),
    Submit = submit(Control, Continuation),
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

gui_component_tree(Id, Vocabulary, Seen, All, component(Id, Kind, Properties, Children)) :-
    term_variables(Id, []), \+ member_eq(Id, Seen),
    Vocabulary = ontology_ref(Ns, Anchor),
    findall(attribute(Key, Value), attribute(Id, Key, Value), Attributes),
    findall(Local, (instance_of(Class, Id),
                    gui_class_basis(Class, Parent),
                    '$quod_owner_name'(Parent, Owner, Local),
                    ontology_name(Owner, Ns)), Raw),
    sort(Raw, Classes),
    Ns::(current_ontology_identity(Ns, Anchor),
         gui_component_schema(Classes, Attributes, Kind, Properties)),
    findall(C, gui_children(Id, C), ChildDeclarations),
    (ChildDeclarations = [] -> ChildIds = []
    ; ChildDeclarations = [ChildIds]),
    term_variables(ChildIds, []),
    (member(Kind, [form, container]) -> true; ChildIds = []),
    gui_component_children(ChildIds, Vocabulary, [Id | Seen], All, Children).

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

gui_field_declarations([], _, Ids, Ids).
gui_field_declarations([field(Id, _) | Rest], Tree, Seen, Ids) :-
    term_variables(Id, []), \+ member_eq(Id, Seen),
    gui_tree_component(Tree, Id, Kind, _, []),
    member(Kind, [text_box, selection, slider, rotary_knob]),
    gui_field_declarations(Rest, Tree, [Id | Seen], Ids).

gui_variables_bound([], _).
gui_variables_bound([Variable | Rest], Variables) :-
    member_eq(Variable, Variables), gui_variables_bound(Rest, Variables).

%% Initial values are a separate projection. Reading them never instantiates
%% the form's submitted variables and never changes its semantic revision.
gui_values(Form, ValuesToken, Values) :-
    gui_definition(Form, _, Tree, Fields, _),
    gui_initial_values(Fields, Form, Tree, Values),
    term_digest(Values, ValuesToken).

gui_initial_values([], _, _, []).
gui_initial_values([field(Id, _) | Rest], Form, Tree, [field(Id, Value) | Values]) :-
    gui_initial_field(Form, Tree, Id, Value),
    gui_initial_values(Rest, Form, Tree, Values).

gui_initial_field(Form, Tree, Id, Value) :-
    gui_tree_component(Tree, Id, Kind, Properties, []),
    gui_vocabulary(Ns, Anchor),
    findall(V, gui_initial(Form, Id, V), Values),
    (Values = [Value] -> true
    ; Values = [], Ns::(current_ontology_identity(Ns, Anchor),
                        gui_default_value(Kind, Properties, Value))),
    term_variables(Value, []),
    Ns::(current_ontology_identity(Ns, Anchor), gui_initial_value(Kind, Properties, Value)).

%% Values frozen by readonly/disabled controls are validation inputs, so they
%% participate in the revision. Ordinary editable defaults remain separate.
gui_fixed_values([], _, _, []).
gui_fixed_values([field(Id, _) | Rest], Form, Tree, Fixed) :-
    gui_tree_component(Tree, Id, _, Properties, []),
    ((member(property(readonly, true), Properties); \+ gui_tree_active(Tree, Id)) ->
        gui_initial_field(Form, Tree, Id, Value), Fixed = [field(Id, Value) | Tail]
    ; Fixed = Tail),
    gui_fixed_values(Rest, Form, Tree, Tail).

%% Construct only the authored continuation. This pure helper is called by
%% question submission/completion; it does not execute a client-supplied goal.
gui_bind(Form, Revision, Control, Values, Continuation) :-
    term_variables(Form-Revision-Control-Values, []),
    gui_definition(Form, Revision, Tree, Fields, submit(Control, Continuation)),
    gui_tree_active(Tree, Control),
    gui_bind_fields(Fields, Values, Form, Tree),
    term_variables(Continuation, []).

gui_bind_fields([], [], _, _).
gui_bind_fields([field(Id, Value) | Rest], Values, Form, Tree) :-
    delete(Values, field(Id, Value), Remaining),
    gui_tree_component(Tree, Id, Kind, Properties, []),
    gui_vocabulary(Ns, Anchor),
    Ns::(current_ontology_identity(Ns, Anchor), gui_value(Kind, Properties, Value)),
    ((member(property(readonly, true), Properties); \+ gui_tree_active(Tree, Id)) ->
        gui_initial_field(Form, Tree, Id, Value)
    ; true),
    gui_bind_fields(Rest, Remaining, Form, Tree).

gui_tree_active(component(Node, _, Properties, Children), Id) :-
    member(property(enabled, true), Properties),
    (Node == Id -> true; member(Child, Children), gui_tree_active(Child, Id)).
