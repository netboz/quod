%% Descriptor and binding helpers interpret data locally. A colon in an
%% input value is never a request to follow that value into another ontology.
no_follow(gui_component_schema/4).
no_follow(gui_tree_schema/2).
no_follow(gui_children_schema/2).
no_follow(gui_initial_projection/3).
no_follow(gui_valid_values/1).
no_follow(gui_properties/3).
no_follow(gui_property/3).
no_follow(gui_attribute/4).
no_follow(gui_property_value/2).
no_follow(gui_value/3).
no_follow(gui_initial_value/3).
no_follow(gui_default_value/3).
no_follow(gui_options/2).
no_follow(gui_text/1).
no_follow(gui_boolean/1).
no_follow(gui_workspace/3).
no_follow(gui_workspace_fields/2).

%% Shared semantic GUI vocabulary. A proof workspace is the first composite
%% form; its adapter reuses the existing cursor controls, never another executor.
acl_sovereign(quod:gui).
can_invoke(Goal, _, _, _) :- gui_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- gui_query(Goal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

gui_query(gui_view(_, _)).
gui_query(isa(_, _)).
gui_query(gui_component_schema(_, _, _, _)).
gui_query(gui_tree_schema(_, _)).
gui_query(gui_initial_projection(_, _, _)).
gui_query(gui_valid_values(_)).
gui_query(gui_value(_, _, _)).
gui_query(gui_initial_value(_, _, _)).
gui_query(gui_default_value(_, _, _)).
gui_query(Goal) :- public_source_query(Goal).

isa(gui_component, thing).
isa(question, thing).
isa(container, gui_component).
isa(form, container).
isa(editor, gui_component).
isa(catalogue_selection, gui_component).
isa(input, gui_component).
isa(text_box, input).
isa(selection, input).
isa(slider, input).
isa(rotary_knob, input).
isa(bindings, gui_component).
isa(button, gui_component).
isa(proof_workspace, form).
isa(code_workspace, form).

%% Portable component contracts. Application instances supply attributes;
%% this ontology owns their kinds, inherited defaults and input constraints.
%% A schema contains semantic values only, never an application continuation.
%% Attribute reflection and executable defaults share this declaration.
%% Other domain attributes on a component remain the application's property.
have_attribute(Class, Key, Type) :- gui_attribute(Class, Key, Type, _).

gui_attribute(gui_component, label, binary, required).
gui_attribute(gui_component, help, binary, default(<<"">>)).
gui_attribute(gui_component, enabled, boolean, default(true)).
gui_attribute(input, required, boolean, default(false)).
gui_attribute(input, readonly, boolean, default(false)).
gui_attribute(Kind, readonly, boolean, default(false)) :- member(Kind, [editor, catalogue_selection]).
gui_attribute(text_box, max_bytes, nonnegative_integer, default(4096)).
gui_attribute(selection, options, labelled_values, required).
gui_attribute(container, layout, layout, default(column)).
gui_attribute(Kind, range, integer_range, required) :- member(Kind, [slider, rotary_knob]).
gui_attribute(Kind, unit, text_or_atom, default(<<"">>)) :- member(Kind, [slider, rotary_knob]).

gui_kind(form).
gui_kind(container).
gui_kind(text_box).
gui_kind(selection).
gui_kind(slider).
gui_kind(rotary_knob).
gui_kind(button).
%% Existing proof/source controller capabilities are presentation components;
%% they are not submitted fields in the common question binding API.
gui_kind(editor).
gui_kind(bindings).
gui_kind(catalogue_selection).

gui_component_schema(Classes, Attributes, Kind, Properties) :-
    term_variables(Classes-Attributes, []),
    findall(K, gui_kind(K), Kinds),
    most_specific_classes(Classes, Kinds, [Kind]),
    findall(property(Key, Default), gui_property(Kind, Key, Default), Contract),
    gui_properties(Contract, Attributes, Properties).

%% One projection visits the vocabulary once for the whole form. These are
%% submitted class/attribute values, never another ontology's clauses or KB.
gui_tree_schema(component(Id, Classes, Attributes, RawChildren),
                component(Id, Kind, Properties, Children)) :-
    gui_component_schema(Classes, Attributes, Kind, Properties),
    (member(Kind, [form, container]) -> true; RawChildren = []),
    gui_children_schema(RawChildren, Children).

gui_children_schema([], []).
gui_children_schema([Raw | Rest], [Child | Children]) :-
    gui_tree_schema(Raw, Child), gui_children_schema(Rest, Children).

gui_initial_projection(_, [], []).
gui_initial_projection(Mode, [initial(Id, Kind, Properties, Declared) | Rest],
                       [field(Id, Value) | Values]) :-
    (Declared = [Value] -> true
    ; Declared = [], gui_default_value(Kind, Properties, Value)),
    term_variables(Value, []),
    (Mode = editing -> gui_initial_value(Kind, Properties, Value)
    ; Mode = frozen, gui_value(Kind, Properties, Value)),
    gui_initial_projection(Mode, Rest, Values).

gui_valid_values([]).
gui_valid_values([value(Kind, Properties, Value) | Rest]) :-
    gui_value(Kind, Properties, Value), gui_valid_values(Rest).

gui_property(Kind, Key, Default) :-
    gui_attribute(Class, Key, _, Default), once(isa(Kind, Class)).

gui_properties([], _, []).
gui_properties([property(Key, Default) | Contract], Attributes, [property(Key, Value) | Properties]) :-
    findall(V, member(attribute(Key, V), Attributes), Values),
    (Values = [Value] -> true
    ; Values = [], Default = default(Value)),
    gui_property_value(Key, Value),
    gui_properties(Contract, Attributes, Properties).

gui_property_value(label, Text) :- gui_text(Text), Text \= <<"">>.
gui_property_value(help, Text) :- gui_text(Text).
gui_property_value(unit, Text) :- (atom(Text) -> true; gui_text(Text)).
gui_property_value(enabled, Value) :- gui_boolean(Value).
gui_property_value(required, Value) :- gui_boolean(Value).
gui_property_value(readonly, Value) :- gui_boolean(Value).
gui_property_value(layout, Value) :- member(Value, [column, row]).
gui_property_value(max_bytes, Value) :- integer(Value), Value >= 0.
gui_property_value(range, range(Min, Max, Step)) :-
    integer(Min), integer(Max), integer(Step), Min =< Max, Step > 0.
gui_property_value(options, Options) :-
    Options = [_ | _], gui_options(Options, []).

gui_boolean(true).
gui_boolean(false).
gui_text(Text) :- binary(Text).

gui_options([], _).
gui_options([option(Id, Label) | Rest], Seen) :-
    term_variables(Id, []), \+ member_eq(Id, Seen),
    gui_property_value(label, Label),
    gui_options(Rest, [Id | Seen]).

%% Field constraints are enforced again at the signed submission, regardless
%% of which client rendered the descriptor. Numeric values use integer units.
gui_value(text_box, Properties, Value) :-
    binary(Value), binary_codes(Value, Bytes), length(Bytes, Length),
    member(property(max_bytes, Max), Properties), Length =< Max,
    (member(property(required, true), Properties) -> Length > 0; true).
gui_value(selection, Properties, Value) :-
    member(property(options, Options), Properties), member(option(Value, _), Options).
gui_value(Kind, Properties, Value) :-
    member(Kind, [slider, rotary_knob]), integer(Value),
    member(property(range, range(Min, Max, Step)), Properties),
    Value >= Min, Value =< Max, 0 =:= (Value - Min) mod Step.

%% A required text field may start empty while the human is editing it.
gui_initial_value(Kind, Properties, Value) :-
    delete(Properties, property(required, _), Rest),
    gui_value(Kind, [property(required, false) | Rest], Value).

gui_default_value(text_box, _, <<"">>).
gui_default_value(selection, Properties, Value) :-
    member(property(options, [option(Value, _) | _]), Properties).
gui_default_value(Kind, Properties, Min) :-
    member(Kind, [slider, rotary_knob]), member(property(range, range(Min, _, _)), Properties).

%% Stable component roles bind local input and cursor results. Descriptors are
%% ground values, not suspended Prolog variables awaiting keyboard events.
gui_view(proof_console, View) :-
    gui_workspace(<<"Prolog console">>,
         [editor(goal, <<"Prolog goal">>), bindings(results, <<"Bindings">>),
          button(run, <<"Run">>), button(next, <<"Next solution">>),
          button(accept, <<"Accept solution">>), button(stop, <<"Stop">>), button(resolve, <<"Check saved outcome">>)], View).

gui_view(prolog_editor, View) :-
    gui_workspace(<<"Prolog code">>,
         [catalogue_selection(predicate, <<"Source lens">>), text_box(new_predicate, <<"New predicate (name/arity)">>),
          editor(source, <<"Source code">>),
          bindings(results, <<"Edit result">>), button(run, <<"Preview changes">>),
          button(accept, <<"Save changes">>), button(stop, <<"Cancel preview">>), button(create, <<"Add predicate">>),
          button(resolve, <<"Check saved outcome">>)], View).

gui_view(prolog_source, View) :-
    gui_workspace(<<"Prolog source (read only)">>,
         [catalogue_selection(predicate, <<"Source lens">>),
          editor(source, <<"Source code">>)], View).

%% Built-in proof/source workspaces retain their existing controllers. They
%% share the ordinary component descriptor; selections receive their live
%% catalogues from the corresponding source lens, not a second GUI engine.
gui_workspace(Title, Fields, Tree) :-
    gui_workspace_fields(Fields, Children),
    gui_tree_schema(component(workspace, [form], [attribute(label, Title)], Children), Tree).
gui_workspace_fields([], []).
gui_workspace_fields([Field | Rest], [component(Id, [Kind], [attribute(label, Label)], []) | Children]) :-
    Field =.. [Kind, Id, Label], gui_workspace_fields(Rest, Children).
