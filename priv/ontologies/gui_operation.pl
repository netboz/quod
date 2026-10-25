%% Offered operations compose the existing form compiler and class recipes.
%% No ACL, mutable state or executor is installed by this vocabulary.
ontology_interface(gui_operations/2, <<"explicit class or instance operations">>).
ontology_interface(gui_operation_bind/7, <<"bind typed inputs to an authored goal and named results">>).

no_follow(gui_operations/2).
no_follow(gui_operation_view/3).
no_follow(gui_operation_definition/8).
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
    gui_operation_subject(Subject, Local, Classes, Mode),
    class_eidolons(Classes, operation(Mode), Name,
                   [eidolon(operation(Mode), Name, recipe(Ns, Anchor, Recipe))]),
    current_ontology_identity(Here, History), Target = ontology_ref(Here, History),
    findall(F, Ns::(current_ontology_identity(Ns, Anchor),
                    eidolon(Recipe, subject(Target, Local), operation(F))), [Form]),
    gui_definition(Form, Schema, Tree, Fields, Submit, operation(Permission, Results)),
    variant_digest(offered_operation(Subject, Name, recipe(Ns, Anchor, Recipe),
                                     Form, Schema), Revision).

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
