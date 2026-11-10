%% Descriptor and binding helpers interpret data locally. A colon in an
%% input value is never a request to follow that value into another ontology.
no_follow(gui_component_schema/4).
no_follow(gui_component_schema/5).
no_follow(gui_class_chain/3).
no_follow(gui_chain_property/3).
no_follow(gui_tree_schema/3).
no_follow(gui_children_schema/3).
no_follow(gui_initial_projection/3).
no_follow(gui_valid_values/1).
no_follow(gui_properties/3).
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
gui_vocabulary(Ns, Anchor) :- current_ontology_identity(Ns, Anchor).
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
gui_query(gui_icon(_, _)).
gui_query(gui_purpose_icon(_, _)).
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
gui_attribute(text_box, max_bytes, nonnegative_integer, optional).
gui_attribute(selection, options, labelled_values, required).
gui_attribute(selectable_list, multiple, boolean, default(false)).
gui_attribute(table, headings, text_list, required).
gui_attribute(image, image, image_asset, required).
gui_attribute(button, image, optional_image_asset, default(none)).
gui_attribute(container, layout, layout, default(column)).
%% A form's image is the icon of the operation it offers, in menus and strips.
gui_attribute(form, image, optional_image_asset, default(none)).
gui_attribute(container, appearance, gui_appearance, default(inherit)).
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
gui_kind(menu_item).

%% A HUD is an ordinary class; each human composes one instance. Its strip is
%% one menu level whose wedges are the human's authored allowance, so commands
%% past it nest under "More" like any pie. Commands are menu items.
isa(hud, thing).

%% The vocabulary's own icons: line glyphs in the house ink on transparent
%% ground, published as content-addressed assets. Forms and menus refer to
%% them by name; a client shows the image where the sketch shows one and
%% falls back to the label's initials without.
no_follow(gui_icon/2).
no_follow(gui_purpose_icon/2).
gui_icon(accept, image(asset(<<"7b243c704098440348152df08bb33d5ce3c2bdfe71e828db26b56f73455a1c85">>, <<"image/png">>), resources(1860, 16384))).
gui_icon(account, image(asset(<<"c198ab56893753eb5b82ba1491940e8e44f35ca8f1f539710dfedd6f6e98c8dc">>, <<"image/png">>), resources(2766, 16384))).
gui_icon(account_controls, image(asset(<<"6f4da85202f3a0c808df9981663341d40671ab17f133522a0669fdda1ac6cd83">>, <<"image/png">>), resources(1632, 16384))).
gui_icon(attention, image(asset(<<"392f95140074b3e5162d8b2cc860a3ebe66c0bb20ca30deb4f4fe31949eab56a">>, <<"image/png">>), resources(4379, 16384))).
gui_icon(back, image(asset(<<"e799c393a99d0d3628d05f4c39518c9211213979fd95ffd5204e54e3bf430a93">>, <<"image/png">>), resources(955, 16384))).
gui_icon(controllers, image(asset(<<"22874de5cdc094924b7b54ce5198dce0c0b07f23704ec31327212afc52671a03">>, <<"image/png">>), resources(4893, 16384))).
gui_icon(create_exact, image(asset(<<"81551291fff5b3b6278d22f58083766e9d39a4f7323f1813da9dc326b786004e">>, <<"image/png">>), resources(3206, 16384))).
gui_icon(create_finite, image(asset(<<"10cb7a60ee0d4b85f634b888d23c34384dcc2fd40bf27115aa6133e85d1751ed">>, <<"image/png">>), resources(2785, 16384))).
gui_icon(create_here, image(asset(<<"1320941c3a3b79716403806ad34b19b39f10920e266b93d9e9783fb20d6abeef">>, <<"image/png">>), resources(4641, 16384))).
gui_icon(create_infinite, image(asset(<<"6e838ec3e3cef10dffeb52c32e25f1e94be12b37216dc70fe7a4e38dbb451d1c">>, <<"image/png">>), resources(2841, 16384))).
gui_icon(create_storage, image(asset(<<"ccb396c150eca6bd7dc6ad5decfb2d5ee5ea4216ced72e5881a320dec6df478b">>, <<"image/png">>), resources(4523, 16384))).
gui_icon(decline, image(asset(<<"89595f66e3caaa073570349da4111a3c4818b8fea496c94465a7eca28dfe6a77">>, <<"image/png">>), resources(1292, 16384))).
gui_icon(device, image(asset(<<"059015d96d31a1b494de7b7c8001f64b2946a66bc433198c09500cc16cfada32">>, <<"image/png">>), resources(1970, 16384))).
gui_icon(enter, image(asset(<<"eaa918e337b050b95e91f2728b56d46b9a605cafb95ded4787a8111af33d3713">>, <<"image/png">>), resources(1567, 16384))).
gui_icon(farther, image(asset(<<"56c975f652fb70f04975b2fc0f33d6b4878cc7c66be21da76358d21574f233fe">>, <<"image/png">>), resources(1837, 16384))).
gui_icon(go_to, image(asset(<<"36652b712193cb0eb76fdac8319b2788cf2cbaae279cee7877f67d1427eaa183">>, <<"image/png">>), resources(3837, 16384))).
gui_icon(hide, image(asset(<<"ca04f09de6eab99c94f999ed8086dac3b35992371e89f46de23ac58594fde191">>, <<"image/png">>), resources(3870, 16384))).
gui_icon(inspect, image(asset(<<"8aa3240d88ef69fc14ab29514a4380d0b901f9f4aced431c393013a6b311237f">>, <<"image/png">>), resources(3410, 16384))).
gui_icon(inspection, image(asset(<<"b2779413cf637752e512a046a515ec4d2a8af1752e5d87eba1aa516acd361f9f">>, <<"image/png">>), resources(1629, 16384))).
gui_icon(leave, image(asset(<<"bb182c7fb117a1dc013d5eb9bb99f5605c9b2c46e4311669325b75a804e6c521">>, <<"image/png">>), resources(1605, 16384))).
gui_icon(matrix, image(asset(<<"793cabf0c5cb2b0ef16e85c10b080130dab950ada00657b215550213c11f1300">>, <<"image/png">>), resources(2500, 16384))).
gui_icon(me, image(asset(<<"a33fbc2379ea162f586a6e964e6765c9c7630d4729a823ecaf787cc0e22554d5">>, <<"image/png">>), resources(3555, 16384))).
gui_icon(more, image(asset(<<"07f924613b4cc096db76d30d800ed1c32e5e5ff2bc8d7c25cebb29b20e1661d2">>, <<"image/png">>), resources(609, 16384))).
gui_icon(move_panel, image(asset(<<"0a9277d4a88bc694812ae5fba3480ac6c1ad297e3a9bb8c6d9a19ee63b51351a">>, <<"image/png">>), resources(2296, 16384))).
gui_icon(nearer, image(asset(<<"3c502ab9596d9f693d23e2a335cc64ac40f1cec574db7a510b64bebe05df49ba">>, <<"image/png">>), resources(1672, 16384))).
gui_icon(panels_opacity, image(asset(<<"147243a8fda4f33f8aa0d4ecd01b16e9857c9a180cba9516a1b46f221ef4c487">>, <<"image/png">>), resources(2234, 16384))).
gui_icon(question, image(asset(<<"e4e8fb93e34d08ac72646a9eea4dc66109b810d056afdba90f38dfdc18884d48">>, <<"image/png">>), resources(5336, 16384))).
gui_icon(recenter, image(asset(<<"f51e7c627d0f067505b52232f9cb787af5b9fcd37a05e5f243c829318e842727">>, <<"image/png">>), resources(4455, 16384))).
gui_icon(show_as, image(asset(<<"443faa8df4937365e159ecd54a0c7b5b23539bf55141d5330912d2a0665c57c2">>, <<"image/png">>), resources(4311, 16384))).
gui_icon(show_none, image(asset(<<"fe4318c1ff1e4fbb9be665ffc5ab08508084e6423e685af6f49a9bbe32ad8375">>, <<"image/png">>), resources(3489, 16384))).
gui_icon(source, image(asset(<<"957dde426601d7cbf44db51a213e5a6f04a75e7b221a677ebc3804ccc46e5e2c">>, <<"image/png">>), resources(2418, 16384))).
gui_icon(text_larger, image(asset(<<"3e382db372492f52ef2554c76136e05f03ed9757d549a9b26ca707b2f8f029ce">>, <<"image/png">>), resources(2118, 16384))).
gui_icon(text_smaller, image(asset(<<"7a205675c04f6c46b85d107f264c4bd54eae68fb63e2802d492fb65dc613b88e">>, <<"image/png">>), resources(2027, 16384))).
gui_icon(vr, image(asset(<<"c8b7ec10c76c9c2fffd890a8aef1480a1d3f69e501ec2c68a9ce17bf8e8b3ba5">>, <<"image/png">>), resources(2175, 16384))).
gui_icon(wireframe, image(asset(<<"dd8cf8820abe42498cb57c0b0d0c479ceeb0dda28595b45821ba9700275f94e5">>, <<"image/png">>), resources(4531, 16384))).
gui_icon(workspace, image(asset(<<"30eb5539c7181615c9fb9eed6f5b0e0418c0dcdfe1d3f81c72ef717979831489">>, <<"image/png">>), resources(1466, 16384))).
%% The icon a menu shows for a view or an inspection of a given purpose.
gui_purpose_icon(playing, show_as).
gui_purpose_icon(edition, show_as).
gui_purpose_icon(prolog, source).
gui_purpose_icon(inspection, inspection).
gui_purpose_icon(workspace, workspace).
gui_purpose_icon(attention, attention).

%% Pie menus. Each `menu` level offers its authored number of wedges; a wedge
%% is a `menu_item` choosing one Eidolon of one exact subject, or a nested menu.
%% Items keep fixed positions: `slot` 1 is the top wedge, then clockwise.
isa(menu_item, gui_component).
gui_attribute(menu_item, target, menu_target, required).
gui_attribute(menu_item, confirm, boolean, default(false)).
gui_attribute(Kind, image, optional_image_asset, default(none)) :- member(Kind, [menu, menu_item]).
gui_attribute(Kind, slot, menu_slot, default(auto)) :- member(Kind, [menu, menu_item]).
%% A nested menu keeps the wedge opposite its parent item for going back.
gui_attribute(menu, back, menu_back, default(none)).
%% Authored allowance, not a client cap: about eight directions per level stay
%% learnable (Kurtenbach & Buxton). Recipes may declare another count per menu.
gui_attribute(menu, wedges, positive_integer, default(8)).

%% One walk up the class tree per component. This vocabulary is a tree, so a
%% component's kind is the nearest declared kind above its classes, and each
%% attribute comes from the nearest owner on that chain; no further class
%% queries are needed once the chain is known.
gui_component_schema(Classes, Attributes, Kind, Properties) :-
    gui_component_schema(Classes, Attributes, Kind, Properties, _).
gui_component_schema(Classes, Attributes, Kind, Properties, Chain) :-
    term_variables(Classes-Attributes, []),
    gui_class_chain(Classes, Kind, Chain),
    findall(property(Key, Default), gui_chain_property(Chain, Key, Default), Contract),
    gui_properties(Contract, Attributes, Properties),
    gui_kind_properties(Kind, Chain, Properties).

%% The selected kind with every class above it. Among the declared kinds the
%% component's classes fall under, the most specific has no other below it;
%% several classes still select one kind, and two unrelated kinds remain
%% ambiguous, as before. The chain is a set: nothing depends on its order.
gui_class_chain(Classes, Kind, [Kind | Above]) :-
    findall(A, (member(Class, Classes), isa(Class, A)), Raw), sort(Raw, Reached),
    findall(K, (member(K, Reached), gui_kind(K)), Applicable),
    findall(K, (member(K, Applicable), \+ (member(Other, Applicable), Other \== K, isa(Other, K))), [Kind]),
    findall(A, (member(A, Reached), A \== Kind, isa(Kind, A)), Above).

%% An attribute applies from its nearest declaring owner on the chain.
gui_chain_property(Chain, Key, Default) :-
    gui_attribute(Owner, Key, _, Default), member_eq(Owner, Chain),
    \+ (gui_attribute(Nearer, Key, _, _), Nearer \== Owner, member_eq(Nearer, Chain), isa(Nearer, Owner)).

no_follow(gui_kind_properties/3).
gui_kind_properties(image, _, Properties) :- !, member(property(image, image(_, _)), Properties).
gui_kind_properties(table, _, Properties) :- !,
    member(property(headings, Headings), Properties),
    member(property(options, Options), Properties),
    length(Headings, Count),
    \+ (member(option(_, Cells), Options),
        \+ (gui_texts(Cells), length(Cells, Count))).
gui_kind_properties(_, Chain, Properties) :-
    (member_eq(selection, Chain) ->
        member(property(options, Options), Properties),
        \+ (member(option(_, Label), Options), \+ gui_text(Label))
    ; true).

%% One projection visits the vocabulary once for the whole form. These are
%% submitted class/attribute values, never another ontology's clauses or KB.
gui_tree_schema(component(Id, Classes, Attributes, RawChildren),
                component(Id, Kind, Properties, Children), Inputs) :-
    gui_component_schema(Classes, Attributes, Kind, Properties, Chain),
    (member_eq(container, Chain) -> true; RawChildren = []),
    gui_children_schema(RawChildren, Children, DescendantInputs),
    (member_eq(input, Chain) -> Inputs = [Id | DescendantInputs]; Inputs = DescendantInputs).

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

gui_properties([], _, []).
gui_properties([property(Key, optional) | Contract], Attributes, Properties) :-
    \+ member(attribute(Key, _), Attributes), !,
    gui_properties(Contract, Attributes, Properties).
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
no_follow(gui_appearance/1).
no_follow(gui_appearance_tokens/2).
no_follow(gui_appearance_token/2).
no_follow(gui_rgb/1).
no_follow(menu_slot/1).
no_follow(menu_back/1).
no_follow(menu_target/1).
no_follow(menu_subject/1).
gui_appearance(inherit).
gui_appearance(appearance(1, Tokens)) :- gui_appearance_tokens(Tokens, []).
gui_appearance_tokens([], _).
gui_appearance_tokens([token(Name, Value) | Rest], Seen) :-
    atom(Name), \+ member_eq(Name, Seen), gui_appearance_token(Name, Value),
    gui_appearance_tokens(Rest, [Name | Seen]).
gui_appearance_token(Name, Value) :-
    member(Name, [panel, field, text, accent, edge, error, success]), gui_rgb(Value).
gui_appearance_token(panel_opacity, Value) :- integer(Value), Value >= 0, Value =< 1000.
gui_appearance_token(Name, Value) :-
    member(Name, [spacing, padding, corner_radius]), integer(Value), Value >= 0.
gui_rgb(rgb(R, G, B)) :-
    integer(R), integer(G), integer(B),
    R >= 0, R =< 255, G >= 0, G =< 255, B >= 0, B =< 255.
text_or_atom(Text) :- (atom(Text) -> true; gui_text(Text)).
layout(Value) :- member(Value, [column, row, grid]).
percentage(Value) :- integer(Value), Value >= 0, Value =< 100.
integer_range(range(Min, Max, Step)) :-
    integer(Min), integer(Max), integer(Step), Min =< Max, Step > 0.
labelled_values(Options) :- Options = [_ | _], gui_options(Options, []).
text_list(Headings) :- Headings = [_ | _], gui_texts(Headings).
optional_image_asset(none).
optional_image_asset(Value) :- image_asset(Value).
image_asset(image(asset(Digest, Mime), resources(Transfer, Pixels))) :-
    integer(Transfer), Transfer > 0, integer(Pixels), Pixels > 0,
    member(Mime, [<<"image/png">>, <<"image/jpeg">>]),
    binary(Digest), binary_codes(Digest, Bytes), length(Bytes, 64), gui_digest(Bytes).
menu_slot(auto).
menu_slot(Slot) :- integer(Slot), Slot > 0.
menu_back(none).
menu_back(Slot) :- integer(Slot), Slot > 0.
%% A wedge names its exact subject: one menu may offer several subjects' choices.
menu_target(choice(Subject, eidolon(Purpose, Style, recipe(Ns, Anchor, Recipe)))) :-
    term_variables(Subject-Purpose-Recipe, []), atom(Style), binary(Ns), binary(Anchor),
    menu_subject(Subject).
menu_subject(entity_ref(Ns, Anchor, _)) :- binary(Ns), binary(Anchor).
menu_subject(class_ref(Ns, Anchor, Class)) :- binary(Ns), binary(Anchor), atom(Class).
menu_subject(ontology_ref(Ns, Anchor)) :- binary(Ns), binary(Anchor).

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
    (member(property(max_bytes, Max), Properties) -> Length =< Max; true),
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
    findall(attribute(appearance, Value), attribute(workspace, appearance, Value), Appearance),
    gui_tree_schema(component(workspace, [form], [attribute(label, Title) | Appearance], Children), Tree, _).
gui_workspace_fields([], []).
gui_workspace_fields([Field | Rest], [component(Id, [Kind], [attribute(label, Label)], []) | Children]) :-
    Field =.. [Kind, Id, Label], gui_workspace_fields(Rest, Children).

%% menu_tree(+Spec, -Tree) compiles one pie through the ordinary component
%% schema. Spec is menu(Label, Help, Options, Entries); each entry is
%%   item(choice(Subject, Eidolon), Label, Help, Availability, Options)
%% (as returned by gui_menu_source/2), a nested menu/4, or
%% group(Label, Options, Purposes, Items): a nested menu of those items whose
%% Eidolon purpose is listed, omitted when none is. Options are slot(N),
%% confirm(true), image(Asset) and, on menus, wedges(N). A level holding more
%% entries than its wedges keeps its pinned entries and nests the rest under
%% "More"; nothing is dropped. Every wedge leaves with its concrete slot. A
%% nested menu reserves its `back` wedge, the direction of its parent's centre.
no_follow(menu_tree/2).
no_follow(menu_raw/5).
no_follow(menu_back_slot/4).
no_follow(menu_children/4).
no_follow(menu_wedges/2).
no_follow(menu_child_id/3).
no_follow(menu_child/5).
no_follow(menu_fit/4).
no_follow(menu_pinned/3).
no_follow(menu_take/4).
no_follow(menu_entry_slot/2).
no_follow(menu_slots/4).
no_follow(menu_free_slots/4).
no_follow(menu_assign/3).
no_follow(menu_enabled/4).
no_follow(menu_image/2).
no_follow(menu_choice_label/2).
no_follow(menu_caption/3).
no_follow(menu_purpose_caption/2).
no_follow(menu_title/2).
no_follow(menu_expand/2).
gui_query(menu_tree(_, _)).

menu_tree(Spec, Tree) :-
    term_variables(Spec, []),
    menu_raw(Spec, menu, auto, none, Raw),
    gui_tree_schema(Raw, Tree, _).

menu_raw(menu(Label, Help, Options, Entries), Id, Slot, Back,
         component(Id, [menu], [attribute(label, Label), attribute(help, Help),
                                attribute(wedges, Wedges), attribute(slot, Slot),
                                attribute(back, Back) | Image],
                   Children)) :-
    menu_wedges(Options, Wedges),
    menu_expand(Entries, Expanded),
    (Back == none -> Capacity = Wedges; Capacity is Wedges - 1),
    menu_fit(Expanded, Capacity, Wedges, Fitted),
    menu_slots(Fitted, Wedges, Back, Placed),
    menu_children(Placed, Id, Wedges, Children),
    menu_image(Options, Image).

menu_wedges(Options, Wedges) :-
    (member(wedges(Wedges), Options) -> true; gui_attribute(menu, wedges, _, default(Wedges))).

menu_children([], _, _, []).
menu_children([Slot-Entry | Rest], Parent, Wedges, [Child | Children]) :-
    menu_child_id(Parent, Slot, Id),
    menu_child(Entry, Id, Slot, Wedges, Child),
    menu_children(Rest, Parent, Wedges, Children).
menu_child_id(menu, Slot, wedge([Slot])).
menu_child_id(wedge(Path), Slot, wedge(Next)) :- append(Path, [Slot], Next).

menu_child(menu(Label, Help, Options, Entries), Id, Slot, ParentWedges, Raw) :-
    menu_wedges(Options, Wedges), menu_back_slot(Slot, ParentWedges, Wedges, Back),
    menu_raw(menu(Label, Help, Options, Entries), Id, Slot, Back, Raw).
menu_child(item(Target, Authored, Offered, Availability, Options), Id, Slot, _,
           component(Id, [menu_item], [attribute(label, Label), attribute(help, Help),
                attribute(target, Target), attribute(enabled, Enabled), attribute(slot, Slot),
                attribute(confirm, Confirm) | Image], [])) :-
    Target = choice(_, Choice),
    (Authored == none -> menu_choice_label(Choice, Label); Label = Authored),
    menu_enabled(Availability, Offered, Enabled, Help),
    (member(confirm(true), Options) -> Confirm = true; Confirm = false),
    menu_image(Options, Image).

%% Unavailable choices stay in place, dimmed, so learned paths stay true.
%% Operations still recheck their authorization on submission.
menu_enabled(unavailable, _, false, <<"You are not allowed to do this here.">>).
menu_enabled(unreachable, _, false, <<"Unavailable: its source can't be reached.">>).
menu_enabled(available, Help, true, Help).
menu_enabled(requires_input, Help, true, Help).

menu_image(Options, [attribute(image, Image)]) :- member(image(Image), Options), !.
menu_image(_, []).

%% The parent item's direction, turned half a circle, in this menu's wedges.
menu_back_slot(Slot, ParentWedges, Wedges, Back) :-
    Back is (((2 * (Slot - 1) + ParentWedges) * Wedges + ParentWedges) // (2 * ParentWedges)) mod Wedges + 1.

menu_fit(Entries, Capacity, _, Entries) :- length(Entries, Count), Count =< Capacity, !.
menu_fit(Entries, Capacity, Wedges, Fitted) :-
    menu_pinned(Entries, Pinned, Free),
    length(Pinned, Count), Keep is Capacity - Count - 1,
    %% Every level must place at least one entry, or nesting never ends.
    (Keep >= 1 -> true; fail_with_reason(menu_wedges_too_few(Wedges))),
    menu_take(Keep, Free, Kept, Rest),
    append(Pinned, Kept, Placed),
    gui_icon(more, More),
    append(Placed, [menu(<<"More">>, <<"">>, [image(More)], Rest)], Fitted).

menu_pinned([], [], []).
menu_pinned([Entry | Rest], Pinned, Free) :-
    menu_pinned(Rest, PinnedRest, FreeRest),
    (menu_entry_slot(Entry, _) -> Pinned = [Entry | PinnedRest], Free = FreeRest
    ; Pinned = PinnedRest, Free = [Entry | FreeRest]).

menu_take(0, Rest, [], Rest) :- !.
menu_take(Count, [Entry | Entries], [Entry | Kept], Rest) :-
    Next is Count - 1, menu_take(Next, Entries, Kept, Rest).

menu_entry_slot(item(_, _, _, _, Options), Slot) :- member(slot(Slot), Options), !.
menu_entry_slot(menu(_, _, Options, _), Slot) :- member(slot(Slot), Options), !.

menu_slots(Entries, Wedges, Back, Placed) :-
    findall(Slot, (member(Entry, Entries), menu_entry_slot(Entry, Slot)), Pinned),
    sort(Pinned, Unique), length(Pinned, Count),
    (length(Unique, Count) -> true; fail_with_reason(duplicate_menu_slot(Pinned))),
    (member(Slot, Pinned), \+ (integer(Slot), Slot >= 1, Slot =< Wedges, Slot \== Back) ->
        fail_with_reason(menu_slot_unavailable(Slot, Wedges))
    ; true),
    menu_free_slots(1, Wedges, [Back | Pinned], Free),
    menu_assign(Entries, Free, Unsorted),
    sort(Unsorted, Placed).

menu_free_slots(Slot, Wedges, _, []) :- Slot > Wedges, !.
menu_free_slots(Slot, Wedges, Pinned, Free) :-
    Next is Slot + 1, menu_free_slots(Next, Wedges, Pinned, Rest),
    (member(Slot, Pinned) -> Free = Rest; Free = [Slot | Rest]).

menu_assign([], _, []).
menu_assign([Entry | Entries], Free, [Slot-Entry | Placed]) :-
    menu_entry_slot(Entry, Slot), !, menu_assign(Entries, Free, Placed).
menu_assign([Entry | Entries], [Slot | Free], [Slot-Entry | Placed]) :-
    menu_assign(Entries, Free, Placed).

%% Plain captions for the shared view and inspection styles. A source's own
%% label (operation forms) always wins; unknown styles get their purpose's.
menu_choice_label(eidolon(Purpose, Style, _), Label) :- menu_caption(Purpose, Style, Label), !.
menu_choice_label(eidolon(Purpose, _, _), Label) :- menu_purpose_caption(Purpose, Label), !.
menu_choice_label(_, <<"Open">>).
menu_caption(playing, solid, <<"Solid">>).
menu_caption(playing, wireframe, <<"Wire box">>).
menu_caption(playing, contents, <<"Permitted contents">>).
menu_caption(playing, matrix, <<"Matrix walls">>).
menu_caption(edition, solid, <<"Edit as solid">>).
menu_caption(edition, wireframe, <<"Edit as wire box">>).
menu_caption(edition, contents, <<"Edit permitted contents">>).
menu_caption(edition, matrix, <<"Edit as matrix walls">>).
menu_caption(prolog, source, <<"Source">>).
menu_caption(inspection, policy, <<"Policy">>).
menu_caption(inspection, interfaces, <<"Interfaces">>).
menu_caption(inspection, routes, <<"Routes">>).
menu_caption(workspace, workbench, <<"Workbench">>).
menu_purpose_caption(playing, <<"Another view">>).
menu_purpose_caption(edition, <<"Another editing view">>).
menu_purpose_caption(prolog, <<"Source view">>).
menu_purpose_caption(inspection, <<"Inspection">>).
menu_purpose_caption(workspace, <<"Workspace">>).
menu_purpose_caption(operation(_), <<"Action">>).

menu_title(Name, Name) :- binary(Name), Name \== <<"">>, !.
menu_title(_, <<"Actions">>).

menu_expand([], []).
menu_expand([group(Label, Options, Purposes, Items) | Rest], Expanded) :- !,
    findall(Item, (member(Item, Items), Item = item(choice(_, eidolon(P, _, _)), _, _, _, _),
                   member(P, Purposes)), Selected),
    menu_expand(Rest, Tail),
    (Selected = [] -> Expanded = Tail; Expanded = [menu(Label, <<"">>, Options, Selected) | Tail]).
menu_expand([Entry | Rest], [Entry | Tail]) :- menu_expand(Rest, Tail).

%% The default pie of any thing: its offered actions first, then its views
%% under "Show as" and its source and inspections under "Inspect".
no_follow(gui_menu_default_spec/2).
eidolon(default_menu, subject(ontology_ref(Ns, Anchor), Entity), menu(Tree)) :-
    term_variables(Ns-Anchor-Entity, []),
    in_ontology(Ns, Anchor, gui_menu_source(Entity, Source)),
    gui_menu_default_spec(Source, Spec),
    menu_tree(Spec, Tree).
gui_menu_default_spec(menu_source(Name, Items), menu(Title, <<"">>, [], Entries)) :-
    menu_title(Name, Title),
    findall(Item, (member(Item, Items),
                   Item = item(choice(_, eidolon(operation(_), _, _)), _, _, _, _)), Actions),
    gui_icon(show_as, Shows), gui_icon(inspect, Inspects),
    append(Actions, [group(<<"Show as">>, [image(Shows)], [playing, edition], Items),
                     group(<<"Inspect">>, [image(Inspects)], [prolog, inspection, workspace], Items)], Entries).

%% Private native operations retain the original verified execute request.
%% Their live results are consumed only by actual prepared presentation work.
no_follow(gui_native_prepare/6).
no_follow(gui_native_activate/4).
gui_query(gui_native_prepare(_, _, _, _, _, _)).
gui_query(gui_native_activate(_, _, _, _)).

gui_native_prepare(Human, Receiver, Question, Descriptor, Capacity, Receipt) :-
    term_variables([Human, Receiver, Question, Descriptor, Capacity], []),
    gui_receiver_accept(Human, Receiver, Capacity),
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
    Source, Human, Actor, View, Receiver, Hosting, Capacity)) :-
    current_ontology_identity(GuiNs, GuiAnchor),
    gui_open_definition(Source, Human, Actor, Reference, View),
    gui_responder_for(Actor, Source, Human, Hosting),
    gui_receiver_accept(Human, Receiver, Capacity).

gui_prepared(Opening) :- '$quod_gui_prepared'(Opening).

%% Public vocabulary selectors share this one foundation admission policy.
gui_query(Goal) :- measure_query(Goal).
gui_query(Goal) :- rendering_query(Goal).
gui_query(Goal) :- modelling_query(Goal).
gui_query(Goal) :- lens_query(Goal).
gui_query(Goal) :- prolog_query(Goal).

%% Question behavior belongs to the class owner; exact references identify
%% the application form, responsible agent and rows in their storing ontologies.
gui_query(gui_open(_, _)).
gui_query(gui_open_definition(_, _, _, _, _)).
gui_query(gui_validate_submission(_, _, _, _, _, _)).
gui_query(gui_form_projection(_, _, _, _)).
gui_query(gui_continue(_)).
gui_query(gui_submit(_, _, _, _)).
gui_query(gui_complete(_)).
gui_query(gui_consume(_)).
gui_query(gui_cancel(_)).
gui_query(gui_answer(_, _, _, _, _, _)).
gui_query(gui_question_view(_, _, _, _)).
gui_query(gui_question_form(_, _)).
gui_query(gui_question_status(_, _)).
gui_query(gui_retirement(_, _)).
gui_query(gui_responder_for(_, _, _, _)).
gui_query(gui_native_handler(_, _, _, _, _)).
gui_query(gui_accept_question(_)).
gui_query(gui_accepting(_)).
gui_query(gui_completion_signing(_, _, _)).

gui_question(question_ref(Ns, Anchor, Q), Source, Human, Actor, Revision, State) :-
    in_ontology(Ns, Anchor, gui_question(Q, Source, Human, Actor, Revision, State)).

gui_validate_submission(form_ref(Ns, Anchor, Form), Human, Actor, Revision, Control, Fields) :-
    term_variables([Ns, Anchor, Form, Human, Actor, Revision, Control, Fields], []),
    current_principal(Human),
    in_ontology(Ns, Anchor,
        (gui_question_policy(Form, Human, Actor), gui_bind(Form, Revision, Control, Fields, _))).

gui_form_projection(form_ref(Ns, Anchor, Form), Human, Actor,
                    form_view(Revision, Tree, ValuesToken, Values, Control)) :-
    term_variables([Ns, Anchor, Form, Human, Actor], []),
    current_principal(Human),
    in_ontology(Ns, Anchor,
        (gui_question_policy(Form, Human, Actor),
         gui_definition(Form, Revision, Tree, Fields, submit(Control, _)),
         gui_initial_values(Fields, Form, Tree, Values))),
    term_digest(Values, ValuesToken).

gui_continue(Reference) :-
    term_variables(Reference, []), current_principal(Actor),
    transaction((
        gui_answer(Reference, form_ref(Ns, Anchor, Form), Human, Revision, Control, Fields),
        in_ontology(Ns, Anchor,
            (gui_question_policy(Form, Human, Actor),
             gui_bind(Form, Revision, Control, Fields, Continuation),
             \+ gui_application_active(Reference), assertz(gui_application_active(Reference)),
             call(Continuation))),
        gui_consume(Reference),
        in_ontology(Ns, Anchor, retract(gui_application_active(Reference))))).

gui_open(Source, Reference) :-
    term_variables(Source, []), Source = form_ref(Ns, Anchor, Form),
    transaction((
        current_principal(Caller),
        in_ontology(Ns, Anchor,
            findall(pair(H, A), (gui_question_policy(Form, H, A), (Caller = H; Caller = A)), [pair(Human, Actor)])),
        gui_open_definition(Source, Human, Actor, Reference, View),
        gui_responder_for(Actor, Source, Human, Hosting),
        gui_receiver_accept(Human, Receiver, Capacity),
        current_ontology_identity(GuiNs, GuiAnchor),
        Opening = gui_opening(ontology_ref(GuiNs, GuiAnchor), Reference, Source, Human, Actor,
                              View, Receiver, Hosting, Capacity),
        gui_prepare_question(Opening), gui_accept_question(Opening))).

gui_open_definition(Source, Human, Actor, question_ref(ActorNs, ActorAnchor, question(Id)),
                    form_view(Revision, Tree, ValuesToken, Values, Control)) :-
    term_variables([Source, Human, Actor], []),
    current_principal(Caller), (Caller = Human; Caller = Actor),
    Source = form_ref(Ns, Anchor, Form), current_request_operation(Operation),
    Actor = agent_instance_ref(ActorNs, ActorAnchor, _),
    term_digest(gui_question(Operation, Source, Human, Actor), Id),
    in_ontology(Ns, Anchor,
        (gui_question_policy(Form, Human, Actor),
         gui_definition(Form, Revision, Tree, Fields, submit(Control, _)),
         gui_initial_values(Fields, Form, Tree, Values))),
    term_digest(Values, ValuesToken).

ontology_interface(gui_operations/2, <<"explicit class or instance operations">>).
ontology_interface(gui_operation_bind/7, <<"bind typed inputs to an authored goal and named results">>).
ontology_interface(gui_operation/6, <<"call the bound operation and return only its named results">>).
ontology_interface(gui_operation_classes/1, <<"classes offering creation in this storing ontology">>).

gui_question_view(Reference, Source, Revision, State) :-
    term_variables(Reference, []), current_principal(Human),
    gui_question(Reference, Source, Human, _, Revision, Stored), gui_visible_state(Stored, State).

gui_question_form(Reference, question_form(Source, Responsible, Revision, State, View)) :-
    term_variables(Reference, []), current_principal(Human),
    Reference = question_ref(Ns, Anchor, _),
    gui_question(Reference, Source, Human, Actor, Revision, Stored),
    gui_visible_state(Stored, State), Responsible = agent_instance_ref(Ns, Anchor, Actor),
    gui_form_projection(Source, Human, Responsible, View).

gui_submit(Reference, Revision, Control, Fields) :-
    term_variables([Reference, Revision, Control, Fields], []),
    Reference = question_ref(Ns, Anchor, Q),
    transaction((
        current_principal(Human), current_request_operation(Submission),
        gui_question(Reference, Source, Human, Actor, Revision, awaiting),
        gui_validate_submission(Source, Human, agent_instance_ref(Ns, Anchor, Actor), Revision, Control, Fields),
        gui_completion_request(Reference, Submission, Actor, Bytes),
        in_ontology(Ns, Anchor,
            (retract(gui_question(Q, Source, Human, Actor, Revision, awaiting)),
             assertz(gui_question(Q, Source, Human, Actor, Revision, submitted(Submission, Control, Fields, Bytes))))))).

gui_answer(Reference, Source, Human, Revision, Control, Fields) :-
    term_variables(Reference, []), Reference = question_ref(Ns, Anchor, _),
    current_principal(agent_instance_ref(Ns, Anchor, Actor)),
    gui_question(Reference, Source, Human, Actor, Revision, submitted(_, Control, Fields, _)).

gui_complete(Reference) :-
    term_variables(Reference, []), Reference = question_ref(Ns, Anchor, _),
    current_principal(agent_instance_ref(Ns, Anchor, Actor)),
    transaction((gui_question(Reference, _, _, Actor, _, submitted(_, _, _, Bytes)),
                 current_signed_request(Bytes), gui_continue(Reference))).

gui_consume(Reference) :-
    term_variables(Reference, []), Reference = question_ref(Ns, Anchor, Q),
    current_principal(agent_instance_ref(Ns, Anchor, Actor)),
    transaction((
        gui_question(Reference, Source, Human, Actor, Revision, Submitted),
        Submitted = submitted(_, _, _, Bytes), current_signed_request(Bytes),
        Source = form_ref(SourceNs, SourceAnchor, _),
        in_ontology(SourceNs, SourceAnchor, gui_application_active(Reference)),
        in_ontology(Ns, Anchor, assertz(gui_retiring(Q, Human))),
        gui_remove_hud(Human, Reference),
        in_ontology(Ns, Anchor,
            (retract(gui_question(Q, Source, Human, Actor, Revision, Submitted)),
             retract(instance_of(quod:gui:question, Q)), retract(gui_retiring(Q, Human)))))).

gui_cancel(Reference) :-
    term_variables(Reference, []), Reference = question_ref(Ns, Anchor, Q),
    transaction((
        current_principal(Human), gui_question(Reference, Source, Human, Actor, Revision, State),
        gui_cancelable(Reference, State),
        in_ontology(Ns, Anchor, assertz(gui_retiring(Q, Human))),
        gui_remove_hud(Human, Reference),
        in_ontology(Ns, Anchor,
            (retract(gui_question(Q, Source, Human, Actor, Revision, State)),
             retract(instance_of(quod:gui:question, Q)), retract(gui_retiring(Q, Human)))))).

gui_remove_hud(Human, Reference) :- gui_unlink(Human, Reference).
gui_retirement(Reference, Human) :-
    Reference = question_ref(Ns, Anchor, Q),
    in_ontology(Ns, Anchor, gui_retiring(Q, Human)), current_principal(Principal),
    (gui_question(Reference, _, Human, _, _, _), Principal = Human
    ; gui_question(Reference, _, Human, Actor, _, submitted(_, _, _, _)),
      Principal = agent_instance_ref(Ns, Anchor, Actor)).

gui_completion_request(Reference, Submission, Actor, Bytes) :-
    Reference = question_ref(Ns, Anchor, _),
    in_ontology(Ns, Anchor,
        (findall(K, agent_key(Actor, K, active), [Key]),
         findall(Ms, gui_completion_allowance(Actor, Ms), [Allowance]))),
    integer(Allowance), Allowance > 0,
    current_request_expiry(SubmissionExpiry), Expiry is SubmissionExpiry + Allowance,
    term_digest(gui_completion(Reference, Submission), Operation),
    <<"quod:root">>::(current_ontology_identity(<<"quod:root">>, Network), acl_sovereign(quod:root)),
    '$quod_program_source'([Actor], InstanceText),
    '$quod_program_source'([<<"quod:gui">>::gui_complete(Reference)], GoalText),
    agent_request_bytes(agent_goal_v1(Network, agent_instance_ref(Ns, Anchor, Actor), InstanceText, Key,
                                     Operation, Expiry, execute, 3, GoalText), Bytes).

%% Only the exact retained bytes and fixed completion goal may be signed.
gui_completion_signing(Node, Responsible, Typed) :-
    term_variables(Typed, []), Responsible = agent_instance_ref(Ns, Anchor, Actor),
    Typed = agent_goal_v1(_, Responsible, _, Key, _, _, execute, 3, GoalText),
    agent_request_bytes(Typed, Bytes),
    in_ontology(Ns, Anchor,
        (agent_hosted(Actor, Node, _, Key), gui_question(Q, _, _, Actor, _, submitted(_, _, _, Bytes)))),
    '$quod_program_source'([Completion], GoalText),
    term_variables(Completion, []), Completion = <<"quod:gui">>::gui_complete(question_ref(Ns, Anchor, Q)).

gui_visible_state(awaiting, awaiting).
gui_visible_state(submitted(Submission, Control, Fields, _), submitted(Submission, Control, Fields)).
gui_question_status(Reference, Status) :-
    term_variables(Reference, []), current_principal(Human),
    gui_question(Reference, _, Human, _, _, State),
    (State = awaiting -> Status = awaiting
    ; State = submitted(_, _, _, Bytes), Reference = question_ref(Ns, Anchor, _),
      in_ontology(Ns, Anchor, committed_operation_outcome(Bytes, Status))).
gui_cancelable(_, awaiting).
gui_cancelable(question_ref(Ns, Anchor, _), submitted(_, _, _, Bytes)) :-
    in_ontology(Ns, Anchor, committed_operation_outcome(Bytes, Status)),
    member(Status, [rejected, aborted, expired]).

gui_responder_for(Responsible, Source, Human, hosted(Node, Epoch, Key)) :-
    term_variables([Responsible, Source, Human], []),
    Responsible = agent_instance_ref(Ns, Anchor, Instance),
    current_principal(Principal), (Principal = Human; Principal = Responsible),
    in_ontology(Ns, Anchor,
        (gui_responder_policy(Instance, Source, Human),
         findall(hosted(N, E, K), agent_hosted(Instance, N, E, K), [hosted(Node, Epoch, Key)]),
         findall(Limit, gui_pending_allowance(Instance, Limit), [Capacity]),
         findall(Q, gui_question(Q, _, _, Instance, _, _), Pending),
         findall(Ms, gui_completion_allowance(Instance, Ms), [Allowance]))),
    integer(Capacity), Capacity > 0, length(Pending, Count), Count < Capacity,
    integer(Allowance), Allowance > 0.

gui_native_handler(Responsible, Source, Human, Hosting, Token) :-
    gui_responder_for(Responsible, Source, Human, Hosting),
    Responsible = agent_instance_ref(Ns, Anchor, Instance), Hosting = hosted(_, Epoch, Key),
    Head = react_on(assert(gui_question(Q, S, H, A, R, Submitted)),
                    <<"quod:gui">>::gui_complete(question_ref(ReactionNs, ReactionAnchor, Q))),
    Body = (Submitted = submitted(_, _, _, Bytes),
            me(agent_instance_ref(ReactionNs, ReactionAnchor, A)),
            gui_question(Q, S, H, A, R, Submitted), use_agent_request(Bytes)),
    in_ontology(Ns, Anchor,
        (clause(Head, Body), installed_agent_reaction(Instance, Epoch, Key, (Head :- Body), Token))).

gui_accept_question(Opening) :-
    term_variables(Opening, []),
    Opening = gui_opening(ontology_ref(GuiNs, GuiAnchor), question_ref(Ns, Anchor, Q), Source,
        Human, Responsible, form_view(Revision, _, _, _, _), _, Hosting, _),
    Responsible = agent_instance_ref(Ns, Anchor, Actor), current_ontology_identity(GuiNs, GuiAnchor),
    transaction((
        gui_responder_for(Responsible, Source, Human, Hosting), gui_prepared(Opening),
        in_ontology(Ns, Anchor,
            (\+ gui_question(Q, _, _, _, _, _),
             assertz((instance_of(quod:gui:question, Q) :- true)),
             assertz(gui_question(Q, Source, Human, Actor, Revision, awaiting)))),
        gui_link_question(Opening))).

gui_accepting(Opening) :-
    term_variables(Opening, []),
    Opening = gui_opening(ontology_ref(GuiNs, GuiAnchor), Reference, Source,
        Human, agent_instance_ref(Ns, Anchor, Actor), form_view(Revision, _, _, _, _), _, _, _),
    Reference = question_ref(Ns, Anchor, _), current_ontology_identity(GuiNs, GuiAnchor),
    gui_question(Reference, Source, Human, Actor, Revision, awaiting), gui_prepared(Opening).

%% The receiver route and pending references stay in the human's ontology.
gui_query(gui_pending_questions(_)).
gui_query(gui_select_receiver(_, _, _)).
gui_query(gui_receiver_for(_, _)).
gui_query(gui_receiver_accept(_, _, _)).
gui_query(gui_unlink(_, _)).
gui_query(gui_link_question(_)).

gui_pending_questions(References) :-
    current_principal(agent_instance_ref(Ns, Anchor, Human)),
    in_ontology(Ns, Anchor,
        (instance_of(quod:user:human_user, Human),
         findall(Reference, gui_pending(Human, Reference), Pending))),
    sort(Pending, References).

gui_select_receiver(Human, Node, Token) :-
    term_variables([Human, Node, Token], []),
    Human = agent_instance_ref(Ns, Anchor, Instance), current_principal(Human),
    binary_codes(Node, NodeBytes), length(NodeBytes, 32),
    binary_codes(Token, TokenBytes), length(TokenBytes, 32),
    transaction((
        in_ontology(Ns, Anchor,
            (instance_of(quod:user:human_user, Instance),
             findall(gui_selected_receiver(Instance, N, T), gui_selected_receiver(Instance, N, T), Previous))),
        (Previous = [gui_selected_receiver(Instance, Node, Token)] -> true
        ; gui_forget_receivers(ontology_ref(Ns, Anchor), Previous),
          in_ontology(Ns, Anchor, assertz(gui_selected_receiver(Instance, Node, Token)))))).

gui_forget_receivers(_, []).
gui_forget_receivers(ontology_ref(Ns, Anchor), [Row|Rows]) :-
    in_ontology(Ns, Anchor, retract(Row)), gui_forget_receivers(ontology_ref(Ns, Anchor), Rows).

gui_receiver_for(Human, receiver(Node, Token)) :-
    term_variables(Human, []), Human = agent_instance_ref(Ns, Anchor, Instance),
    current_principal(Principal),
    in_ontology(Ns, Anchor,
        (instance_of(quod:user:human_user, Instance),
         (Principal = Human; gui_receiver_policy(Instance, Principal)),
         findall(receiver(N, T), gui_selected_receiver(Instance, N, T), [receiver(Node, Token)]))).

gui_receiver_accept(Human, Receiver, Capacity) :-
    gui_receiver_for(Human, Receiver), Human = agent_instance_ref(Ns, Anchor, Instance),
    in_ontology(Ns, Anchor,
        (findall(Limit, gui_pending_allowance(Instance, Limit), [Capacity]),
         findall(Q, gui_pending(Instance, Q), Pending))),
    integer(Capacity), Capacity > 0, length(Pending, Count), Count < Capacity.

gui_unlink(Human, Reference) :-
    term_variables([Human, Reference], []), Human = agent_instance_ref(Ns, Anchor, Instance),
    gui_retirement(Reference, Human),
    in_ontology(Ns, Anchor,
        (instance_of(quod:user:human_user, Instance), retract(gui_pending(Instance, Reference)))).

gui_link_question(Opening) :-
    term_variables(Opening, []),
    Opening = gui_opening(_, Reference, _, Human, _, _, Receiver, _, Capacity),
    Human = agent_instance_ref(Ns, Anchor, Instance),
    gui_receiver_accept(Human, Receiver, Capacity), gui_accepting(Opening),
    in_ontology(Ns, Anchor,
        (\+ gui_pending(Instance, Reference), assertz(gui_pending(Instance, Reference)))).

%% HUD choices are exact references. Only the storing ontology holds the
%% accepted contributions, waiting offers and authored display allowance.
gui_query(gui_definition(_, _, _, _, _, _)).
gui_query(gui_bind_values(_, _, _, _, _)).
gui_query(gui_initial_values(_, _, _, _)).
gui_query(gui_form_caption(_, _, _, _, _)).
gui_query(hud_commands(_)).
gui_query(hud_contribute(_, _)).
gui_query(hud_withdraw(_, _)).
gui_query(hud_offer(_, _)).
gui_query(hud_withdraw_offer(_, _)).
gui_query(hud_answer_offer(_, _, _)).

hud_commands(hud(Tree)) :-
    current_principal(agent_instance_ref(Ns, A, Human)),
    in_ontology(Ns, A,
        (instance_of(quod:user:human_user, Human), instance_of(quod:gui:hud, Hud),
         findall(N, hud_allowance(Hud, N), [Allowance]))),
    findall(Item, hud_command(entity_ref(Ns, A, Hud), Human, Item), Items),
    menu_tree(menu(<<"Commands">>, <<"">>, [wedges(Allowance)], Items), Tree).

hud_command(entity_ref(Ns, A, _), Human,
    item(choice(Me, Choice), <<"Your attention">>, <<"Questions waiting for you">>, available, [image(Icon)])) :-
    Me = entity_ref(Ns, A, Human),
    in_ontology(Ns, A, entity_eidolons(Human, attention, _, [Choice])), gui_icon(attention, Icon).
hud_command(entity_ref(Ns, A, _), Human,
    item(choice(Me, Choice), <<"Me">>, <<"Your settings and keys">>, available, [image(Icon)])) :-
    Me = entity_ref(Ns, A, Human),
    in_ontology(Ns, A, entity_eidolons(Human, menu, _, [Choice])), gui_icon(me, Icon).
hud_command(entity_ref(Ns, A, _), _, Item) :-
    <<"quod:space">>::space_location(entity_ref(Ns, A, personal), placed(entity_ref(SNs, SA, Space), _)),
    in_ontology(SNs, SA,
        (entity_eidolons(Space, hud, _, Choices), member(Choice, Choices),
         client_eidolon(Space, Choice, hud(Items)))), member(Item, Items).
hud_command(entity_ref(Ns, A, Hud), _, Item) :-
    in_ontology(Ns, A, hud_contribution(Hud, Subject, Choice, _)),
    Subject = entity_ref(Source, Anchor, Entity),
    (in_ontology(Source, Anchor, gui_menu_source(Entity, menu_source(_, Items))),
     member(Offered, Items), Offered = item(choice(Subject, Choice), _, _, _, _) -> Item = Offered
    ; Item = item(choice(Subject, Choice), <<"Unavailable">>, <<"">>, unreachable, [])).

eidolon(attention, subject(ontology_ref(Ns, A), Human), attention(References)) :-
    current_principal(agent_instance_ref(Ns, A, Human)), gui_pending_questions(References).

%% The ordinary choice term carries the contributed subject and its recipe;
%% the HUD reference identifies where acceptance is stored.
hud_contribute(Hud, choice(Subject, Choice)) :-
    term_variables([Hud, Subject, Choice], []),
    Subject = entity_ref(_, _, _), Choice = eidolon(_, Style, recipe(_, _, _)), atom(Style),
    current_principal(Principal), hud_direct_contributor(Hud, Principal),
    Hud = entity_ref(Ns, A, Id),
    transaction(in_ontology(Ns, A,
        (instance_of(quod:gui:hud, Id),
         \+ hud_contribution(Id, Subject, Choice, _),
         assertz(hud_contribution(Id, Subject, Choice, Principal))))).

hud_direct_contributor(entity_ref(Ns, A, Id), Principal) :-
    in_ontology(Ns, A,
        (instance_of(quod:gui:hud, Id),
         findall(H, instance_of(quod:user:human_user, H), [Human]),
         findall(D, space_assignment_state(personal, _, D), Destinations))),
    (Principal = agent_instance_ref(Ns, A, Human)
    ; Principal = agent_instance_ref(Ns, A, personal)
    ; Destinations = [entity_ref(SNs, SA, Space)], in_ontology(SNs, SA, attribute(Space, owner, Principal))).

hud_offer(Hud, choice(Subject, Choice)) :-
    term_variables([Hud, Subject, Choice], []),
    Subject = entity_ref(_, _, _), Choice = eidolon(_, Style, recipe(_, _, _)), atom(Style),
    Hud = entity_ref(Ns, A, Id), current_principal(Principal),
    in_ontology(Ns, A,
        (instance_of(quod:gui:hud, Id), instance_of(quod:user:human_user, Human),
         gui_receiver_policy(Human, Principal))),
    (hud_direct_contributor(Hud, Principal) -> fail_with_reason(hud_contribute_directly); true),
    transaction(in_ontology(Ns, A,
        (instance_of(quod:gui:hud, Id),
         \+ hud_offered(Id, _, Subject, Choice), \+ hud_contribution(Id, Subject, Choice, _),
         assertz(hud_offered(Id, Principal, Subject, Choice))))).

hud_withdraw_offer(entity_ref(Ns, A, Id), choice(Subject, Choice)) :-
    term_variables([Ns, A, Id, Subject, Choice], []), current_principal(Principal),
    transaction(in_ontology(Ns, A,
        (instance_of(quod:gui:hud, Id), retract(hud_offered(Id, Principal, Subject, Choice))))).

hud_withdraw(entity_ref(Ns, A, Id), choice(Subject, Choice)) :-
    term_variables([Ns, A, Id, Subject, Choice], []), current_principal(Principal),
    transaction((
        in_ontology(Ns, A, (instance_of(quod:gui:hud, Id), hud_contribution(Id, Subject, Choice, Contributor))),
        (Principal = agent_instance_ref(Ns, A, Human),
         in_ontology(Ns, A, instance_of(quod:user:human_user, Human)) -> true; Principal = Contributor),
        in_ontology(Ns, A, (instance_of(quod:gui:hud, Id), retract(hud_contribution(Id, Subject, Choice, Contributor)))))).

%% The human answers through their existing class-selected operation form.
hud_answer_offer(entity_ref(Ns, A, Human), Offer, Answer) :-
    term_variables([Ns, A, Human, Offer, Answer], []), member(Answer, [accept, decline]),
    <<"quod:user">>::personal_agent_owner(agent_instance_ref(Ns, A, Human)),
    Offer = offer(Contributor, Subject, Choice),
    in_ontology(Ns, A, operation_authorized(instance(Human), answer_hud_offer(Offer, Answer))),
    transaction(in_ontology(Ns, A,
        (instance_of(quod:gui:hud, Id), retract(hud_offered(Id, Contributor, Subject, Choice)),
         (Answer == accept -> assertz(hud_contribution(Id, Subject, Choice, Contributor)); true)))).

eidolon(answer_hud_offer, subject(ontology_ref(Ns, A), instance(Human)), operation(hud_offers(Owner))) :-
    Owner = entity_ref(Ns, A, Human),
    in_ontology(Ns, A,
        (instance_of(quod:user:human_user, Human), instance_of(quod:gui:hud, Id), once(hud_offered(Id, _, _, _)))).
instance_of(quod:gui:form, hud_offers(entity_ref(Ns, A, H))) :- in_ontology(Ns, A, instance_of(quod:user:human_user, H)).
instance_of(quod:gui:selection, hud_offer_choice(_)).
instance_of(quod:gui:selection, hud_offer_answer).
instance_of(quod:gui:button, hud_offer_submit).
attribute(hud_offers(_), label, <<"Offered commands">>).
attribute(hud_offers(_), image, Icon) :- gui_icon(question, Icon).
attribute(hud_offers(_), help, <<"Other agents asked to add these commands to your HUD. Nothing is added unless you accept.">>).
attribute(hud_offer_choice(_), label, <<"Offer">>).
attribute(hud_offer_choice(entity_ref(Ns, A, _)), options, Options) :-
    findall(option(offer(P, S, C), Label),
        (in_ontology(Ns, A, (instance_of(quod:gui:hud, Id), hud_offered(Id, P, S, C))),
         hud_offer_label(S, C, Label)), Options).
attribute(hud_offer_answer, label, <<"Answer">>).
attribute(hud_offer_answer, options, [option(accept, <<"Add it to my HUD">>), option(decline, <<"Decline">>)]).
attribute(hud_offer_submit, label, <<"Answer">>).
gui_children(hud_offers(H), [hud_offer_choice(H), hud_offer_answer, hud_offer_submit]).
gui_initial(hud_offers(_), hud_offer_answer, decline).
gui_form(hud_offers(Human), [field(hud_offer_choice(Human), Offer), field(hud_offer_answer, Answer)],
    submit(hud_offer_submit, <<"quod:gui">>::hud_answer_offer(Human, Offer, Answer), operation(answer_hud_offer(Offer, Answer), []))).
hud_offer_label(entity_ref(Ns, A, Entity), Choice, Label) :-
    (in_ontology(Ns, A, gui_menu_source(Entity, menu_source(_, Items))),
     member(item(choice(_, Choice), Offered, _, _, _), Items), binary(Offered) -> Label = Offered
    ; Label = <<"A command whose source can't be reached">>).
