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
gui_query(gui_value(_, _, _)).
gui_query(gui_initial_value(_, _, _)).
gui_query(gui_default_value(_, _, _)).
gui_query(Goal) :- public_source_query(Goal).

isa(gui_component, thing).
isa(container, gui_component).
isa(form, container).
isa(editor, gui_component).
isa(input, gui_component).
isa(text_box, input).
isa(selection, input).
isa(slider, input).
isa(rotary_knob, input).
isa(choice, gui_component).
isa(bindings, gui_component).
isa(button, gui_component).
isa(proof_workspace, form).
isa(code_workspace, form).

%% Portable component contracts. Application instances supply attributes;
%% this ontology owns their kinds, inherited defaults and input constraints.
%% A schema contains semantic values only, never an application continuation.
have_attribute(gui_component, label, binary).
have_attribute(gui_component, help, binary).
have_attribute(gui_component, enabled, boolean).
have_attribute(input, required, boolean).
have_attribute(input, readonly, boolean).
have_attribute(text_box, max_bytes, nonnegative_integer).
have_attribute(slider, range, integer_range).
have_attribute(rotary_knob, range, integer_range).
have_attribute(selection, options, labelled_values).

gui_kind(form).
gui_kind(container).
gui_kind(text_box).
gui_kind(selection).
gui_kind(slider).
gui_kind(rotary_knob).
gui_kind(button).

gui_component_schema(Classes, Attributes, Kind, Properties) :-
    term_variables(Classes-Attributes, []),
    findall(K, gui_kind(K), Kinds),
    most_specific_classes(Classes, Kinds, [Kind]),
    findall(property(Key, Default), gui_property(Kind, Key, Default), Contract),
    gui_properties(Contract, Attributes, Properties).

gui_property(_, label, required).
gui_property(_, help, default(<<"">>)).
gui_property(_, enabled, default(true)).
gui_property(Kind, required, default(false)) :- isa(Kind, input).
gui_property(Kind, readonly, default(false)) :- isa(Kind, input).
gui_property(Kind, range, required) :- member(Kind, [slider, rotary_knob]).
gui_property(Kind, unit, default(<<"">>)) :- member(Kind, [slider, rotary_knob]).
gui_property(selection, options, required).
gui_property(text_box, max_bytes, default(4096)).
gui_property(Kind, layout, default(column)) :- isa(Kind, container).

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
gui_text(Text) :- binary_codes(Text, _).

gui_options([], _).
gui_options([option(Id, Label) | Rest], Seen) :-
    term_variables(Id, []), \+ member_eq(Id, Seen),
    gui_property_value(label, Label),
    gui_options(Rest, [Id | Seen]).

%% Field constraints are enforced again at the signed submission, regardless
%% of which client rendered the descriptor. Numeric values use integer units.
gui_value(text_box, Properties, Value) :-
    binary_codes(Value, Bytes), length(Bytes, Length),
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
gui_view(proof_console,
    form(<<"Prolog console">>,
         [editor(goal, <<"Prolog goal">>), bindings(results, <<"Bindings">>),
          button(run, <<"Run">>), button(next, <<"Next solution">>),
          button(accept, <<"Accept solution">>), button(stop, <<"Stop">>), button(resolve, <<"Check saved outcome">>)])).

gui_view(prolog_editor,
    form(<<"Prolog code">>,
         [choice(predicate, <<"Source lens">>), input(new_predicate, <<"New predicate (name/arity)">>),
          editor(source, <<"Source code">>),
          bindings(results, <<"Edit result">>), button(run, <<"Preview changes">>),
          button(accept, <<"Save changes">>), button(stop, <<"Cancel preview">>), button(create, <<"Add predicate">>),
          button(resolve, <<"Check saved outcome">>)])).

gui_view(prolog_source,
    form(<<"Prolog source (read only)">>,
         [choice(predicate, <<"Source lens">>),
          editor(source, <<"Source code">>)])).
