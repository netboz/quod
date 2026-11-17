'$quod_assert_instance'(V0, V1, V2) :- term_variables(V1, []) , (var(V2) -> '$quod_build_plan'(V3) , operation_authorized(class(V1), create(V3)) , '$quod_instance_id'(V2) , (instance_of(V4, V2) -> fail_with_reason(instance_identity_collision(V2)) ; true) , '$quod_constructor_plan'(V1, V2, V3, V5, V6) , '$quod_membership_clause'(V0, V1, V2) , '$quod_initial_attribute_writes'(V2, V6) ; term_variables(V2, []) , (instance_of(V7, V2) -> '$quod_membership_clause'(V0, V1, V2) ; fail_with_reason(creation_requires_output_variable(V1)))).
'$quod_attribute_declaration'(V0, V1, V2, V3) :- have_attribute(V0, V1, V2, V3).
'$quod_attribute_declaration'(V0, V1, V2, optional) :- have_attribute(V0, V1, V2).
'$quod_attribute_default'(V0, V1, V2, V3) :- findall(V4, (member(declaration(V4, V1, V5, V6), V2) , V6 \== optional), V7) , findall(V8, (member(declaration(V4, V1, V9, V6), V2) , V6 \== optional , \+ '$quod_stricter_class'(V4, V7) , (V6 = default_from(V10) -> '$quod_class_predicate'(V4, V10, V11) , V8 = default_from(V11) ; V8 = V6)), V12) , term_variables(V12, []) , sort(V12, V13) , (V13 = [] -> V3 = optional ; V13 = [V3] -> true ; fail_with_reason(conflicting_attribute_defaults(V0, V1))).
'$quod_attribute_types'([], V0) :- term_variables(V0, []).
'$quod_attribute_types'([V0 | V1], V2) :- attribute_value(V0, V2) , '$quod_attribute_types'(V1, V2).
'$quod_build_entries'([], V0) :- true.
'$quod_build_entries'([attribute(V0, V1) | V2], V3) :- atom(V0) , \+ member_eq(attribute(V0), V3) , '$quod_build_entries'(V2, [attribute(V0) | V3]).
'$quod_build_inputs'(V0) :- term_variables(V0, []) , '$quod_build_entries'(V0, []) -> true ; fail_with_reason(invalid_build_inputs).
'$quod_class_predicate'(V0, V1, V2) :- '$quod_owner_name'(V0, V3, V4) -> V2 = V3 : V1 ; V2 = V1.
'$quod_constructor_branches'([], V0, V1, V1, []) :- true.
'$quod_constructor_branches'([V0 | V1], V2, V3, V4, V5) :- '$quod_constructor_graph'(V0, V2, V3, V6, V7) , '$quod_constructor_branches'(V1, V2, V6, V4, V8) , append(V7, V8, V5).
'$quod_constructor_description'(V0, V1, V2, V3, V4) :- term_variables(V0 - V1, []) , '$quod_build_inputs'(V2) , '$quod_constructor_graph'(V0, [], [], V5, V6) , '$quod_constructor_sort'(V5, V6, [], V3) , findall(declaration(V7, V8, V9, V10), (member(V7, V3) , '$quod_attribute_declaration'(V7, V8, V9, V10)), V11) , findall(V8, member(declaration(V12, V8, V13, V14), V11), V15) , sort(V15, V16) , (member(attribute(V8, V17), V2) , \+ member_eq(V8, V16) -> fail_with_reason(unknown_initial_attribute(V8)) ; true) , '$quod_initial_attributes'(V16, V0, V1, V2, V11, V4).
'$quod_constructor_graph'(V0, V1, V2, V3, V4) :- (member_eq(V0, V1) -> fail_with_reason(constructor_cycle(V0)) ; true) , (member_eq(V0, V2) -> V3 = V2 , V4 = [] ; '$quod_constructor_metadata'(V0, V5, V6) , term_variables(V5, []) , sort(V5, V7) , '$quod_constructor_parents'(V0, V7, V6, V8) , '$quod_constructor_branches'(V8, [V0 | V1], V2, V9, V10) , append(V9, [V0], V3) , findall(before(V11, V0), member(V11, V7), V12) , '$quod_parent_edges'(V8, V13) , append(V12, V13, V14) , append(V10, V14, V4)).
'$quod_constructor_metadata'(V0, V1, V2) :- '$quod_owner_name'(V0, V3, V4) -> V3 :: '$quod_constructor_metadata'(V4, V5, V6) , '$quod_qualified_classes'(V3, V5, V1) , findall(V7, (member(V8, V6) , (term_variables(V8, []) , '$quod_qualified_classes'(V3, V8, V9) -> V7 = V9 ; V7 = V8)), V2) ; (clause(constructor(V0, V10, V11), V12) -> fail_with_reason(constructor_body(V0)) ; true) , findall(V13, '$quod_direct_isa'(V0, V13), V1) , findall(V7, constructor_order(V0, V7), V2).
'$quod_constructor_parents'(V0, V1, V2, V3) :- V2 == [] , (V1 = [] ; V1 = [V4]) -> V3 = V1 ; V2 = [V3] , term_variables(V3, []) , '$quod_parent_list'(V3) , sort(V3, V1) , length(V3, V5) , length(V1, V5) -> true ; fail_with_reason(constructor_order(V0)).
'$quod_constructor_plan'(V0, V1, V2, V3, V4) :- '$quod_state_check'(once('$quod_constructor_description'(V0, V1, V2, V3, V4))).
'$quod_constructor_sort'([], V0, V1, []) :- true.
'$quod_constructor_sort'([V0 | V1], V2, V3, [V4 | V5]) :- once((member(V4, [V0 | V1]) , \+ (member(before(V6, V4), V2) , \+ member_eq(V6, V3)))) -> delete([V0 | V1], V4, V7) , '$quod_constructor_sort'(V7, V2, [V4 | V3], V5) ; fail_with_reason(constructor_order_cycle).
'$quod_declared_class'(V0) :- '$quod_direct_isa'(V0, V1).
'$quod_declared_class'(V0) :- '$quod_direct_isa'(V1, V0).
'$quod_default_value'(optional, V0, V1, absent) :- true.
'$quod_default_value'(required, V0, V1, V2) :- fail_with_reason(missing_initial_attribute(V1)).
'$quod_default_value'(default(V0), V1, V2, value(V0)) :- true.
'$quod_default_value'(default_from(V0), V1, V2, value(V3)) :- once(('$quod_owner_name'(V0, V4, V5) -> atom(V5) , V6 =.. [V5, V1, V3] , V4 :: V6 ; atom(V0) , V6 =.. [V0, V1, V3] , call(V6))) -> true ; fail_with_reason(initial_default_failed(V2, V0)).
'$quod_direct_isa'(V0, V1) :- clause(isa(V0, V1), V2) , \+ '$quod_isa_semantics'(V2) , call(V2).
'$quod_initial_attribute_writes'(V0, []) :- true.
'$quod_initial_attribute_writes'(V0, [attribute(V1, V2) | V3]) :- assertz(attribute(V0, V1, V2)) , '$quod_initial_attribute_writes'(V0, V3).
'$quod_initial_attributes'([], V0, V1, V2, V3, []) :- true.
'$quod_initial_attributes'([V0 | V1], V2, V3, V4, V5, V6) :- atom(V0) , (member(attribute(V0, V7), V4) -> V8 = value(V7) ; '$quod_attribute_default'(V2, V0, V5, V9) , '$quod_default_value'(V9, V3, V0, V8)) , (V8 = value(V10) -> findall(V11, (member(declaration(V12, V0, V13, V14), V5) , '$quod_class_predicate'(V12, V13, V11)), V15) , sort(V15, V16) , ('$quod_attribute_types'(V16, V10) -> true ; fail_with_reason(invalid_initial_attribute(V0))) , V6 = [attribute(V0, V10) | V17] ; V8 = absent , V6 = V17) , '$quod_initial_attributes'(V1, V2, V3, V4, V5, V17).
'$quod_isa_path'(V0, V1, V2) :- nonvar(V0) , nonvar(V1) , V0 \== V1 , '$quod_name_normalize'(V0, V3) , '$quod_name_normalize'(V1, V3).
'$quod_isa_path'(V0, V1, V2) :- '$quod_owner_name'(V0, V3, V4) , V3 :: isa(V4, V5) , '$quod_qualified_class'(V3, V5, V6) , \+ member_eq(V6, V2) , '$quod_name_normalize'(V1, V6).
'$quod_isa_path'(V0, V1, V2) :- '$quod_direct_isa'(V0, V1) , \+ member_eq(V1, V2).
'$quod_isa_path'(V0, V1, V2) :- '$quod_direct_isa'(V0, V3) , \+ member_eq(V3, V2) , '$quod_isa_path'(V3, V1, [V3 | V2]).
'$quod_isa_requires_closure'(V0, V1) :- var(V0).
'$quod_isa_requires_closure'(V0, V1) :- var(V1).
'$quod_isa_requires_closure'(V0, V1) :- \+ '$quod_direct_isa'(V0, V1).
'$quod_isa_semantics'('$quod_transitive_isa'(V0, V1)) :- true.
'$quod_isa_semantics'('$quod_known_class'(V0)) :- true.
'$quod_known_class'(V0) :- nonvar(V0) , ! , ('$quod_direct_isa'(V0, V1) ; '$quod_direct_isa'(V2, V0)) , !.
'$quod_known_class'(V0) :- findall(V1, '$quod_declared_class'(V1), V2) , sort(V2, V3) , member(V0, V3).
'$quod_membership_clause'(V0, V1, V2) :- V3 =.. [V0, (instance_of(V1, V2) :- true)] , call(V3).
'$quod_name_join'(V0, V1, V2 : V3) :- nonvar(V0) , V0 = V2 : V4 , ! , '$quod_name_join'(V4, V1, V3).
'$quod_name_join'(V0, V1, V0 : V1) :- true.
'$quod_name_normalize'(V0, V1) :- nonvar(V0) , V0 = V2 : V3 , ! , '$quod_name_normalize'(V2, V4) , '$quod_name_normalize'(V3, V5) , '$quod_name_join'(V4, V5, V1).
'$quod_name_normalize'(V0, V0) :- true.
'$quod_name_tail'(V0, V1, V2, V3) :- nonvar(V0) , V0 = V4 : V5 , ! , '$quod_name_tail'(V5, V1 : V4, V2, V3).
'$quod_name_tail'(V0, V1, V1, V0) :- true.
'$quod_owner_name'(V0 : V1, V2, V3) :- nonvar(V0) , '$quod_name_tail'(V1, V0, V2, V3).
'$quod_parent_edges'([], []) :- true.
'$quod_parent_edges'([V0], []) :- true.
'$quod_parent_edges'([V0, V1 | V2], [before(V0, V1) | V3]) :- '$quod_parent_edges'([V1 | V2], V3).
'$quod_parent_list'([]) :- true.
'$quod_parent_list'([V0 | V1]) :- '$quod_parent_list'(V1).
'$quod_qualified_class'(V0, V1, V2) :- (nonvar(V1) , V1 = V3 : V4 -> V5 = V1 ; V5 = V0 : V1) , '$quod_name_normalize'(V5, V6) , (var(V2) -> V2 = V6 ; '$quod_name_normalize'(V2, V6)).
'$quod_qualified_classes'(V0, [], []) :- true.
'$quod_qualified_classes'(V0, [V1 | V2], [V3 | V4]) :- nonvar(V1) , '$quod_qualified_class'(V0, V1, V3) , '$quod_qualified_classes'(V0, V2, V4).
'$quod_stricter_class'(V0, V1) :- member(V2, V1) , isa(V2, V0) , \+ isa(V0, V2).
'$quod_transitive_isa'(V0, V1) :- '$quod_owner_name'(V0, V2, V3) -> '$quod_isa_path'(V0, V1, []) ; '$quod_isa_requires_closure'(V0, V1) , '$quod_direct_isa'(V0, V4) , \+ member_eq(V4, [V0]) , '$quod_isa_path'(V4, V1, [V4, V0]).
action(place(V0, V1, V2), [goal(unplaced(V1)), placement_pose(V0, V2), space_authorized(V1, space_enter, V0, placement), space_authorized(V0, space_admit, V1, placement)], inside(V0, V1, V2)) :- true.
action(withdraw(V0), [space_assignment(V0, V1, V2), V2 \== none, space_authorized(V0, space_leave, V2, placement)], unplaced(V0)) :- true.
action(show(V0, V1), [space_instance(V0, space), V0 \== V1, space_authorized(V1, space_enter, V0, display), space_authorized(V0, space_admit, V1, display)], shown_in(V0, V1)) :- true.
action(hide(V0, V1), [space_removal_allowed(V0, V1, display)], not_shown_in(V0, V1)) :- true.
attribute(ontology_ref(V0, V1), transform, transform(0, 0, 0, 0, 0, 0)) :- current_ontology_identity(V0, V1).
attribute(ontology_ref(V0, V1), exterior, contents) :- current_ontology_identity(V0, V1).
attribute(ontology_ref(V0, V1), dimensions, infinite) :- current_ontology_identity(V0, V1).
attribute(eidolon(ontology, playing, contents), label, <<"Contents">>) :- true.
attribute(eidolon(ontology, playing, contents), image, V0) :- menu_icon(contents, V0).
attribute(show_as(V0, V1, V2, default), label, <<"Default">>) :- true.
attribute(show_as(V0, V1, V2, default), image, V3) :- menu_icon(default, V3).
attribute(show_as(V0, V1, V2, V3), V4, V5) :- member(V4, [label, image]) , attribute(eidolon(V1, V2, V3), V4, V5).
attribute(show_as_submit, label, <<"Show">>) :- true.
attribute(space_create(V0, finite), label, <<"Create space">>) :- true.
attribute(space_create(V0, exact), label, <<"Create space with rational lengths">>) :- true.
attribute(space_create(V0, infinite), label, <<"Create infinite space">>) :- true.
attribute(space_create(V0, finite), image, V1) :- menu_icon(create_finite, V1).
attribute(space_create(V0, exact), image, V1) :- menu_icon(create_exact, V1).
attribute(space_create(V0, infinite), image, V1) :- menu_icon(create_infinite, V1).
attribute(space_create(V0, V1), help, <<"The personal agent's human is the default owner, independently of the selected storage and placement. Creation does not enter the new space.">>) :- true.
attribute(space_name, label, <<"Name">>) :- true.
attribute(space_name, help, <<"A place name is suggested. Change it to use your own.">>) :- true.
attribute(space_name, required, false) :- true.
attribute(space_placement(V0), label, <<"Placement">>) :- true.
attribute(space_placement(ontology_ref(V0, V1)), options, V2) :- findall(option(at(entity_ref(V0, V1, V3), transform(0, 0, 0, 0, 0, 0)), V4), (space_instance(entity_ref(V0, V1, V3), space) , in_ontology(V0, V1, attribute(V3, name, V4))), V5) , append([option(near_agent, <<"In front of me, or unplaced when my agent is unplaced">>), option(unplaced, <<"Unplaced">>)], V5, V2).
attribute(space_view, label, <<"Where you look">>) :- true.
attribute(space_view, help, <<"Filled by the device that shows the form: in front of you is where your eyes look.">>) :- true.
attribute(space_length(width), label, <<"Width (X)">>) :- true.
attribute(space_length(height), label, <<"Height (Y)">>) :- true.
attribute(space_length(depth), label, <<"Depth (Z)">>) :- true.
attribute(space_length(V0), range, range(1, 1000000, 1)) :- true.
attribute(space_divisor(V0), label, V1) :- member(V0 - V1, [width - <<"Width divisor">>, height - <<"Height divisor">>, depth - <<"Depth divisor">>]).
attribute(space_divisor(V0), help, <<"The length is the numerator divided by this positive integer, in the selected unit.">>) :- true.
attribute(space_divisor(V0), range, range(1, 1000000, 1)) :- true.
attribute(space_unit, label, <<"Length unit">>) :- true.
attribute(space_unit, options, [option(<<"mm">>, <<"Millimetres">>), option(<<"cm">>, <<"Centimetres">>), option(<<"m">>, <<"Metres">>), option(<<"km">>, <<"Kilometres">>)]) :- true.
attribute(space_create_submit, label, <<"Create">>) :- true.
attribute(space_travel_form(V0, V1, V2, placed(V3, V4)), label, <<"Enter space">>) :- true.
attribute(space_travel_form(V0, V1, V2, V3), label, <<"Leave space">>) :- space_leaving(V3).
attribute(space_travel_form(V0, V1, V2, placed(V3, V4)), image, V5) :- menu_icon(enter, V5).
attribute(space_travel_form(V0, V1, V2, V3), image, V4) :- space_leaving(V3) , menu_icon(leave, V4).
attribute(space_travel_form(V0, V1, V2, placed(V3, V4)), help, <<"Move the same personal agent into this space. Navigation follows the committed location.">>) :- true.
attribute(space_travel_form(V0, V1, V2, parent(V3, V4)), help, <<"Go back to the space this one stands in, in front of it.">>) :- true.
attribute(space_travel_form(V0, V1, V2, unplaced), help, <<"This space stands in no other: leaving makes the personal agent unplaced.">>) :- true.
attribute(space_travel_submit, label, <<"Move">>) :- true.
attribute(eidolon(space, playing, solid), label, <<"Solid">>) :- true.
attribute(eidolon(space, playing, solid), image, V0) :- menu_icon(solid, V0).
attribute(eidolon(space, playing, contents), label, <<"Contents">>) :- true.
attribute(eidolon(space, playing, contents), image, V0) :- menu_icon(contents, V0).
attribute(eidolon(space, interior, wireframe), label, <<"Wire">>) :- true.
attribute(eidolon(space, interior, wireframe), image, V0) :- menu_icon(wireframe, V0).
attribute(eidolon(space, interior, matrix), label, <<"Matrix">>) :- true.
attribute(eidolon(space, interior, matrix), image, V0) :- menu_icon(matrix, V0).
attribute_value(term, V0) :- ! , term_variables(V0, []).
attribute_value(V0, V1) :- term_variables(V1, []) , ('$quod_owner_name'(V0, V2, V3) -> V2 :: attribute_value(V3, V1) ; atom(V0) , V4 =.. [V0, V1] , call(V4)).
boolean(true) :- true.
boolean(false) :- true.
can_invoke(V0, V1, [], V2) :- true.
can_invoke(V0, V1, V2, V3) :- space_query(V0).
can_invoke((current_ontology_identity(V0, V1) , V2), V3, V4, V5) :- space_query(V2).
can_invoke(V0, V1, V2, V3) :- system_source_query(V0).
can_invoke(V0, node(V1), V2, V3) :- peer_admitted(V1, V4, V5, V1).
can_join(V0, V1, V2) :- peer_ready(V2).
class_ancestors(V0, V1) :- findall(V2, ((V3 = V0 ; isa(V0, V3)) , '$quod_name_normalize'(V3, V2)), V4) , sort(V4, V1).
class_below(V0, V1, V2) :- member(V3 - V4, V2) , V3 == V0 , ! , member_eq(V1, V4).
class_eidolon(predicate, prolog, source, recipe(V0, V1, predicate_source)) :- current_ontology_identity(V0, V1).
class_eidolon(predicate, V0, solid, recipe(V1, V2, predicate_model)) :- member(V0, [playing, edition]) , current_ontology_identity(V1, V2).
class_eidolon(thing, prolog, source, recipe(V0, V1, prolog_editor)) :- V0 = <<"quod:gui">> , quod : root :: system_ontology(V0, V1).
class_eidolon(ontology, inspection, V0, recipe(V1, V2, V0)) :- member(V0, [policy, interfaces, routes]) , V1 = <<"quod:gui">> , quod : root :: system_ontology(V1, V2).
class_eidolon(ontology, workspace, workbench, recipe(V0, V1, workbench)) :- V0 = <<"quod:gui">> , quod : root :: system_ontology(V0, V1).
class_eidolon(ontology, V0, contents, recipe(V1, V2, ontology_contents)) :- member(V0, [playing, edition]) , current_ontology_identity(V1, V2).
class_eidolon(thing, menu, default, recipe(V0, V1, default_menu)) :- menu_vocabulary(V0, V1).
class_eidolon(V0, operation(instance), show(V1, V2), recipe(V3, V4, show(V0, V1, V2))) :- atom(V0) , member(V1, [playing, interior]) , findall(V5, (class_eidolon(V0, V1, V5, V6) , attribute(eidolon(V0, V1, V5), label, V7)), V8) , sort(V8, V9) , V9 \== [] , (member(V2, V9) ; V2 = default) , current_ontology_identity(V3, V4).
class_eidolon(space, operation(class), V0, recipe(V1, V2, V3)) :- space_creation_recipe(V0, V3, V4) , current_ontology_identity(V1, V2).
class_eidolon(space, operation(instance), enter, recipe(V0, V1, space_enter)) :- current_ontology_identity(V0, V1).
class_eidolon(space, operation(instance), leave, recipe(V0, V1, space_leave)) :- current_ontology_identity(V0, V1).
class_eidolon(space, menu, default, recipe(V0, V1, space_menu)) :- current_ontology_identity(V0, V1).
class_eidolon(space, V0, contents, recipe(V1, V2, space_contents)) :- member(V0, [playing, edition]) , current_ontology_identity(V1, V2).
class_eidolon(space, playing, solid, recipe(V0, V1, marker)) :- scene_vocabulary(V0, V1).
class_eidolon(space, edition, solid, recipe(V0, V1, space_edition)) :- current_ontology_identity(V0, V1).
class_eidolon(space, interior, wireframe, recipe(V0, V1, space_wireframe)) :- current_ontology_identity(V0, V1).
class_eidolon(space, interior, matrix, recipe(V0, V1, space_matrix)) :- current_ontology_identity(V0, V1).
class_eidolons(V0, V1) :- class_eidolons(V0, V2, V3, V1).
class_eidolons(V0, V1, V2, V3) :- findall(candidate(V4, V1, V2, V5), (member(V6, V0) , class_ancestors(V6, V7) , member(V4, V7) , class_eidolon(V4, V1, V2, V5)), V8) , findall(V4, member(candidate(V4, V9, V10, V11), V8), V12) , sort(V12, V13) , findall(V4 - V7, (member(V4, V13) , class_ancestors(V4, V7)), V14) , findall(eidolon(V1, V2, V5), (member(V15, V8) , V15 = candidate(V4, V1, V2, V5) , \+ (member(candidate(V16, V1, V2, V17), V8) , class_below(V16, V4, V14) , \+ class_below(V4, V16, V14)) , \+ local_recipe_overrides(V15, V8)), V18) , sort(V18, V3).
class_permission(thing, show_as, allow) :- true.
class_permission(space, V0, allow) :- member(V0, [create, space_enter, space_admit, space_leave, space_remove, space_visit, space_represent]).
client_eidolon(V0, V1, V2) :- term_variables([V0, V1], []) , V1 = eidolon(V3, V4, recipe(V5, V6, V7)) , entity_eidolons(V0, V3, V4, V8) , member_eq(V1, V8) , current_ontology_identity(V9, V10) , V11 = ontology_ref(V9, V10) , (client_scene_purpose(V3, V12) -> client_entity_scene(V0, V12, appearance(V13, V14, V15, V16, V17)) , in_ontology(V5, V6, eidolon(V7, V15, V18)) , client_eidolon_scene(V0, V3, V4, V16, V18, V2) ; in_ontology(V5, V6, eidolon(V7, subject(V11, V0), V2))).
client_eidolon_scene(V0, V1, V2, V3, contents(V4), eidolon_scene(V5, V6, V7, V8)) :- ! , current_ontology_identity(V9, V10) , V5 = entity_ref(V9, V10, V0) , V4 = exposure(V5, V11, V12) , quod : space :: space_exposure_projection(V4, V1, V6, V8) , client_space_selection(V0, V6, V7).
client_eidolon_scene(V0, V1, V2, V3, V4, eidolon_scene(entity_ref(V5, V6, V0), V7, nonphysical, [])) :- current_ontology_identity(V5, V6) , scene_vocabulary(V8, V9) , in_ontology(V8, V9, place_model(<<"selected">>, V3, depicts(V5, V6, V0), V4, V10)) , in_ontology(V8, V9, model(V10, V7)).
client_entity_scene(V0, V1, V2) :- findall(V3, entity_scene(V0, V1, V3), V4) , (V4 \== [] -> member(V2, V4) ; current_ontology_identity(V5, V6) , entity_classes(V0, V7) , findall(owner(V8, V9), (member(V8, V7) , '$quod_owner_name'(V8, V10, V11) , ontology_name(V10, V9)), V12) , findall(V9, member(owner(V13, V9), V12), V14) , sort(V14, V15) , findall(candidate(V8, V3), (member(V9, V15) , V9 :: entity_scene(subject(ontology_ref(V5, V6), V0), V1, V3) , member(owner(V8, V9), V12)), V16) , findall(V8, member(candidate(V8, V17), V16), V18) , findall(V3, (member(candidate(V8, V3), V16) , \+ '$quod_stricter_class'(V8, V18)), V19) , sort(V19, V20) , member(V2, V20)).
client_menu(V0, V1) :- term_variables(V0, []) , (V0 = class_ref(V2, V3, V4) -> gui_operation_subject(V0, class(V5), V6, class) ; V5 = V0) , entity_eidolons(V5, menu, V7, V8) , (V8 = [V9] -> client_eidolon(V5, V9, V1) ; V8 = [] -> V1 = none ; fail_with_reason(ambiguous_menu(V5))).
client_scene_purpose(playing, playing) :- true.
client_scene_purpose(edition, edition) :- true.
client_scene_purpose(selected, playing) :- true.
client_simulation_frame(V0, V1, V2, simulation_view(V3, V4, V5, V6, V7, V8, V9), simulation_view(V3, V4, V5, V6, V7, V8, V9, view_frame(entity_ref(V10, V11, V0), V1, V2))) :- current_ontology_identity(V10, V11).
client_simulation_frame(V0, V1, V2, V3, V3) :- member(V3, [disabled, denied, recovering, unavailable]).
client_space_selection(V0, V1, V2) :- current_ontology_identity(V3, V4) , V5 = entity_ref(V3, V4, V0) , (quod : space :: space_simulation_domain(V5, world_ref(V6, V7, V8), V9, V10) -> (V6 :: (current_ontology_identity(V6, V7) , physics_client_view(V8, V1, V11) , physics_view_frames(V8, V10, V12) , physics_scene_frames(V8, V1, V13)) , client_simulation_frame(V0, V12, V13, V11, V2) -> true ; V2 = unavailable) ; quod : space :: space_instance(V5, physical_space) -> (findall(V14, physics_client_view(V0, V1, V14), [V11]) , physics_scene_frames(V0, V1, V13) , client_simulation_frame(V0, [], V13, V11, V2) -> true ; V2 = unavailable) ; current_principal(V15) , findall(V14, physics_control(V0, V15, V16, V14), V17) , (V17 = [] -> V2 = nonphysical ; V17 = [none] -> V2 = nonphysical ; V2 = unavailable)).
client_subject_label(V0, V1) :- client_subject_name(V0, V2) , ((V2 == unnamed ; V2 == <<"">>) -> V1 = unlabelled ; V1 = label(V2, <<"above">>)).
client_subject_name(V0, V1) :- findall(V2, attribute(V0, name, V2), V3) , (V3 = [] -> V1 = unnamed ; V3 = [V1] , binary(V1) -> true ; fail_with_reason(invalid_subject_name(V0))).
client_view_dependencies([]) :- true.
client_view_dependencies([dependency(V0, V1, V2) | V3]) :- V0 :: current_ontology_identity(V0, V1) , client_view_dependencies(V3).
client_world_view(V0, V1, V2, world_view(entity_ref(V3, V4, V0), V5, V6, V7)) :- term_variables([V0, V1, V2], []) , atom(V1) , client_view_dependencies(V2) , current_ontology_identity(V3, V4) , client_subject_name(V0, V5) , (quod : space :: space_instance(entity_ref(V3, V4, V0), space) , findall(V8, quod : space :: world_view(entity_ref(V3, V4, V0), V1, V8), [V6]) , term_variables(V6, []) , findall(ontology_ref(V9, V10), rendering_vocabulary(V9, V10), [ontology_ref(V11, V12)]) , V11 :: (current_ontology_identity(V11, V12) , well_formed_scene(V6)) -> client_space_selection(V0, V6, V7) ; V6 = [] , V7 = unavailable).
consensus_incarnation(<<"\xA3\\xCC\\xC8\\xB7\4\xE7\\xA6\\xAE\\xB4\%\x19\\x8E\N\xF3\f\xAF\\xE9\1\xD6\\x85\\xE5\ \x98\\x82\\x91\q\xB6\Gu\xF\~v">>) :- true.
delete(V0, V1, V2) :- insert(V2, V1, V0).
digest_hex_codes([], []) :- true.
digest_hex_codes([V0 | V1], [V2, V3 | V4]) :- V5 is V0 // 16 , V6 is V0 mod 16 , digest_hex_digit(V5, V2) , digest_hex_digit(V6, V3) , digest_hex_codes(V1, V4).
digest_hex_digit(V0, V1) :- V0 < 10 -> V1 is V0 + 48 ; V1 is V0 + 87.
eidolon(predicate_source, subject(V0, predicate(V1)), V2) :- instance_of(predicate, predicate(V1)) , quod : root :: system_ontology(<<"quod:gui">>, V3) , in_ontology(<<"quod:gui">>, V3, eidolon(prolog_editor(V1), subject(V0, predicate(V1)), V2)).
eidolon(predicate_model, predicate(V0), [part(<<"predicate">>, box(800, 500, 200), transform(0, 0, 0, 0, 0, 0), surface(<<"#6A90D9">>, 0, 700, 0, 1000, []), label(V1, <<"above">>), depicts_nothing)]) :- instance_of(predicate, predicate(V0)) , '$quod_program_source'([V0], V2) , binary_codes(V2, V3) , append(V4, [46, 10], V3) , binary_codes(V1, V4).
eidolon(ontology_contents, subject(ontology_ref(V0, V1), V2), contents(V3)) :- current_ontology_identity(V0, V1) , ontology_inspect(predicates(V4), V5) , quod : space :: space_contents_projection(entity_ref(V0, V1, V2), V3).
eidolon(show(V0, V1, V2), subject(ontology_ref(V3, V4), instance(V5)), operation(show_as(entity_ref(V3, V4, V5), V0, V1, V2))) :- in_ontology(V3, V4, entity_eidolons(V5, V1, V6, V7)) , findall(V8, member(eidolon(V9, V8, V10), V7), V11) , sort(V11, [V12, V13 | V14]) , (V2 == default -> once(in_ontology(V3, V4, viewer_eidolon(V5, V1, V15, V16))) ; (in_ontology(V3, V4, eidolon_seen(V5, V1, V17, V18)) -> V2 \== V17 ; true) , member(eidolon(V19, V2, recipe(V20, V21, V22)), V7) , once(in_ontology(V20, V21, eidolon(V22, subject(ontology_ref(V3, V4), V5), V23)))).
eidolon(V0, subject(V1, class(V2)), operation(space_create(V1, V3))) :- current_ontology_identity(V4, V5) , once((isa(V2, V6) , '$quod_qualified_class'(V4, V6, V7) , '$quod_owner_name'(V7, V8, space) , ontology_name(V8, V4))) , space_creation_recipe(V9, V0, V3).
eidolon(space_enter, subject(ontology_ref(V0, V1), instance(V2)), operation(V3)) :- space_travel_context(V4, V5, V6) , V7 = entity_ref(V0, V1, V2) , V6 \== V7 , V3 = space_travel_form(V4, V5, V6, placed(V7, transform(0, 0, 0, 0, 0, 0))).
eidolon(space_leave, subject(ontology_ref(V0, V1), instance(V2)), operation(V3)) :- space_travel_context(V4, V5, entity_ref(V0, V1, V2)) , space_leave_to(entity_ref(V0, V1, V2), V6) , V3 = space_travel_form(V4, V5, entity_ref(V0, V1, V2), V6).
eidolon(space_menu, subject(ontology_ref(V0, V1), V2), V3) :- in_ontology(V0, V1, isa(V2, V2)) , ! , menu_vocabulary(V4, V5) , in_ontology(V4, V5, eidolon(default_menu, subject(ontology_ref(V0, V1), V2), V3)).
eidolon(space_menu, subject(ontology_ref(V0, V1), V2), menu(V3)) :- space_instance(entity_ref(V0, V1, V2), space) , in_ontology(V0, V1, gui_menu_source(V2, menu_source(V4, V5))) , in_ontology(V0, V1, gui_menu_source(quod : space : space, menu_source(V6, V7))) , in_ontology(V0, V1, gui_menu_source(ontology_ref(V0, V1), menu_source(V8, V9))) , (space_travel_context(V10, V11, entity_ref(V0, V1, V2)) -> V12 = interior ; V12 = playing) , findall(V13, (member(V13, V5) , V13 = item(choice(V14, eidolon(V15, show(V12, V16), V17)), V18, V19, V20, V21)), V22) , findall(V13, (member(V23, V5) , \+ V23 = item(choice(V24, eidolon(V25, show(V26, V27), V28)), V29, V30, V31, V32) , space_menu_action(V23, V13)), V33) , findall(V13, space_menu_destination(V2, V0, V1, V13), V34) , menu_icon(create_here, V35) , menu_icon(show_as, V36) , menu_icon(inspect, V37) , menu_icon(go_to, V38) , append([group(<<"Create here">>, [slot(1), image(V35)], [operation(class)], V7), group(<<"Show as">>, [slot(2), image(V36)], [operation(instance)], V22), group(<<"Inspect">>, [slot(3), image(V37)], [prolog, inspection, workspace], V9) | V33], [group(<<"Go to">>, [image(V38)], [operation(instance)], V34)], V39) , (binary(V4) , V4 \== <<"">> -> V40 = V4 ; V40 = <<"Space">>) , menu_vocabulary(V41, V42) , in_ontology(V41, V42, menu_tree(menu(V40, <<"">>, [], V39), V3)).
eidolon(space_wireframe, V0, V1) :- space_extent(V0, V2, V3, V4) , unique_solution(scene_vocabulary(V5, V6)) , in_ontology(V5, V6, eidolon(extent(V2, V3, V4), V0, V1)).
eidolon(space_matrix, V0, [part(<<"walls">>, box(V1, V2, V3), transform(0, 0, 0, 0, 0, 0), surface(<<"#030F08">>, 0, 900, 80, 220, []), unlabelled, depicts_nothing) | V4]) :- space_extent(V0, V5, V6, V7) , unique_solution(scene_vocabulary(V8, V9)) , in_ontology(V8, V9, eidolon(extent(V5, V6, V7, <<"#3CFF7A">>), V0, V4)) , space_whole_mm(V5, V1) , space_whole_mm(V6, V2) , space_whole_mm(V7, V3).
eidolon(space_edition, V0, V1) :- V0 = subject(ontology_ref(V2, V3), V4) , unique_solution(scene_vocabulary(V5, V6)) , in_ontology(V5, V6, eidolon(marker, V0, V7)) , in_ontology(V5, V6, marker_size(V8)) , in_ontology(V2, V3, attribute(V4, dimensions, V9)) , space_size_text(V9, V10) , V11 is - (V8 // 2) , append(V7, [part(<<"size">>, group, transform(0, V11, 0, 0, 0, 0), no_surface, label(V10, <<"below">>), depicts_nothing)], V1).
eidolon(space_contents, subject(ontology_ref(V0, V1), V2), contents(V3)) :- space_contents_projection(entity_ref(V0, V1, V2), V3).
eidolon_seen(V0, V1, V2, V3) :- viewer_eidolon(V0, V1, V2, V3) -> true ; once(client_entity_scene(V0, V1, appearance(V4, V2, V5, V6, V3))).
entity_classes(V0, V1) :- findall(V2, ((instance_of(V3, V0) ; V3 = V0 , isa(V3, V3)) , (V2 = V3 ; isa(V3, V2))), V4) , sort(V4, V1).
entity_eidolon_mode(V0, operation(class)) :- ! , once(isa(V0, V0)).
entity_eidolon_mode(V0, operation(instance)) :- ! , once(instance_of(V1, V0)).
entity_eidolon_mode(V0, V1) :- true.
entity_eidolons(V0, V1) :- entity_eidolons(V0, V2, V3, V1).
entity_eidolons(V0, V1, V2, V3) :- findall(V4, (instance_of(V4, V0) ; V4 = V0 , isa(V4, V4)), V5) , sort(V5, V6) , class_eidolons(V6, V1, V2, V7) , findall(eidolon(V8, V9, V10), (member(eidolon(V8, V9, V10), V7) , entity_eidolon_mode(V0, V8)), V3).
entity_scene(predicate(V0), V1, appearance(predicate(V0), solid, predicate(V0), V2, V3)) :- ontology_predicate(V0, V4) , V5 is V4 mod 16 * 1200 , V6 is - (V4 // 16) * 800 , V2 = transform(V5, V6, 0, 0, 0, 0) , entity_eidolons(predicate(V0), V1, solid, V3).
entity_scene(subject(ontology_ref(V0, V1), V2), interior, appearance(V2, V3, subject(ontology_ref(V0, V1), V2), transform(0, 0, 0, 0, 0, 0), V4)) :- space_instance(entity_ref(V0, V1, V2), space) , in_ontology(V0, V1, (attribute(V2, interior, V3) , entity_eidolons(V2, interior, V3, V4))).
entity_scene(subject(ontology_ref(V0, V1), V2), V3, appearance(V2, V4, subject(ontology_ref(V0, V1), V2), V5, V6)) :- space_instance(entity_ref(V0, V1, V2), space) , member(V3, [playing, edition]) , in_ontology(V0, V1, (attribute(V2, transform, V5) , attribute(V2, exterior, V7) , (V7 == contents -> V4 = contents ; V4 = solid) , entity_eidolons(V2, V3, V4, V6))).
external_predicate_modules([quod_agent_predicates(<<",\x95\\x81\\x8C\\x0\#\xED\\xEC\\xA5\O\x91\-wL\xB4\\x9C\\xAA\s\xC7\\x82\Ti\xA2\\x8\\xF3\\xBA\\xA1\\xF3\\xE5\\xCA\\xD8\\xBD\">>), quod_agent_work_predicates(<<"r\xAE\_\xD8\\x93\E\x83\\x5\EQ\xFC\\xF6\\xF3\S\x83\\x8C\D\xC3\~\x3\\x1E\o\xBD\ODR\x5\\xC5\.A\\7">>), quod_agent_hosting_tests(<<"\xA9\. \xEA\-xO\xA6\6}a\x99\\x5\\xA\d\xCE\o\xFB\]\xA5\\xC5\\xAB\\xFB\\x89\b\xC1\\x88\\xB0\\x8A\\xDF\\xFA\\x1\">>)]) :- true.
goal(V0) :- goal(V0, []).
goal(V0, V1) :- '$quod_callable'(V0) , resolve_goal(V0, V1).
gui_bind(V0, V1, V2, V3, V4) :- term_variables(V0 - V1 - V2 - V3, []) , gui_local_id(V0) , gui_local_id(V2) , gui_definition(V0, V1, V5, V6, submit(V2, V4)) , gui_bind_values(V0, V5, V6, V2, V3) , term_variables(V4, []).
gui_bind_fields([], [], V0, []) :- true.
gui_bind_fields([field(V0, V1) | V2], V3, V4, [value(V5, V6, V1) | V7]) :- once((delete(V3, field(V0, V1), V8) , gui_tree_component(V4, V0, V5, V6, []))) , gui_bind_fields(V2, V8, V4, V7).
gui_bind_values(V0, V1, V2, V3, V4) :- gui_tree_active(V1, V3) , gui_bind_fields(V2, V4, V1, V5) , gui_fixed_values(V2, V0, V1, V6) , gui_match_fixed(V6, V4) , gui_vocabulary(V7, V8) , in_ontology(V7, V8, gui_valid_values(V5)).
gui_children(show_as(V0, V1, V2, V3), [show_as_submit]) :- true.
gui_children(space_create(V0, V1), V2) :- space_form_lengths(V1, V3, V4) , findall(V5, member(field(V5, V6), V3), V7) , append([space_name | V7], [space_placement(V0), space_view, space_create_submit], V2).
gui_children(space_travel_form(V0, V1, V2, V3), [space_travel_submit]) :- true.
gui_class_basis(V0, V0) :- nonvar(V0) , V0 = V1 : V2 , !.
gui_class_basis(V0, V1) :- isa(V0, V1).
gui_compile(V0, V1, V2, V3, V4, V5) :- gui_local_id(V0) , findall(ontology_ref(V6, V7), gui_vocabulary(V6, V7), [ontology_ref(V8, V9)]) , findall(binding(V10, V11), gui_form(V0, V10, V11), [binding(V3, V12)]) , gui_submission(V12, V4, V5, V13) , gui_component_tree(V0, V8, [], V14, V15) , in_ontology(V8, V9, gui_tree_schema(V15, V2, V16)) , V2 = component(V0, form, V17, V18) , \+ (gui_tree_component(V2, V19, V20, V21, V22) , member(V20, [editor, bindings, catalogue_selection])) , V4 = submit(V23, V24) , gui_local_id(V23) , gui_tree_component(V2, V23, button, V25, V26) , gui_field_declarations(V3, V16, [], V27) , sort(V16, V28) , sort(V27, V28) , gui_results(V13, [], V29) , term_variables(V3, V30) , term_variables(V13, V31) , \+ (member(V32, V31) , member_eq(V32, V30)) , term_variables(V24, V33) , term_variables(V3 - V13, V34) , gui_variables_bound(V33, V34) , gui_variables_bound(V31, V33) , (V5 = operation(V35, V36) -> '$quod_callable'(V35) , term_variables(V35, V37) , gui_variables_bound(V37, V30) ; true) , '$quod_callable'(V24) , gui_fixed_values(V3, V0, V2, V38) , findall(V39, gui_validation_context(V0, V39), V40) , term_variables(V40, []) , sort(V40, V41) , gui_semantic_tree(V2, V42) , variant_digest(schema(1, ontology_ref(V8, V9), V42, binding(V3, V12), V38, V41), V1).
gui_component_children([], V0, V1, V1, []) :- true.
gui_component_children([V0 | V1], V2, V3, V4, [V5 | V6]) :- gui_component_tree(V0, V2, V3, V7, V5) , gui_component_children(V1, V2, V7, V4, V6).
gui_component_tree(V0, V1, V2, V3, component(V0, V4, V5, V6)) :- gui_local_id(V0) , \+ member_eq(V0, V2) , findall(attribute(V7, V8), attribute(V0, V7, V8), V5) , findall(V9, instance_of(V9, V0), V10) , term_variables(V10, []) , findall(V11, (member(V12, V10) , gui_class_basis(V12, V13) , '$quod_owner_name'(V13, V14, V11) , ontology_name(V14, V1)), V15) , sort(V15, V4) , findall(V9, gui_children(V0, V9), V16) , (V16 = [] -> V17 = [] ; V16 = [V17]) , term_variables(V17, []) , gui_component_children(V17, V1, [V0 | V2], V3, V6).
gui_definition(V0, V1, V2, V3, V4) :- gui_definition(V0, V1, V2, V3, V4, question).
gui_definition(V0, V1, V2, V3, V4, V5) :- once('$quod_state_check'(gui_compile(V0, V6, V7, V8, V9, V10))) , V1 = V6 , V2 = V7 , V3 = V8 , V4 = V9 , V5 = V10.
gui_field_declarations(V0, V1, V2, V3) :- nonvar(V0) , (V0 = [] -> V3 = V2 ; V0 = [V4 | V5] , nonvar(V4) , V4 = field(V6, V7) , gui_local_id(V6) , \+ member_eq(V6, V2) , member_eq(V6, V1) , gui_field_declarations(V5, V1, [V6 | V2], V3)).
gui_fixed_values(V0, V1, V2, V3) :- findall(field(V4, frozen), (member(field(V4, V5), V0) , once(gui_tree_component(V2, V4, V6, V7, [])) , (member(property(readonly, true), V7) -> true ; \+ gui_tree_active(V2, V4))), V8) , gui_project_values(frozen, V8, V1, V2, V3).
gui_form(show_as(V0, V1, V2, V3), [], submit(show_as_submit, quod : user :: show_as(V0, V2, V3), operation(show_as(V2, V3), []))) :- true.
gui_form(space_create(V0, V1), V2, submit(space_create_submit, (current_ontology_identity(V3, V4) , with_build_plan(V5, assert(instance_of(quod : space : space, V6))) , quod : space :: space_form_placement(entity_ref(V3, V4, V6), V7, V8, V9) , attribute(V6, owner, V10)), operation(create(V5), [result(space, entity_ref(V3, V4, V6)), result(location, V9), result(owner, V10)]))) :- V0 = ontology_ref(V3, V4) , space_form_lengths(V1, V11, V12) , append([field(space_name, V13) | V11], [field(space_placement(V0), V7), field(space_view, V8)], V2) , V5 = [attribute(name, V13), attribute(dimensions, V12)].
gui_form(space_travel_form(V0, V1, V2, V3), [], submit(space_travel_submit, (quod : space :: space_assignment(entity_ref(V4, V5, V6), V1, V2) , V7 , quod : space :: space_assignment(entity_ref(V4, V5, V6), V8, V9)), operation(space_visit(V0, V9), [result(agent, V0), result(location, V10), result(revision, V8)]))) :- V0 = agent_instance_ref(V4, V5, V6) , (V3 = unplaced -> V9 = none , V10 = unplaced , V7 = quod : space :: goal(unplaced(entity_ref(V4, V5, V6))) ; (V3 = placed(V9, V11) ; V3 = parent(V9, V11)) , V10 = placed(V9, V11) , V7 = quod : space :: goal(inside(V9, entity_ref(V4, V5, V6), V11))).
gui_form_caption(V0, V1, V2, V3, V4) :- findall(ontology_ref(V5, V6), gui_vocabulary(V5, V6), [ontology_ref(V7, V8)]) , gui_component_tree(V0, V7, [], V9, component(V0, V10, V11, V12)) , in_ontology(V7, V8, gui_component_schema(V10, V11, form, V13)) , findall(binding(V14, V15), gui_form(V0, V14, V15), [binding(V16, V17)]) , gui_submission(V17, V18, operation(V4, V19), V20) , member(property(label, V1), V13) , member(property(help, V2), V13) , member(property(image, V3), V13).
gui_initial(space_create(V0, V1), space_name, V2) :- quod : names :: draw(<<"place">>, form, V2).
gui_initial(space_create(V0, V1), space_placement(V0), near_agent) :- true.
gui_initial(space_create(V0, V1), space_view, none) :- true.
gui_initial(space_create(V0, V1), space_unit, V2) :- member(V1, [finite, exact]) , have_attribute(space, dimensions, space_dimensions, default(box(q(V3, V2), q(V4, V2), q(V5, V2)))).
gui_initial(space_create(V0, V1), space_length(V2), V3) :- member(V1, [finite, exact]) , have_attribute(space, dimensions, space_dimensions, default(box(q(V4, V5), q(V6, V7), q(V8, V9)))) , member(V2 - V3, [width - V4, height - V6, depth - V8]).
gui_initial(space_create(V0, exact), space_divisor(V1), 1) :- true.
gui_initial_queries([], V0, V1, []) :- true.
gui_initial_queries([field(V0, V1) | V2], V3, V4, [initial(V0, V5, V6, V7) | V8]) :- once(gui_tree_component(V4, V0, V5, V6, [])) , findall(V9, gui_initial(V3, V0, V9), V7) , term_variables(V7, []) , gui_initial_queries(V2, V3, V4, V8).
gui_initial_values(V0, V1, V2, V3) :- gui_project_values(editing, V0, V1, V2, V3).
gui_local_id(V0) :- term_variables(V0, []) , \+ V0 = V1 : V2.
gui_match_fixed([], V0) :- true.
gui_match_fixed([V0 | V1], V2) :- member_eq(V0, V2) , gui_match_fixed(V1, V2).
gui_menu_image(none, []) :- !.
gui_menu_image(V0, [image(V0)]) :- true.
gui_menu_item(V0, V1, item(choice(V0, V1), V2, V3, V4, V5)) :- V1 = eidolon(operation(V6), V7, V8) , ! , gui_operation_caption(V0, V7, V2, V3, V9, V4) , gui_menu_image(V9, V5).
gui_menu_item(V0, V1, item(choice(V0, V1), none, <<"">>, available, V2)) :- V1 = eidolon(V3, V4, V5) , V3 \== menu , findall(ontology_ref(V6, V7), gui_vocabulary(V6, V7), [ontology_ref(V8, V9)]) , (in_ontology(V8, V9, (gui_purpose_icon(V3, V10) , gui_icon(V10, V11))) -> true ; V11 = none) , gui_menu_image(V11, V2).
gui_menu_source(V0, menu_source(V1, V2)) :- term_variables(V0, []) , gui_menu_subject(V0, V3) , client_subject_name(V0, V1) , entity_eidolons(V0, V4) , findall(V5, (member(V6, V4) , gui_menu_item(V3, V6, V5)), V2).
gui_menu_subject(ontology_ref(V0, V1), ontology_ref(V0, V1)) :- ! , current_ontology_identity(V0, V1).
gui_menu_subject(V0, entity_ref(V1, V2, V0)) :- instance_of(V3, V0) , ! , current_ontology_identity(V1, V2).
gui_menu_subject(V0, class_ref(V1, V2, V3)) :- once(isa(V0, V0)) , ('$quod_owner_name'(V0, V4, V3) -> ontology_name(V4, V1) , V1 :: current_ontology_identity(V1, V2) ; V3 = V0 , current_ontology_identity(V1, V2)).
gui_operation(V0, V1, V2, V3, V4, V5) :- gui_operation_bind(V0, V1, V2, V3, V4, V6, V5) , call(V6).
gui_operation_availability(V0, V1, V2) :- term_variables(V1, []) -> (operation_authorized(V0, V1) -> V2 = available ; V2 = unavailable) ; V2 = requires_input.
gui_operation_bind(V0, V1, V2, V3, V4, V5, V6) :- var(V5) , var(V6) , gui_operation_binding(V0, V1, V2, V3, V4, V7, V6) , V5 = (gui_operation_guard(V0, V1, V2, V3, V4, V7, V6) , V7).
gui_operation_binding(V0, V1, V2, V3, V4, V5, V6) :- term_variables([V0, V1, V2, V3, V4], []) , '$quod_state_check'((gui_operation_definition(V0, V1, V2, form_ref(V7, V8, V9), V10, V11, submit(V3, V5), operation(V12, V13, V6)) , in_ontology(V7, V8, gui_bind_values(V9, V10, V11, V3, V4)) , operation_authorized(V12, V13))).
gui_operation_caption(V0, V1, V2, V3, V4, V5) :- gui_operation_form(V0, V1, V6, V7, form_ref(V8, V9, V10)) , in_ontology(V8, V9, gui_form_caption(V10, V2, V3, V4, V11)) , gui_operation_availability(V6, V11, V5).
gui_operation_classes(V0) :- '$quod_state_check'((findall(V1, (isa(V2, V2) , gui_menu_subject(V2, V1) , class_eidolons([V2], operation(class), V3, V4) , member(eidolon(V5, V6, V7), V4) , gui_operation_form(V1, V6, V8, V9, V10)), V11) , sort(V11, V0))).
gui_operation_definition(V0, V1, V2, V3, V4, V5, V6, operation(V7, V8, V9)) :- gui_operation_form(V0, V1, V7, V10, V3) , V3 = form_ref(V11, V12, V13) , in_ontology(V11, V12, gui_definition(V13, V14, V4, V5, V6, operation(V8, V9))) , variant_digest(offered_operation(V0, V1, V10, V3, V14), V2).
gui_operation_form(V0, V1, V2, recipe(V3, V4, V5), form_ref(V3, V4, V6)) :- gui_operation_subject(V0, V2, V7, V8) , class_eidolons(V7, operation(V8), V1, [eidolon(operation(V8), V1, recipe(V3, V4, V5))]) , current_ontology_identity(V9, V10) , V11 = ontology_ref(V9, V10) , findall(V12, in_ontology(V3, V4, eidolon(V5, subject(V11, V2), operation(V12))), [V6]).
gui_operation_guard(V0, V1, V2, V3, V4, V5, V6) :- gui_operation_binding(V0, V1, V2, V3, V4, V7, V8) , variant_digest(binding(V7, V8), V9) , variant_digest(binding(V5, V6), V9).
gui_operation_subject(class_ref(V0, V1, V2), class(V3), [V3], class) :- once(in_ontology(V0, V1, isa(V2, V2))) , current_ontology_identity(V4, V5) , (V0 == V4 -> V3 = V2 ; V3 = V0 : V2).
gui_operation_subject(entity_ref(V0, V1, V2), instance(V2), V3, instance) :- current_ontology_identity(V0, V1) , findall(V4, instance_of(V4, V2), V5) , sort(V5, V3) , V3 \== [].
gui_operation_view(V0, V1, operation_view(V1, V0, V2, V3, V4, V5, V6, V7, V8)) :- gui_operation_definition(V0, V1, V2, form_ref(V9, V10, V11), V3, V12, submit(V6, V13), operation(V14, V15, V16)) , in_ontology(V9, V10, gui_initial_values(V12, V11, V3, V5)) , term_digest(V5, V4) , gui_results(V16, [], V7) , gui_operation_availability(V14, V15, V8).
gui_operations(V0, V1) :- term_variables(V0, []) , '$quod_state_check'((gui_operation_subject(V0, V2, V3, V4) , class_eidolons(V3, operation(V4), V5, V6) , findall(V7, member(eidolon(V8, V7, V9), V6), V10) , sort(V10, V11) , findall(V12, (member(V7, V11) , gui_operation_view(V0, V7, V12)), V1))).
gui_project_values(V0, [], V1, V2, []) :- !.
gui_project_values(V0, V1, V2, V3, V4) :- gui_initial_queries(V1, V2, V3, V5) , gui_vocabulary(V6, V7) , in_ontology(V6, V7, gui_initial_projection(V0, V5, V4)).
gui_results(V0, V1, V2) :- nonvar(V0) , (V0 = [] -> V2 = [] ; V0 = [V3 | V4] , nonvar(V3) , V3 = result(V5, V6) , atom(V5) , \+ member_eq(V5, V1) , V2 = [V5 | V7] , gui_results(V4, [V5 | V1], V7)).
gui_schema(V0, V1, V2) :- gui_definition(V0, V1, V2, V3, V4).
gui_semantic_children([], []) :- true.
gui_semantic_children([V0 | V1], [V2 | V3]) :- gui_semantic_tree(V0, V2) , gui_semantic_children(V1, V3).
gui_semantic_tree(component(V0, V1, V2, V3), component(V0, V1, V4, V5)) :- findall(property(V6, V7), (member(property(V6, V7), V2) , V6 \== appearance), V4) , gui_semantic_children(V3, V5).
gui_submission(submit(V0, V1), submit(V0, V1), question, []) :- true.
gui_submission(submit(V0, V1, operation(V2, V3)), submit(V0, V1), operation(V2, V3), V3) :- true.
gui_tree_active(component(V0, V1, V2, V3), V4) :- member(property(enabled, true), V2) , (V0 == V4 -> true ; member(V5, V3) , gui_tree_active(V5, V4)).
gui_tree_component(component(V0, V1, V2, V3), V0, V1, V2, V3) :- true.
gui_tree_component(component(V0, V1, V2, V3), V4, V5, V6, V7) :- member(V8, V3) , gui_tree_component(V8, V4, V5, V6, V7).
gui_values(V0, V1, V2) :- gui_definition(V0, V3, V4, V5, V6) , gui_initial_values(V5, V0, V4, V2) , term_digest(V2, V1).
gui_variables_bound([], V0) :- true.
gui_variables_bound([V0 | V1], V2) :- member_eq(V0, V2) , gui_variables_bound(V1, V2).
gui_vocabulary(<<"quod:gui">>, <<"\xF8\s6\xD7\s\xD4\\xBA\\xFC\Y\xD5\i\xFC\\xE3\\xBB\\x9C\f4P42\xDB\\x87\\x88\\x5\\xA0\\xFD\\xD4\\x83\\x85\5\xEB\\xEE\">>) :- true.
have_attribute(V0, name, binary) :- nonvar(V0).
have_attribute(space, interior, space_interior) :- true.
have_attribute(space, name, binary, default_from(space_name)) :- true.
have_attribute(space, dimensions, space_dimensions, default(box(q(10, <<"m">>), q(10, <<"m">>), q(10, <<"m">>)))) :- true.
have_attribute(space, owner, space_owner, default_from(space_creator_owner)) :- true.
have_attribute(space, transform, space_transform, default(transform(0, 0, 0, 0, 0, 0))) :- true.
have_attribute(space, exterior, space_exterior, default(solid)) :- true.
hide(entity_ref(V0, V1, V2), V3) :- in_ontology(V0, V1, retract(space_member(V2, V3))).
in_ontology(V0, V1, V2) :- V0 :: (current_ontology_identity(V0, V1) , V2).
inside(V0, V1, V2) :- V0 = entity_ref(V3, V4, V5) , space_assignment(V1, V6, V0) , V1 = entity_ref(V7, V8, V9) , in_ontology(V7, V8, attribute(V9, transform, V2)).
instance_of(ontology, ontology_ref(V0, V1)) :- current_ontology_identity(V0, V1).
instance_of(predicate, predicate(V0)) :- ontology_inspect(predicates(V0), V1) , member(V0, V1).
instance_of(quod : gui : form, show_as(V0, V1, V2, V3)) :- true.
instance_of(quod : gui : button, show_as_submit) :- true.
instance_of(quod : gui : form, space_create(ontology_ref(V0, V1), V2)) :- member(V2, [finite, exact, infinite]).
instance_of(quod : gui : text_box, space_name) :- true.
instance_of(quod : gui : selection, space_placement(ontology_ref(V0, V1))) :- true.
instance_of(quod : gui : viewer_pose, space_view) :- true.
instance_of(quod : gui : number_input, space_length(V0)) :- member(V0, [width, height, depth]).
instance_of(quod : gui : number_input, space_divisor(V0)) :- member(V0, [width, height, depth]).
instance_of(quod : gui : selection, space_unit) :- true.
instance_of(quod : gui : button, space_create_submit) :- true.
instance_of(quod : gui : form, space_travel_form(V0, V1, V2, V3)) :- true.
instance_of(quod : gui : button, space_travel_submit) :- true.
isa(ontology, quod : space : space) :- true.
isa(predicate, thing) :- true.
isa(V0, V0) :- '$quod_known_class'(V0).
isa(V0, V1) :- '$quod_transitive_isa'(V0, V1).
isa(space, thing) :- true.
isa(physical_space, space) :- true.
last(V0, V1) :- append(V2, [V1], V0).
local_recipe_overrides(candidate(V0, V1, V2, recipe(V3, V4, V5)), V6) :- current_ontology_identity(V7, V8) , V3 \== V7 , member(candidate(V0, V1, V2, recipe(V7, V8, V5)), V6).
material_default_limit(founding, canonical_bytes, unlimited) :- true.
material_default_limit(founding, symbols, 2048) :- true.
material_default_limit(plan, canonical_bytes, unlimited) :- true.
material_default_limit(plan, symbols, 2048) :- true.
material_default_limit(plan, operations, 1024) :- true.
material_default_limit(plan, reads, 1024) :- true.
material_default_limit(proof, heap_bytes, unlimited) :- true.
material_default_limit(proof, answer_bytes, unlimited) :- true.
material_limit(V0, V1, V2) :- material_limit_override(V0, V1, V2).
material_limit(V0, V1, V2) :- material_default_limit(V0, V1, V2) , \+ material_limit_override(V0, V1, V3).
measure_vocabulary(<<"creation-measure">>, <<"\xA6\J\xED\C\xD2\\x13\E\x8E\\xE2\\xEC\\xC7\F\xBB\\x15\\xD6\\xB1\\x83\\x97\\x98\\xA\\xAE\$A\x5\\x22\H\xEA\5\x95\Q\xE9\\x8\">>) :- true.
member_eq(V0, [V1 | V2]) :- V0 == V1 , !.
member_eq(V0, [V1 | V2]) :- member_eq(V0, V2).
menu_icon(V0, V1) :- menu_vocabulary(V2, V3) , in_ontology(V2, V3, gui_icon(V0, V1)).
menu_vocabulary(V0, V1) :- findall(ontology_ref(V2, V3), gui_vocabulary(V2, V3), V4) , (V4 = [] -> V0 = <<"quod:gui">> , quod : root :: system_ontology(V0, V1) ; V4 = [ontology_ref(V0, V1)]).
modelling_vocabulary(<<"creation-modelling">>, <<"K2\xC1\\xE2\7\x9D\\x95\\xDA\\xAB\?zc&<\xBE\\x4\\xAB\\x1A\[3Kr\xA6\\x94\\xF7\\xBC\o\x93\\xDF\\xD6\DZ">>) :- true.
most_specific_classes(V0, V1, V2) :- term_variables(V0 - V1, []) , sort(V1, V3) , findall(V4, (member(V4, V3) , member(V5, V0) , isa(V5, V4)), V6) , sort(V6, V7) , findall(V4, (member(V4, V7) , \+ '$quod_stricter_class'(V4, V7)), V2).
no_follow(in_ontology / 3) :- true.
no_follow(unique_solution / 1) :- true.
no_follow(term_hex_digest / 2) :- true.
no_follow(menu_icon / 2) :- true.
no_follow(client_entity_scene / 3) :- true.
no_follow(operation_authorized / 2) :- true.
no_follow(operation_policy / 3) :- true.
no_follow(operation_classes / 2) :- true.
no_follow(operation_requirements / 4) :- true.
no_follow(operation_check / 4) :- true.
no_follow('$quod_class_predicate' / 3) :- true.
no_follow(operation_grant / 5) :- true.
no_follow(operation_grants / 2) :- true.
no_follow(operation_override / 3) :- true.
no_follow(permission_grant / 1) :- true.
no_follow(permission_allows / 4) :- true.
no_follow(set_instance_permission / 3) :- true.
no_follow(instance_permission / 3) :- true.
no_follow(permission_administrator / 2) :- true.
no_follow(isa / 2) :- true.
no_follow('$quod_owner_name' / 3) :- true.
no_follow('$quod_name_tail' / 4) :- true.
no_follow('$quod_name_normalize' / 2) :- true.
no_follow('$quod_name_join' / 3) :- true.
no_follow('$quod_qualified_class' / 3) :- true.
no_follow('$quod_stricter_class' / 2) :- true.
no_follow('$quod_known_class' / 1) :- true.
no_follow('$quod_declared_class' / 1) :- true.
no_follow('$quod_transitive_isa' / 2) :- true.
no_follow('$quod_isa_requires_closure' / 2) :- true.
no_follow('$quod_isa_path' / 3) :- true.
no_follow('$quod_direct_isa' / 2) :- true.
no_follow('$quod_isa_semantics' / 1) :- true.
no_follow(most_specific_classes / 3) :- true.
no_follow(class_ancestors / 2) :- true.
no_follow(class_below / 3) :- true.
no_follow(member_eq / 2) :- true.
no_follow(with_build_plan / 2) :- true.
no_follow('$quod_assert_instance' / 3) :- true.
no_follow('$quod_membership_clause' / 3) :- true.
no_follow(attribute_value / 2) :- true.
no_follow(nonempty_binary / 1) :- true.
no_follow(boolean / 1) :- true.
no_follow(positive_integer / 1) :- true.
no_follow(nonnegative_integer / 1) :- true.
no_follow(constructor / 3) :- true.
no_follow(constructor_order / 2) :- true.
no_follow('$quod_build_inputs' / 1) :- true.
no_follow('$quod_build_entries' / 2) :- true.
no_follow('$quod_constructor_plan' / 5) :- true.
no_follow('$quod_constructor_description' / 5) :- true.
no_follow('$quod_constructor_graph' / 5) :- true.
no_follow('$quod_constructor_metadata' / 3) :- true.
no_follow('$quod_qualified_classes' / 3) :- true.
no_follow('$quod_constructor_parents' / 4) :- true.
no_follow('$quod_parent_list' / 1) :- true.
no_follow('$quod_constructor_branches' / 5) :- true.
no_follow('$quod_parent_edges' / 2) :- true.
no_follow('$quod_constructor_sort' / 4) :- true.
no_follow('$quod_attribute_declaration' / 4) :- true.
no_follow('$quod_initial_attributes' / 6) :- true.
no_follow('$quod_attribute_default' / 4) :- true.
no_follow('$quod_default_value' / 4) :- true.
no_follow('$quod_attribute_types' / 2) :- true.
no_follow('$quod_initial_attribute_writes' / 2) :- true.
no_follow(gui_schema / 3) :- true.
no_follow(gui_definition / 5) :- true.
no_follow(gui_definition / 6) :- true.
no_follow(gui_compile / 6) :- true.
no_follow(gui_submission / 4) :- true.
no_follow(gui_results / 3) :- true.
no_follow(gui_bind_values / 5) :- true.
no_follow(gui_component_tree / 5) :- true.
no_follow(gui_class_basis / 2) :- true.
no_follow(gui_component_children / 5) :- true.
no_follow(gui_tree_component / 5) :- true.
no_follow(gui_field_declarations / 4) :- true.
no_follow(gui_variables_bound / 2) :- true.
no_follow(gui_values / 3) :- true.
no_follow(gui_initial_values / 4) :- true.
no_follow(gui_project_values / 5) :- true.
no_follow(gui_initial_queries / 4) :- true.
no_follow(gui_fixed_values / 4) :- true.
no_follow(gui_bind / 5) :- true.
no_follow(gui_bind_fields / 4) :- true.
no_follow(gui_match_fixed / 2) :- true.
no_follow(gui_tree_active / 2) :- true.
no_follow(gui_local_id / 1) :- true.
no_follow(gui_semantic_tree / 2) :- true.
no_follow(gui_semantic_children / 2) :- true.
no_follow(gui_operations / 2) :- true.
no_follow(gui_operation / 6) :- true.
no_follow(gui_operation_view / 3) :- true.
no_follow(gui_operation_definition / 8) :- true.
no_follow(gui_operation_form / 5) :- true.
no_follow(gui_operation_subject / 4) :- true.
no_follow(gui_operation_bind / 7) :- true.
no_follow(gui_operation_binding / 7) :- true.
no_follow(gui_operation_guard / 7) :- true.
no_follow(gui_operation_availability / 3) :- true.
no_follow(gui_menu_source / 2) :- true.
no_follow(gui_menu_subject / 2) :- true.
no_follow(gui_menu_item / 3) :- true.
no_follow(gui_operation_caption / 6) :- true.
no_follow(gui_form_caption / 5) :- true.
no_follow(gui_menu_image / 2) :- true.
no_follow(physics_valid_body / 6) :- true.
no_follow(physics_world_position / 1) :- true.
no_follow(physics_world_pose / 1) :- true.
no_follow(physics_frame_path / 1) :- true.
no_follow(physics_local_pose / 1) :- true.
no_follow(physics_valid_pose / 2) :- true.
no_follow(physics_valid_shape / 3) :- true.
no_follow(physics_valid_solid / 2) :- true.
no_follow(physics_dimension / 2) :- true.
no_follow(physics_valid_parts / 2) :- true.
no_follow(physics_valid_vertices / 2) :- true.
no_follow(physics_valid_triangles / 2) :- true.
no_follow(physics_vertex_index / 2) :- true.
no_follow(physics_native_scalar_limit / 1) :- true.
no_follow(physics_positive_scalar / 1) :- true.
no_follow(physics_milli_integer / 1) :- true.
no_follow(physics_coordinate / 2) :- true.
no_follow(physics_body_vector / 2) :- true.
no_follow(physics_body_coordinate / 2) :- true.
nonempty_binary(V0) :- binary(V0) , V0 \== <<"">>.
nonnegative_integer(V0) :- integer(V0) , V0 >= 0.
not_shown_in(V0, V1) :- \+ shown_in(V0, V1).
ontology_acl_indicator(can_invoke / 4) :- true.
ontology_acl_indicator(can_join / 3) :- true.
ontology_acl_indicator(acl_sovereign / 1) :- true.
ontology_inspect(V0, V1) :- current_ontology_identity(V2, V3) , quod : root :: system_ontology(<<"quod:gui">>, V4) , in_ontology(<<"quod:gui">>, V4, prolog_inspect(ontology_ref(V2, V3), V0, V1)).
ontology_predicate(V0, V1) :- ontology_inspect(predicate(V0), V2) , member(predicate(V0, V1), V2).
ontology_presentation_mode([], read_only) :- true.
ontology_presentation_mode([V0], V0) :- term_variables(V0, []) , member(V0, [read_only, editable]).
operation_authorized(V0, V1) :- term_variables(V0 - V1, []) , (V0 = class(V2) ; V0 = instance(V3)) , (V0 = instance(V4) , '$quod_construction'(V4, V5, V6) , instance_of(V5, V4) -> V7 = construction(V5, V4, V6) ; V7 = V0) , current_principal(V8) , '$quod_committed_check'(operation_policy(V8, V7, V1)).
operation_check(V0, V1, V2, V3) :- '$quod_owner_name'(V0, V4, V5) -> V6 =.. [V5, V1, V2, V3] , V4 :: V6 ; atom(V0) , V6 =.. [V0, V1, V2, V3] , call(V6).
operation_classes(class(V0), V1) :- findall(V2, (V2 = V0 ; isa(V0, V2)), V3) , sort(V3, V1).
operation_classes(construction(V0, V1, V2), V3) :- \+ instance_of(V4, V1) , operation_classes(class(V0), V3).
operation_classes(instance(V0), V1) :- findall(V2, (instance_of(V3, V0) , (V2 = V3 ; isa(V3, V2))), V4) , sort(V4, V1).
operation_grant(V0, V1, set_permission(V2, V3), set_permission, V4) :- ! , V1 = instance(V5) , atom(V2) , V2 \== set_permission , (V3 == inherit ; permission_grant(V3)) , (findall(V6, attribute(V5, owner, V6), V7) , term_variables(V7, []) , sort(V7, [V0]) ; permission_administrator(V5, V0)).
operation_grant(V0, V1, V2, V3, V4) :- operation_override(V1, V3, V5) , (V5 == [] -> findall(candidate(V6, V7), (member(V6, V4) , class_permission(V6, V3, V7)), V8) , findall(V6, member(candidate(V6, V9), V8), V10) , findall(candidate(V6, V7), (member(candidate(V6, V7), V8) , \+ '$quod_stricter_class'(V6, V10)), V11) ; findall(candidate(local, V7), member(V7, V5), V11)) , term_variables(V11, []) , operation_grants(V11, V12) , sort(V12, [V7]) , permission_allows(V7, V0, V1, V2).
operation_grants([], []) :- true.
operation_grants([candidate(V0, V1) | V2], [V3 | V4]) :- permission_grant(V1) , (V1 = check(V5) -> '$quod_class_predicate'(V0, V5, V6) , V3 = check(V6) ; V3 = V1) , operation_grants(V2, V4).
operation_override(class(V0), V1, []) :- true.
operation_override(construction(V0, V1, V2), V3, []) :- true.
operation_override(instance(V0), V1, V2) :- findall(V3, instance_permission(V0, V1, V3), V2).
operation_policy(V0, V1, V2) :- term_variables(V0 - V1 - V2, []) , functor(V2, V3, V4) , atom(V3) , operation_classes(V1, V5) , V5 \== [] , term_variables(V5, []) , findall(requirement(V6, V7), (member(V6, V5) , class_requirement(V6, V3, V7)), V8) , operation_requirements(V8, V0, V1, V2) , operation_grant(V0, V1, V2, V3, V5).
operation_requirements([], V0, V1, V2) :- true.
operation_requirements([requirement(V0, V1) | V2], V3, V4, V5) :- atom(V1) , '$quod_class_predicate'(V0, V1, V6) , operation_check(V6, V3, V4, V5) , operation_requirements(V2, V3, V4, V5).
peer_admitted(<<";\xCB\\xA\Kc\xE6\\x9C\\xEB\n@\x1A\j\xE1\\x80\dgC\xED\\xED\\xE5\\x91\\xA8\\xC3\L\xC8\2Gb\xE0\\x1F\on">>, undefined, undefined, <<";\xCB\\xA\Kc\xE6\\x9C\\xEB\n@\x1A\j\xE1\\x80\dgC\xED\\xED\\xE5\\x91\\xA8\\xC3\L\xC8\2Gb\xE0\\x1F\on">>) :- true.
perm([], []) :- true.
perm([V0 | V1], V2) :- perm(V1, V3) , insert(V3, V0, V2).
permission_allows(allow, V0, V1, V2) :- true.
permission_allows(check(V0), V1, V2, V3) :- operation_check(V0, V1, V2, V3).
permission_grant(allow) :- true.
permission_grant(deny) :- true.
permission_grant(check(V0)) :- atom(V0).
phrase(V0, V1) :- phrase(V0, V1, []).
physics_body_coordinate(V0, V1) :- physics_milli_integer(V0) , (physics_coordinate(V0, V1) -> true ; fail_with_reason(coordinate_allowance(V1))).
physics_body_vector(vector(V0, V1, V2), V3) :- physics_body_coordinate(V0, V3) , physics_body_coordinate(V1, V3) , physics_body_coordinate(V2, V3).
physics_coordinate(V0, V1) :- physics_milli_integer(V0) , V0 >= - V1 , V0 =< V1.
physics_dimension(V0, V1) :- physics_body_coordinate(V0, V1) , V0 > 0.
physics_frame_path([]) :- true.
physics_frame_path([frame(entity_ref(V0, V1, V2), V3, V4) | V5]) :- binary(V0) , binary(V1) , term_variables(V2, []) , integer(V3) , V3 > 0 , binary_codes(V4, V6) , length(V6, 32) , physics_frame_path(V5).
physics_local_pose(transform(V0, V1, V2, V3, V4, V5)) :- physics_world_position(vector(V0, V1, V2)) , physics_world_position(vector(V3, V4, V5)).
physics_local_pose(V0) :- V0 \= framed(V1, V2) , physics_world_pose(V0).
physics_milli_integer(V0) :- integer(V0) , physics_native_scalar_limit(V1) , V0 >= - V1 , V0 =< V1.
physics_native_scalar_limit(179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368) :- true.
physics_positive_scalar(V0) :- integer(V0) , V0 > 0 , physics_native_scalar_limit(V1) , V0 =< V1.
physics_valid_body(V0, V1, V2, V3, V4, V5) :- term_variables([V0, V1, V2, V3, V4, V5], []) , integer(V0) , V0 >= 0 , V0 < 18446744073709551616 , member(V1, [fixed, dynamic, controlled]) , physics_positive_scalar(V4) , integer(V5) , V5 > 0 , physics_world_pose(V2) , physics_valid_shape(V1, V3, V5).
physics_valid_parts([], V0) :- true.
physics_valid_parts([part(V0, V1) | V2], V3) :- physics_valid_pose(V0, V3) , physics_valid_solid(V1, V3) , physics_valid_parts(V2, V3).
physics_valid_pose(vector(V0, V1, V2), V3) :- physics_body_vector(vector(V0, V1, V2), V3).
physics_valid_pose(pose(V0, rotation(V1, V2, V3)), V4) :- physics_body_vector(V0, V4) , physics_milli_integer(V1) , physics_milli_integer(V2) , physics_milli_integer(V3).
physics_valid_shape(V0, V1, V2) :- physics_valid_solid(V1, V2).
physics_valid_shape(V0, parts(V1), V2) :- V1 = [V3 | V4] , physics_valid_parts(V1, V2).
physics_valid_shape(fixed, surface(V0, V1), V2) :- V0 = [V3, V4, V5 | V6] , physics_valid_vertices(V0, V2) , length(V0, V7) , V1 = [V8 | V9] , physics_valid_triangles(V1, V7).
physics_valid_solid(box(V0, V1, V2), V3) :- physics_dimension(V0, V3) , physics_dimension(V1, V3) , physics_dimension(V2, V3).
physics_valid_solid(ball(V0), V1) :- physics_dimension(V0, V1).
physics_valid_solid(capsule(V0, V1), V2) :- physics_dimension(V0, V2) , physics_dimension(V1, V2).
physics_valid_solid(convex(V0), V1) :- V0 = [V2, V3, V4, V5 | V6] , physics_valid_vertices(V0, V1).
physics_valid_triangles([], V0) :- true.
physics_valid_triangles([triangle(V0, V1, V2) | V3], V4) :- physics_vertex_index(V0, V4) , physics_vertex_index(V1, V4) , physics_vertex_index(V2, V4) , V0 \= V1 , V1 \= V2 , V0 \= V2 , physics_valid_triangles(V3, V4).
physics_valid_vertices([], V0) :- true.
physics_valid_vertices([V0 | V1], V2) :- physics_body_vector(V0, V2) , physics_valid_vertices(V1, V2).
physics_vertex_index(V0, V1) :- integer(V0) , V0 >= 0 , V0 < 4294967296 , V0 < V1.
physics_world_pose(vector(V0, V1, V2)) :- physics_world_position(vector(V0, V1, V2)).
physics_world_pose(pose(V0, rotation(V1, V2, V3))) :- physics_world_position(V0) , physics_milli_integer(V1) , physics_milli_integer(V2) , physics_milli_integer(V3).
physics_world_pose(framed(V0, V1)) :- V0 = [V2 | V3] , physics_frame_path(V0) , physics_local_pose(V1).
physics_world_position(vector(V0, V1, V2)) :- integer(V0) , integer(V1) , integer(V2).
place(V0, V1, V2) :- term_variables([V0, V1, V2], []) , V0 \== V1 , space_instance(V0, space) , space_assignment(V1, V3, none) , V1 = entity_ref(V4, V5, V6) , V0 = entity_ref(V7, V8, V9) , V10 is V3 + 1 , in_ontology(V4, V5, (instance_of(V11, V6) , (V3 = 0 -> true ; retract(space_assignment_state(V6, V3, none))) , findall(V12, attribute(V6, transform, V12), V13) , (V13 = [] -> true ; V13 = [V12] , retract(attribute(V6, transform, V12))) , assertz(attribute(V6, transform, V2)) , assertz(space_assignment_state(V6, V10, V0)))) , space_change_physics(V0, V1, admitted) , in_ontology(V7, V8, (\+ space_placement(V9, V1, V14) , assertz(space_placement(V9, V1, V10)))).
placement_pose(V0, V1) :- nonvar(V1) -> space_transform(V1) ; quod : user :: personal_agent(V2, V3) , V2 = agent_instance_ref(V4, V5, V6) , space_location(entity_ref(V4, V5, V6), placed(V0, transform(V7, V8, V9, V10, V11, V12))) , space_near(V13, V14) , V15 is V9 - V14 , space_free_pose(V0, transform(V7, V8, V15, V10, V11, V12), 1000, 0, V1).
positive_integer(V0) :- integer(V0) , V0 > 0.
prolog_introspection(predicates, V0) :- prolog_introspection(predicates(V1), V0).
prolog_introspection(predicates(V0), V1) :- findall(V0, current_predicate(V0), V2) , sort(V2, V1).
prolog_introspection(predicate(V0), V1) :- prolog_introspection(predicates, V2) , (term_variables(V0, []) -> (once(append(V3, [V0 | V4], V2)) -> length(V3, V5) , V1 = [predicate(V0, V5)] ; V1 = []) ; findall(predicate(V0, V5), (append(V3, [V0 | V6], V2) , length(V3, V5)), V1)).
prolog_introspection(source(V0), V1) :- '$quod_predicate_source'(V0, V1).
prolog_introspection(chunks(V0), V1) :- '$quod_source_chunk'(all, V0, V1).
prolog_introspection(identity, ontology_ref(V0, V1)) :- current_ontology_identity(V0, V1).
prolog_introspection(workbench, content(V0, V1, V2)) :- findall(isa(V3, V4), (clause(isa(V3, V4), true) , atom(V3) , atom(V4)), V5) , sort(V5, V0) , findall(instance_of(V3, V6), (clause(instance_of(V3, V6), true) , atom(V3) , term_variables(V6, [])), V7) , sort(V7, V1) , findall(attribute(V6, V8, V9), (clause(attribute(V6, V8, V9), true) , term_variables([V6, V8, V9], [])), V10) , sort(V10, V2).
prolog_introspection(policy_chunks(V0), V1) :- findall(V2, ontology_acl_indicator(V2), V3) , '$quod_source_chunk'(predicates(V3), V0, V1).
prolog_introspection(interface_chunks(V0), V1) :- '$quod_source_chunk'(predicates([ontology_interface / 2]), V0, V1).
prolog_introspection(route_chunks(V0), V1) :- '$quod_ontology_routes'(V2) , '$quod_source_chunk'(terms(V2), V0, V1).
prolog_introspection(presentation, V0) :- findall(V1, (current_predicate(ontology_source_mode / 1) , ontology_source_mode(V1)), V2) , sort(V2, V3) , ontology_presentation_mode(V3, V0).
proof_draw(V0, V1, V2) :- '$quod_draw'(V0, V1, V2).
public_source_query(current_ontology_identity(V0, V1)) :- true.
public_source_query(instance_of(ontology, ontology_ref(V0, V1))) :- true.
public_source_query(entity_eidolons(V0, V1)) :- true.
public_source_query(class_eidolons(V0, V1)) :- true.
public_source_query(class_eidolons(V0, V1, V2, V3)) :- true.
public_source_query(entity_eidolons(V0, V1, V2, V3)) :- true.
public_source_query(client_eidolon(V0, V1, V2)) :- true.
public_source_query(entity_scene(V0, V1, V2)) :- true.
public_source_query(client_entity_scene(V0, V1, V2)) :- true.
public_source_query(viewer_eidolon(V0, V1, V2, V3)) :- true.
public_source_query(viewer_scene(V0, V1, V2)) :- true.
public_source_query(eidolon_seen(V0, V1, V2, V3)) :- true.
public_source_query(client_menu(V0, V1)) :- true.
public_source_query(gui_menu_source(V0, V1)) :- true.
resolve_goal(V0, V1) :- '$quod_state_check'(V0) , !.
resolve_goal(V0, V1) :- \+ member_eq(V0, V1) , action(V2, V3, V0) , '$quod_action_shape'(V2, V3, V0) , '$quod_action_candidate'(V2, V3, V0, [V0 | V1]) , !.
run_declared_action(V0) :- action(V0, V1, V2) , '$quod_action_shape'(V0, V1, V2) , run_declared_candidate(V0, V1, V2).
run_declared_candidate(V0, V1, V2) :- '$quod_state_check'(V2) , !.
run_declared_candidate(V0, V1, V2) :- '$quod_action_candidate'(V0, V1, V2, [V2]).
run_transition([V0 | V1]) :- ! , call(V0) , run_transitions(V1).
run_transition(V0) :- call(V0).
run_transitions([]) :- true.
run_transitions([V0 | V1]) :- call(V0) , run_transitions(V1).
satisfy_prerequisites([], V0) :- true.
satisfy_prerequisites([goal(V0) | V1], V2) :- ! , goal(V0, V2) , satisfy_prerequisites(V1, V2).
satisfy_prerequisites([V0 :: goal(V1) | V2], V3) :- ! , V0 :: goal(V1, V3) , satisfy_prerequisites(V2, V3).
satisfy_prerequisites([V0 | V1], V2) :- '$quod_state_check'(V0) , satisfy_prerequisites(V1, V2).
scene_vocabulary(V0, V1) :- findall(ontology_ref(V2, V3), modelling_vocabulary(V2, V3), V4) , (V4 = [] -> quod : root :: system_ontology(<<"quod:gui">>, V1) , V0 = <<"quod:gui">> ; V4 = [ontology_ref(V0, V1)]).
set_instance_permission(V0, V1, V2) :- operation_authorized(instance(V0), set_permission(V1, V2)) , findall(V3, retract(instance_permission(V0, V1, V3)), V4) , (V2 == inherit -> true ; assertz(instance_permission(V0, V1, V2))).
show(entity_ref(V0, V1, V2), V3) :- in_ontology(V0, V1, assertz(space_member(V2, V3))).
shown_in(entity_ref(V0, V1, V2), V3) :- in_ontology(V0, V1, space_member(V2, V3)).
space_assignment(entity_ref(V0, V1, V2), V3, V4) :- in_ontology(V0, V1, findall(assignment(V5, V6), space_assignment_state(V2, V5, V6), V7)) , (V7 = [] -> V8 = 0 , V9 = none ; V7 = [assignment(V8, V9)] -> true ; fail_with_reason(ambiguous_space_assignment(V2))) , V3 = V8 , V4 = V9.
space_authorized(V0, V1, V2, V3) :- V0 = entity_ref(V4, V5, V6) , space_subject(V0, V7) , V8 =.. [V1, V0, V2, V3] , in_ontology(V4, V5, operation_authorized(V7, V8)).
space_authorized_representation(entity_ref(V0, V1, V2), V3, V4, V5, V6, V7, V8) :- in_ontology(V0, V1, operation_authorized(instance(V2), space_represent(V3, V4, V5, V6, V7, V8))).
space_boundary_parts(V0, V1, V2, V3, V4) :- V0 = entity_ref(V5, V6, V7) , (in_ontology(V5, V6, eidolon_seen(V7, interior, V8, [eidolon(interior, V9, V10)])) , space_entity_model([V10], subject(ontology_ref(V5, V6), V7), V11) -> term_hex_digest([interior(V0), boundary], V12) , in_ontology(V1, V2, place_model(V12, transform(0, 0, 0, 0, 0, 0), depicts(V5, V6, V7), V11, V13)) , append(V3, V13, V4) ; V4 = V3).
space_change_physics(V0, V1, V2) :- V0 = entity_ref(V3, V4, V5) , ((space_instance(V0, physical_space) ; space_simulation_domain(V0, V6, V7, V8) ; V2 == withdrawn , in_ontology(V3, V4, physics_body_definition(V5, V9, V10, V11, V12, live(V1, V13, V14, V15)))) -> (space_physical_change(V0, V1, V2) -> true ; fail_with_reason(space_physical_change_refused(V0, V2))) ; true).
space_contains(entity_ref(V0, V1, V2), V3) :- in_ontology(V0, V1, (space_member(V2, V3) ; space_placement(V2, V3, V4))).
space_contents_projection(V0, exposure(V1, V2, V3)) :- space_instance(V0, space) , V1 = V0 , findall(V4, space_contains(V0, V4), V5) , sort(V5, V6) , space_exposed_subjects(V6, V0, V3) , variant_digest(contents(V1, V3), V2).
space_creation_recipe(create, space_create, finite) :- true.
space_creation_recipe(create_exact, space_create_exact, exact) :- true.
space_creation_recipe(create_infinite, space_create_infinite, infinite) :- true.
space_creator_owner(V0, V1) :- quod : user :: personal_agent_owner(V1).
space_dimensions(infinite) :- true.
space_dimensions(box(V0, V1, V2)) :- unique_solution(measure_vocabulary(V3, V4)) , space_length(V3, V4, V0) , space_length(V3, V4, V1) , space_length(V3, V4, V2).
space_eidolon_status(V0, [part(<<"eidolon-status">>, group, transform(0, 0, 0, 0, 0, 0), no_surface, label(V0, <<"above">>), depicts_nothing)]) :- true.
space_entity_model([recipe(V0, V1, V2)], V3, V4) :- in_ontology(V0, V1, eidolon(V2, V3, V4)).
space_entity_model([], V0, V1) :- space_eidolon_status(<<"No matching eidolon">>, V1).
space_entity_model([V0, V1 | V2], V3, V4) :- space_eidolon_status(<<"Choose an eidolon">>, V4).
space_exposed_subjects([], V0, []) :- true.
space_exposed_subjects([V0 | V1], V2, [exposed(V0, V3, V4) | V5]) :- V0 = entity_ref(V6, V7, V8) , term_variables(V0, []) , V2 = entity_ref(V9, V10, V11) , in_ontology(V9, V10, findall(V12, space_placement(V11, V0, V12), V13)) , (V13 = [] -> V3 = display ; V13 = [V14] , V3 = placement(V14)) , space_subject_binding(V2, V0, V15) , (V15 = body_pose(V16, V17) , space_simulation_domain(V2, V18, V19, V20) -> V4 = in_frame(V18, V15) ; V4 = V15) , space_exposed_subjects(V1, V2, V5).
space_exposure_projection(exposure(V0, V1, V2), V3, V4, V5) :- member(V3, [playing, edition]) , V0 = entity_ref(V6, V7, V8) , unique_solution(scene_vocabulary(V9, V10)) , (space_simulation_domain(V0, V11, V12, V13) -> true ; V11 = none) , space_scene_parts(V2, V3, [interior(V0)], [representation(V0, contents(V3))], none, role(physical, V11), V14, V5) , space_boundary_parts(V0, V9, V10, V14, V15) , in_ontology(V9, V10, model(V15, V4)).
space_extent(subject(ontology_ref(V0, V1), V2), V3, V4, V5) :- in_ontology(V0, V1, attribute(V2, dimensions, box(V6, V7, V8))) , unique_solution(measure_vocabulary(V9, V10)) , space_millimetres(V9, V10, V6, V3) , space_millimetres(V9, V10, V7, V4) , space_millimetres(V9, V10, V8, V5).
space_exterior(V0) :- class_eidolon(space, playing, V0, V1).
space_form_lengths(finite, [field(space_length(width), V0), field(space_length(height), V1), field(space_length(depth), V2), field(space_unit, V3)], box(q(V0, V3), q(V1, V3), q(V2, V3))) :- true.
space_form_lengths(exact, [field(space_length(width), V0), field(space_divisor(width), V1), field(space_length(height), V2), field(space_divisor(height), V3), field(space_length(depth), V4), field(space_divisor(depth), V5), field(space_unit, V6)], box(q(V0 / V1, V6), q(V2 / V3, V6), q(V4 / V5, V6))) :- true.
space_form_lengths(infinite, [], infinite) :- true.
space_form_placement(V0, V1, V2, V3) :- (V1 = unplaced -> goal(unplaced(V0)) ; V1 = at(V4, V5) -> goal(inside(V4, V0, V5)) ; V1 = near_agent , quod : user :: personal_agent(agent_instance_ref(V6, V7, V8), V9) , space_location(entity_ref(V6, V7, V8), V10) , (V10 = unplaced -> goal(unplaced(V0)) ; V10 = placed(V4, transform(V11, V12, V13, V14, V15, V16)) , (V2 == none -> goal(inside(V4, V0, V17)) ; space_view_pose(V4, V12, V2, V5) , goal(inside(V4, V0, V5))))) , space_location(V0, V3).
space_free_place(V0, V1, V2, V3, V4, V5, V6, V7, V8, V9) :- V10 is (V0 + 1) // 2 * (V6 * 3 // 2) , (V0 mod 2 =:= 1 -> V11 = 1 ; V11 = - 1) , V12 is V1 + V11 * V10 * V4 // 1000 , V13 is V3 + V11 * V10 * V5 // 1000 , (member(transform(V14, V15, V16, V17, V18, V19), V7) , abs(V14 - V12) < V6 , abs(V15 - V2) < V6 , abs(V16 - V13) < V6 -> V20 is V0 + 1 , space_free_place(V20, V1, V2, V3, V4, V5, V6, V7, V8, V9) ; V8 = V12 , V9 = V13).
space_free_pose(V0, transform(V1, V2, V3, V4, V5, V6), V7, V8, transform(V9, V2, V10, V4, V5, V6)) :- space_near(V11, V12) , V0 = entity_ref(V13, V14, V15) , in_ontology(V13, V14, findall(V16, space_placement(V15, V16, V17), V18)) , findall(V19, (member(V16, V18) , space_location(V16, placed(V0, V19))), V20) , space_free_place(0, V1, V2, V3, V7, V8, V11, V20, V9, V10).
space_instance(entity_ref(V0, V1, V2), V3) :- in_ontology(V0, V1, findall(instance(V2, V3), (nonvar(V2) -> instance_of(V4, V2) , isa(V4, quod : space : V3) ; isa(V4, quod : space : V3) , instance_of(V4, V2)), V5)) , sort(V5, V6) , member(instance(V2, V3), V6).
space_interior(V0) :- class_eidolon(space, interior, V0, V1).
space_leave_to(V0, V1) :- space_assignment(V0, V2, V3) , (V3 == none -> V1 = unplaced ; space_location(V0, placed(V3, transform(V4, V5, V6, V7, V8, V9))) , space_near(V10, V11) , V12 is V6 + V11 , V1 = parent(V3, transform(V4, V5, V12, V7, V8, V9))).
space_leaving(unplaced) :- true.
space_leaving(parent(V0, V1)) :- true.
space_length(V0, V1, q(V2, V3)) :- binary(V3) , in_ontology(V0, V1, convert(V2, V3, <<"m">>, V4)) , (integer(V4) -> V4 > 0 ; V4 = V5 / V6 , integer(V5) , integer(V6) , V5 > 0 , V6 > 0).
space_length_codes(q(V0, V1), V2) :- '$quod_program_source'([V0], V3) , binary_codes(V3, V4) , append(V5, [46, 10], V4) , findall(V6, (member(V6, V5) , V6 =\= 32), V7) , binary_codes(V1, V8) , append(V7, [32 | V8], V2).
space_location(V0, V1) :- V0 = entity_ref(V2, V3, V4) , in_ontology(V2, V3, instance_of(V5, V4)) , space_assignment(V0, V6, V7) , (V7 == none -> V1 = unplaced ; in_ontology(V2, V3, unique_solution(attribute(V4, transform, V8))) , V1 = placed(V7, V8)).
space_member(ontology_ref(V0, V1), entity_ref(V0, V1, predicate(V2))) :- current_ontology_identity(V0, V1) , instance_of(predicate, predicate(V2)).
space_menu_action(item(V0, V1, V2, V3, V4), item(V0, V1, V2, V3, [slot(5), confirm(true) | V4])) :- V0 = choice(V5, eidolon(operation(instance), leave, V6)) , !.
space_menu_action(V0, V0) :- V0 = item(choice(V1, eidolon(operation(V2), V3, V4)), V5, V6, V7, V8).
space_menu_destination(V0, V1, V2, item(V3, V4, V5, V6, V7)) :- space_contains(entity_ref(V1, V2, V0), entity_ref(V8, V9, V10)) , entity_ref(V8, V9, V10) \== entity_ref(V1, V2, V0) , space_instance(entity_ref(V8, V9, V10), space) , in_ontology(V8, V9, gui_menu_source(V10, menu_source(V11, V12))) , member(item(V3, V13, V5, V6, V7), V12) , V3 = choice(V14, eidolon(operation(instance), enter, V15)) , (binary(V11) , V11 \== <<"">> -> V4 = V11 ; V4 = V13).
space_millimetres(V0, V1, q(V2, V3), V4) :- in_ontology(V0, V1, convert(V2, V3, <<"mm">>, V4)).
space_name(V0, V1) :- quod : names :: draw(<<"place">>, V0, V1).
space_near(V0, V1) :- unique_solution(scene_vocabulary(V2, V3)) , in_ontology(V2, V3, marker_size(V0)) , V1 is 2000 + V0 // 2.
space_occurrence_model(contents(exposure(V0, V1, V2)), V3, V4, V5, V6, V7, V8, V9, V10, V0, V2, V11) :- V12 = representation(V0, contents(V3)) , (member_eq(V12, V5) -> V11 = cycle , V9 = [] , V10 = [] , space_eidolon_status(<<"Contents cycle">>, V8) ; V11 = contents , V8 = [] , space_scene_parts(V2, V3, V4, [V12 | V5], V6, V7, V9, V10)).
space_occurrence_model(V0, V1, V2, V3, V4, V5, V0, [], [], none, [], model) :- V0 \= contents(V6).
space_owner(agent_instance_ref(V0, V1, V2)) :- binary(V0) , binary(V1) , term_variables(V2, []).
space_parent_pose(none, V0, V0) :- true.
space_parent_pose(V0, V1, relative(V0, V1)) :- V0 \== none.
space_physical_change(entity_ref(V0, V1, V2), V3, V4) :- in_ontology(V0, V1, space_physical_change(V2, V3, V4)).
space_projection(V0, V1, scene(V2, V3)) :- space_projection(V0, V1, V2, V3).
space_projection(V0, V1, V2, V3) :- space_instance(V0, space) , V0 = entity_ref(V4, V5, V6) , in_ontology(V4, V5, entity_eidolons(V6, V1, contents, V7)) , findall(V8, member(eidolon(V1, contents, V8), V7), V9) , space_entity_model(V9, subject(ontology_ref(V4, V5), V6), contents(V10)) , V10 = exposure(V0, V11, V12) , space_exposure_projection(V10, V1, V2, V3).
space_query(isa(V0, V1)) :- true.
space_query(have_attribute(V0, V1, V2, V3)) :- true.
space_query(have_attribute(V0, V1, V2)) :- true.
space_query('$quod_constructor_metadata'(V0, V1, V2)) :- true.
space_query(attribute_value(V0, V1)) :- member(V0, [binary, space_dimensions, space_owner, space_transform, space_exterior, space_interior]).
space_query(class_permission(V0, V1, V2)) :- true.
space_query(class_requirement(V0, V1, V2)) :- true.
space_query(class_eidolon(V0, V1, V2, V3)) :- true.
space_query(eidolon(V0, V1, V2)) :- true.
space_query(gui_definition(V0, V1, V2, V3, V4, V5)) :- true.
space_query(gui_initial_values(V0, V1, V2, V3)) :- true.
space_query(gui_bind_values(V0, V1, V2, V3, V4)) :- true.
space_query(gui_form_caption(V0, V1, V2, V3, V4)) :- true.
space_query(space_instance(V0, V1)) :- true.
space_query(space_assignment(V0, V1, V2)) :- true.
space_query(space_location(V0, V1)) :- true.
space_query(space_contains(V0, V1)) :- true.
space_query(space_projection(V0, V1, V2)) :- true.
space_query(space_contents_projection(V0, V1)) :- true.
space_query(world_view(V0, V1, V2)) :- true.
space_query(space_exposure_projection(V0, V1, V2, V3)) :- true.
space_query(space_simulation_domain(V0, V1, V2, V3)) :- true.
space_query(space_creator_owner(V0, V1)) :- true.
space_query(space_name(V0, V1)) :- true.
space_query(space_dimensions(V0)) :- true.
space_query(space_owner(V0)) :- true.
space_query(space_transform(V0)) :- true.
space_query(space_exterior(V0)) :- true.
space_query(space_interior(V0)) :- true.
space_query(goal(inside(V0, V1, V2))) :- true.
space_query(goal(unplaced(V0))) :- true.
space_query(goal(shown_in(V0, V1))) :- true.
space_query(goal(not_shown_in(V0, V1))) :- true.
space_query(space_represent(V0, V1, V2, V3, V4, V5, V6)) :- true.
space_query(space_form_placement(V0, V1, V2, V3)) :- true.
space_query(V0) :- public_source_query(V0).
space_removal_allowed(V0, V1, V2) :- space_authorized(V0, space_remove, V1, V2) -> true ; space_authorized(V1, space_leave, V0, V2).
space_represent(V0, V1, V2, V3, V4, V5, V6) :- term_variables([V0, V1, V2, V3, V4, V5, V6], []) , V0 = entity_ref(V7, V8, V9) , transaction((space_instance(V0, space) , space_transform(V5) , (V6 == none -> true ; space_interior(V6)) , (V4 == V1 -> true ; space_exterior(V4)) , space_authorized_representation(V0, V1, V2, V3, V4, V5, V6) , in_ontology(V7, V8, unique_solution((attribute(V9, exterior, V1) , attribute(V9, transform, V2)))) , in_ontology(V7, V8, findall(V10, attribute(V9, interior, V10), V11)) , (V11 == [] -> V3 == none ; V11 == [V3]) , (V3 == V6 -> true ; in_ontology(V7, V8, ((V3 == none -> true ; retract(attribute(V9, interior, V3))) , (V6 == none -> true ; assertz(attribute(V9, interior, V6)))))) , (V1 == V4 , V2 == V5 -> true ; in_ontology(V7, V8, (retract(attribute(V9, exterior, V1)) , assertz(attribute(V9, exterior, V4)) , retract(attribute(V9, transform, V2)) , assertz(attribute(V9, transform, V5)))) , space_assignment(V0, V12, V13) , (V13 == none -> true ; space_representation_changed(V13, V0))))).
space_representation_changed(V0, V1) :- V0 = entity_ref(V2, V3, V4) , in_ontology(V2, V3, space_placement(V4, V1, V5)) , space_assignment(V1, V5, V0) , space_change_physics(V0, V1, represented).
space_scene_parts([], V0, V1, V2, V3, V4, [], []) :- true.
space_scene_parts([exposed(V0, V1, V2) | V3], V4, V5, V6, V7, V8, V9, V10) :- V0 = entity_ref(V11, V12, V13) , in_ontology(V11, V12, viewer_scene(V13, V4, V14)) , (V14 = hidden -> V15 = [] , V16 = [] ; V14 = appearance(V17, V18, V19, V20, V21) , append(V5, [edge(V0, V17)], V22) , term_hex_digest(V22, V23) , findall(V24, member(eidolon(V4, V18, V24), V21), V25) , (V18 == contents -> (V25 = [V26] , space_entity_model([V26], V19, contents(exposure(V0, V27, V28))) -> V29 = contents(exposure(V0, V27, V28)) ; fail_with_reason(space_contents_unavailable(V0))) ; space_entity_model(V25, V19, V29)) , variant_digest(selected(V25, V19, V29), V30) , V8 = role(V31, V32) , (V31 == physical , V1 = placement(V33) -> V34 = physical ; V34 = display) , space_scene_pose(V34, V32, V0, V2, V20, V35) , V36 = role(V34, V32) , space_parent_pose(V7, V35, V37) , space_occurrence_model(V29, V4, V22, V6, V23, V36, V38, V39, V40, V41, V42, V43) , scene_vocabulary(V44, V45) , in_ontology(V44, V45, place_model(V23, V37, depicts(V11, V12, V13), V38, V46)) , append(V46, V39, V15) , V16 = [exposure(V23, V22, V0, selected(V25, V30, V34), V41, V42, V35, V43) | V40]) , space_scene_parts(V3, V4, V5, V6, V7, V8, V47, V48) , append(V15, V47, V9) , append(V16, V48, V10).
space_scene_pose(V0, V1, V2, in_frame(V3, body_pose(V4, V5)), V6, V7) :- (V3 == V1 -> true ; fail_with_reason(incompatible_physics_view(V3, V1))) , (V0 == physical -> V7 = body_pose(V4, V5) ; V0 == display , V7 = body_frame_pose(V4, V5)).
space_scene_pose(physical, V0, V1, body_pose(V2, V3), V4, body_pose(V2, V3)) :- true.
space_scene_pose(physical, V0, V1, source_layout, V2, V2) :- true.
space_scene_pose(display, V0, V1, source_layout, V2, V3) :- V0 = world_ref(V4, V5, V6) -> in_ontology(V4, V5, physics_appearance_binding(V6, V1, V7)) , (V7 = none -> V3 = V2 ; V7 = body_pose(V8, V9) , V3 = body_frame_pose(V8, V9)) ; V3 = V2.
space_simulation_domain(entity_ref(V0, V1, V2), V3, V4, V5) :- in_ontology(V0, V1, physics_domain(V2, V3, V4, V5)).
space_size_text(infinite, <<"Infinite">>) :- true.
space_size_text(box(V0, V1, V2), V3) :- space_length_codes(V0, V4) , space_length_codes(V1, V5) , space_length_codes(V2, V6) , V7 = [32, 195, 151, 32] , append(V5, V7, V8) , append(V8, V6, V9) , append(V4, V7, V10) , append(V10, V9, V11) , binary_codes(V3, V11).
space_subject(entity_ref(V0, V1, V2), V3) :- in_ontology(V0, V1, (instance_of(V4, V2) -> V3 = instance(V2) ; isa(V2, V2) , V3 = class(V2))).
space_subject_binding(V0, V1, V2) :- V0 = entity_ref(V3, V4, V5) , (in_ontology(V3, V4, space_placement(V5, V1, V6)) , space_simulation_domain(V0, V7, V8, V9) -> V7 = world_ref(V10, V11, V12) , in_ontology(V10, V11, physics_scene_binding(V12, V9, V1, V6, V2)) ; in_ontology(V3, V4, space_placement(V5, V1, V6)) , space_instance(V0, physical_space) -> in_ontology(V3, V4, findall(binding(V13, V14), physics_body_definition(V5, V13, V14, V15, V16, live(V1, V6, V17, V18)), [binding(V19, V20)])) , V2 = body_pose(V19, V20) ; V2 = source_layout).
space_transform(V0) :- V0 = transform(V1, V2, V3, V4, V5, V6) , unique_solution(scene_vocabulary(V7, V8)) , in_ontology(V7, V8, placed(V0)).
space_travel_context(V0, V1, V2) :- quod : user :: personal_agent(V0, V3) , V0 = agent_instance_ref(V4, V5, V6) , space_assignment(entity_ref(V4, V5, V6), V1, V2).
space_view_pose(V0, V1, view(transform(V2, V3, V4, V5, V6, V7), forward(V8, 0, V9)), V10) :- integer(V2) , integer(V4) , integer(V8) , integer(V9) , V11 is V8 * V8 + V9 * V9 , V11 >= 998001 , V11 =< 1002001 , space_near(V12, V13) , V14 is V2 + V8 * V13 // 1000 , V15 is V4 + V9 * V13 // 1000 , V16 is - V9 , space_free_pose(V0, transform(V14, V1, V15, 0, V6, 0), V16, V8, V10).
space_whole_mm(V0 / V1, V2) :- ! , V3 is (V0 + V1 // 2) // V1 , (V3 < 1 -> V2 = 1 ; V2 = V3).
space_whole_mm(V0, V0) :- true.
system_prolog_edit :- current_ontology_identity(V0, V1) , quod : root :: (current_ontology_identity(<<"quod:root">>, V2) , system_source_access(ontology_ref(V0, V1), editable)).
system_prolog_introspection(V0, V1) :- current_ontology_identity(V2, V3) , quod : root :: (current_ontology_identity(<<"quod:root">>, V4) , system_source_access(ontology_ref(V2, V3), V5)) , (V0 == presentation -> V1 = V5 ; prolog_introspection(V0, V1)).
system_source_query((current_ontology_identity(V0, V1) , system_prolog_introspection(V2, V3))) :- true.
system_source_query((current_ontology_identity(V0, V1) , system_prolog_edit , transaction(V2))) :- true.
term_hex_digest(V0, V1) :- term_digest(V0, V2) , binary_codes(V2, V3) , digest_hex_codes(V3, V4) , binary_codes(V1, V4).
unique_solution(V0) :- term_variables(V0, V1) , findall(V1, V0, [V1]).
unplaced(V0) :- space_assignment(V0, V1, none).
viewer_eidolon(V0, V1, V2, V3) :- current_ontology_identity(V4, V5) , quod : user :: shown_as(entity_ref(V4, V5, V0), V1, V2) , entity_eidolons(V0, V1, V2, V3) , V3 \== [].
viewer_scene(V0, V1, V2) :- client_entity_scene(V0, V1, V3) , (V3 = appearance(V4, V5, V6, V7, V8) , viewer_eidolon(V0, V1, V9, V10) -> V2 = appearance(V4, V9, V6, V7, V10) ; V2 = V3).
with_build_plan(V0, V1) :- '$quod_build_inputs'(V0) , '$quod_with_build_plan'(V0, V1).
withdraw(V0) :- space_assignment(V0, V1, V2) , V2 = entity_ref(V3, V4, V5) , V0 = entity_ref(V6, V7, V8) , V9 is V1 + 1 , in_ontology(V6, V7, (retract(space_assignment_state(V8, V1, V2)) , assertz(space_assignment_state(V8, V9, none)))) , space_change_physics(V2, V0, withdrawn) , in_ontology(V3, V4, retract(space_placement(V5, V0, V1))).
world_view(V0, V1, V2) :- space_projection(V0, V1, V2, V3).
