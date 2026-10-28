%% Descriptor and binding helpers interpret data locally. A colon in an
%% input value is never a request to follow that value into another ontology.
no_follow(gui_component_schema/4).
no_follow(gui_tree_schema/3).
no_follow(gui_children_schema/3).
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
gui_query(gui_tree_schema(_, _, _)).
gui_query(gui_initial_projection(_, _, _)).
gui_query(gui_valid_values(_)).
gui_query(gui_value(_, _, _)).
gui_query(gui_initial_value(_, _, _)).
gui_query(gui_default_value(_, _, _)).
gui_query(instance_of(_, _)).
gui_query(have_attribute(_, _, _)).
gui_query(attribute(_, _, _)).
gui_query(eidolon(_, _, _)).
gui_query(class_eidolon(_, _, _, _)).
gui_query(Goal) :- public_source_query(Goal).

isa(gui_component, thing).
isa(question, thing).
isa(eidolon, thing).
isa(container, gui_component).
isa(form, container).
isa(panel, container).
isa(group, container).
isa(row, container).
isa(column, container).
isa(grid, container).
isa(scroll, container).
isa(tabs, container).
isa(menu, container).
isa(dialog, container).
isa(image, gui_component).
isa(icon, image).
isa(label, gui_component).
isa(separator, gui_component).
isa(progress, gui_component).
isa(status, label).
isa(help, label).
isa(error, label).

isa(editor, gui_component).
isa(catalogue_selection, gui_component).
isa(input, gui_component).
isa(text_box, input).
isa(text_area, text_box).
isa(boolean_input, input).
isa(checkbox, boolean_input).
isa(toggle, boolean_input).
isa(numeric_input, input).
isa(number_input, numeric_input).
isa(selection, input).
isa(radio_group, selection).
isa(selectable_list, selection).
isa(table, selectable_list).
isa(slider, numeric_input).
isa(rotary_knob, numeric_input).
isa(bindings, gui_component).
isa(button, gui_component).
isa(icon_button, button).
isa(proof_workspace, form).
isa(code_workspace, form).

%% Portable component contracts. Application instances supply attributes;
%% this ontology owns their kinds, inherited defaults and input constraints.
%% A schema contains semantic values only, never an application continuation.
%% Attribute reflection and executable defaults share this declaration.
%% Other domain attributes on a component remain the application's property.
have_attribute(Class, Key, Type) :- gui_attribute(Class, Key, Type, _).
have_attribute(Class, Key, Type, Default) :- gui_attribute(Class, Key, Type, Default).

gui_attribute(gui_component, label, nonempty_binary, required).
gui_attribute(gui_component, help, binary, default(<<"">>)).
gui_attribute(gui_component, enabled, boolean, default(true)).
gui_attribute(input, required, boolean, default(false)).
gui_attribute(input, readonly, boolean, default(false)).
gui_attribute(Kind, readonly, boolean, default(false)) :- member(Kind, [editor, catalogue_selection]).
gui_attribute(text_box, max_bytes, nonnegative_integer, default(4096)).
gui_attribute(selection, options, labelled_values, required).
gui_attribute(selectable_list, multiple, boolean, default(false)).
gui_attribute(table, headings, text_list, required).
gui_attribute(image, image, image_asset, required).
gui_attribute(button, image, optional_image_asset, default(none)).
gui_attribute(container, layout, layout, default(column)).
gui_attribute(row, layout, layout, default(row)).
gui_attribute(grid, layout, layout, default(grid)).
gui_attribute(grid, columns, positive_integer, default(2)).
gui_attribute(scroll, visible_rows, positive_integer, default(6)).
gui_attribute(progress, percent, percentage, required).
gui_attribute(numeric_input, range, integer_range, required).
gui_attribute(numeric_input, unit, text_or_atom, default(<<"">>)).

gui_kind(form).
gui_kind(container).
gui_kind(panel).
gui_kind(group).
gui_kind(row).
gui_kind(column).
gui_kind(grid).
gui_kind(scroll).
gui_kind(tabs).
gui_kind(menu).
gui_kind(dialog).
gui_kind(image).
gui_kind(label).
gui_kind(status).
gui_kind(help).
gui_kind(error).
gui_kind(separator).
gui_kind(progress).

gui_kind(text_box).
gui_kind(text_area).
gui_kind(number_input).
gui_kind(checkbox).
gui_kind(toggle).
gui_kind(radio_group).
gui_kind(selectable_list).
gui_kind(table).
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
    gui_properties(Contract, Attributes, Properties),
    gui_kind_properties(Kind, Properties).

no_follow(gui_kind_properties/2).
gui_kind_properties(image, Properties) :- !, member(property(image, asset(_, _)), Properties).
gui_kind_properties(table, Properties) :- !,
    member(property(headings, Headings), Properties),
    member(property(options, Options), Properties),
    length(Headings, Count),
    \+ (member(option(_, Cells), Options),
        \+ (gui_texts(Cells), length(Cells, Count))).
gui_kind_properties(Kind, Properties) :-
    (once(isa(Kind, selection)) ->
        member(property(options, Options), Properties),
        \+ (member(option(_, Label), Options), \+ gui_text(Label))
    ; true).

%% One projection visits the vocabulary once for the whole form. These are
%% submitted class/attribute values, never another ontology's clauses or KB.
gui_tree_schema(component(Id, Classes, Attributes, RawChildren),
                component(Id, Kind, Properties, Children), Inputs) :-
    gui_component_schema(Classes, Attributes, Kind, Properties),
    (once(isa(Kind, container)) -> true; RawChildren = []),
    gui_children_schema(RawChildren, Children, DescendantInputs),
    (once(isa(Kind, input)) -> Inputs = [Id | DescendantInputs]; Inputs = DescendantInputs).

gui_children_schema([], [], []).
gui_children_schema([Raw | Rest], [Child | Children], Inputs) :-
    gui_tree_schema(Raw, Child, ChildInputs),
    gui_children_schema(Rest, Children, RestInputs),
    append(ChildInputs, RestInputs, Inputs).

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
    gui_attribute(Class, Key, _, Default), once(isa(Kind, Class)),
    findall(Owner, gui_attribute(Owner, Key, _, _), Owners),
    most_specific_classes([Kind], Owners, [Class]).

gui_properties([], _, []).
gui_properties([property(Key, Default) | Contract], Attributes, [property(Key, Value) | Properties]) :-
    findall(V, member(attribute(Key, V), Attributes), Values),
    (Values = [Value] -> true
    ; Values = [], Default = default(Value)),
    gui_property_value(Key, Value),
    gui_properties(Contract, Attributes, Properties).

gui_property_value(Key, Value) :-
    once((gui_attribute(_, Key, Type, _), attribute_value(Type, Value))).

%% The same declared types validate constructor inputs and GUI projections.
no_follow(text_or_atom/1).
no_follow(layout/1).
no_follow(percentage/1).
no_follow(integer_range/1).
no_follow(labelled_values/1).
no_follow(text_list/1).
no_follow(optional_image_asset/1).
no_follow(image_asset/1).
text_or_atom(Text) :- (atom(Text) -> true; gui_text(Text)).
layout(Value) :- member(Value, [column, row, grid]).
percentage(Value) :- integer(Value), Value >= 0, Value =< 100.
integer_range(range(Min, Max, Step)) :-
    integer(Min), integer(Max), integer(Step), Min =< Max, Step > 0.
labelled_values(Options) :- Options = [_ | _], gui_options(Options, []).
text_list(Headings) :- Headings = [_ | _], gui_texts(Headings).
optional_image_asset(none).
optional_image_asset(Value) :- image_asset(Value).
image_asset(asset(Digest, <<"image/jpeg">>)) :-
    binary(Digest), binary_codes(Digest, Bytes), length(Bytes, 64), gui_digest(Bytes).

no_follow(gui_texts/1).
gui_texts([]).
gui_texts([Text | Rest]) :- gui_property_value(label, Text), gui_texts(Rest).
no_follow(gui_digest/1).
gui_digest([]).
gui_digest([C | Rest]) :-
    (C >= 48, C =< 57 -> true; C >= 97, C =< 102), gui_digest(Rest).

gui_text(Text) :- binary(Text).

gui_options([], _).
gui_options([option(Id, Label) | Rest], Seen) :-
    term_variables(Id, []), \+ member_eq(Id, Seen),
    (gui_property_value(label, Label) -> true; Label = [_ | _], gui_texts(Label)),
    gui_options(Rest, [Id | Seen]).

%% Field constraints are enforced again at the signed submission, regardless
%% of which client rendered the descriptor. Numeric values use integer units.
gui_value(Kind, Properties, Value) :-
    once(isa(Kind, text_box)),
    binary(Value), binary_codes(Value, Bytes), length(Bytes, Length),
    member(property(max_bytes, Max), Properties), Length =< Max,
    (member(property(required, true), Properties) -> Length > 0; true).
gui_value(Kind, Properties, Value) :-
    once(isa(Kind, selection)), member(property(options, Options), Properties),
    (member(property(multiple, true), Properties) ->
        gui_selected_values(Value, Options, []),
        (member(property(required, true), Properties) -> Value = [_ | _]; true)
    ; member(option(Value, _), Options)).
gui_value(Kind, Properties, Value) :-
    once(isa(Kind, boolean_input)), boolean(Value),
    (member(property(required, true), Properties) -> Value = true; true).

no_follow(gui_selected_values/3).
gui_selected_values([], _, _).
gui_selected_values([Value | Rest], Options, Seen) :-
    member(option(Value, _), Options), \+ member_eq(Value, Seen),
    gui_selected_values(Rest, Options, [Value | Seen]).
gui_value(Kind, Properties, Value) :-
    once(isa(Kind, numeric_input)), integer(Value),
    member(property(range, range(Min, Max, Step)), Properties),
    Value >= Min, Value =< Max, 0 =:= (Value - Min) mod Step.

%% A required text field may start empty while the human is editing it.
gui_initial_value(Kind, Properties, Value) :-
    delete(Properties, property(required, _), Rest),
    gui_value(Kind, [property(required, false) | Rest], Value).

gui_default_value(Kind, _, <<"">>) :- once(isa(Kind, text_box)).
gui_default_value(Kind, _, false) :- once(isa(Kind, boolean_input)).
gui_default_value(Kind, Properties, Value) :-
    once(isa(Kind, selection)),
    (member(property(multiple, true), Properties) -> Value = []
    ; member(property(options, [option(Value, _) | _]), Properties)).
gui_default_value(Kind, Properties, Min) :-
    once(isa(Kind, numeric_input)), member(property(range, range(Min, _, _)), Properties).

%% Stable component roles bind local input and cursor results. Descriptors are
%% ground values, not suspended Prolog variables awaiting keyboard events.
gui_view(proof_console, View) :-
    gui_workspace(<<"Prolog console">>,
         [editor(goal, <<"Prolog goal">>), bindings(results, <<"Bindings">>),
          button(run, <<"Run">>), button(next, <<"Next solution">>),
          button(accept, <<"Accept solution">>), button(stop, <<"Stop">>), button(resolve, <<"Check saved outcome">>)], View).

gui_view(space_library, View) :-
    gui_workspace(<<"My worlds">>,
        [catalogue_selection(world, <<"World">>), text_box(status, <<"Status">>),
         button(create, <<"Create world">>), button(enter, <<"Enter world">>),
         button(settings, <<"Viewing distance">>), button(edit, <<"Terrain tools">>),
         button(refresh, <<"Refresh worlds">>), button(setup, <<"Set up world tools">>),
         button(resolve, <<"Check saved operation">>), button(return, <<"Return to lobby">>)], View).

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
    gui_tree_schema(component(workspace, [form], [attribute(label, Title)], Children), Tree, _).
gui_workspace_fields([], []).
gui_workspace_fields([Field | Rest], [component(Id, [Kind], [attribute(label, Label)], []) | Children]) :-
    Field =.. [Kind, Id, Label], gui_workspace_fields(Rest, Children).

%% Private native operations retain the original verified execute request.
%% Their live results are consumed only by actual prepared presentation work.
no_follow(gui_native_prepare/6).
no_follow(gui_native_activate/4).
gui_query(gui_native_prepare(_, _, _, _, _, _)).
gui_query(gui_native_activate(_, _, _, _)).

gui_native_prepare(Human, Receiver, Question, Descriptor, Capacity, Receipt) :-
    term_variables([Human, Receiver, Question, Descriptor, Capacity], []),
    Human = agent_instance_ref(Ns, Anchor, Instance),
    Ns::(current_ontology_identity(Ns, Anchor),
         gui_receiver_accept(Instance, Receiver, Capacity)),
    '$quod_gui_receiver_prepare'(Human, Receiver, Question, Descriptor, Capacity, Receipt).

gui_native_activate(Human, Connection, Token, Status) :-
    '$quod_gui_receiver_activate'(Human, Connection, Token, Status).

%% The existing action candidate owns policy checks and rollback. Its private
%% transition prepares a real receiver resource before staging this promise.
no_follow(gui_opening_allowed/1).
no_follow(gui_prepared/1).
gui_query(gui_prepare_question(_)).
gui_query(gui_prepared(_)).
action('$quod_stage_gui'(Handle, Opening, gui_prepared(Opening)),
       [gui_opening_allowed(Opening)], gui_prepared(Opening)).

gui_opening_allowed(gui_opening(ontology_ref(GuiNs, GuiAnchor), Reference,
    form_ref(SourceNs, SourceAnchor, Form), Human, Actor, View, Receiver, Hosting, Capacity)) :-
    current_ontology_identity(GuiNs, GuiAnchor),
    SourceNs::(current_ontology_identity(SourceNs, SourceAnchor),
               gui_open_definition(Form, Human, Actor, Reference, View)),
    Actor = agent_instance_ref(ActorNs, ActorAnchor, Instance),
    ActorNs::(current_ontology_identity(ActorNs, ActorAnchor),
              gui_responder_for(Instance, form_ref(SourceNs, SourceAnchor, Form), Human, Hosting)),
    Human = agent_instance_ref(HumanNs, HumanAnchor, HumanInstance),
    HumanNs::(current_ontology_identity(HumanNs, HumanAnchor),
              gui_receiver_accept(HumanInstance, Receiver, Capacity)).

gui_prepared(Opening) :- '$quod_gui_prepared'(Opening).

%% Public vocabulary selectors share this one foundation admission policy.
gui_query(Goal) :- measure_query(Goal).
gui_query(Goal) :- rendering_query(Goal).
gui_query(Goal) :- modelling_query(Goal).
gui_query(Goal) :- lens_query(Goal).
gui_query(Goal) :- prolog_query(Goal).
