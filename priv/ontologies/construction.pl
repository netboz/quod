%% Shared slot initialization. Bare assertions enter through the existing hook
%% and proof savepoint. Explicit clauses are source, not creation requests.
%% Class declarations and their checks run at the class owner.
have_attribute(Class, name, binary) :- nonvar(Class).

'$quod_assert_instance'(Method, Class, Instance) :-
    term_variables(Class, []),
    (var(Instance) ->
        '$quod_build_plan'(Inputs),
        operation_authorized(class(Class), create(Inputs)),
        '$quod_instance_id'(Instance),
        (instance_of(_, Instance) -> fail_with_reason(instance_identity_collision(Instance)); true),
        '$quod_constructor_plan'(Class, Instance, Inputs, _, Attributes),
        '$quod_membership_clause'(Method, Class, Instance),
        '$quod_initial_attribute_writes'(Instance, Attributes)
    ; term_variables(Instance, []),
      (instance_of(_, Instance) -> '$quod_membership_clause'(Method, Class, Instance)
      ; fail_with_reason(creation_requires_output_variable(Class)))).

'$quod_membership_clause'(Method, Class, Instance) :-
    Assertion =.. [Method, (instance_of(Class, Instance) :- true)],
    call(Assertion).

with_build_plan(Inputs, Goal) :-
    '$quod_build_inputs'(Inputs),
    '$quod_with_build_plan'(Inputs, Goal).

'$quod_build_inputs'(Inputs) :-
    (term_variables(Inputs, []), '$quod_build_entries'(Inputs, []) -> true
    ; fail_with_reason(invalid_build_inputs)).
'$quod_build_entries'([], _).
'$quod_build_entries'([attribute(Key, _) | Rest], Seen) :-
    atom(Key), \+ member_eq(attribute(Key), Seen),
    '$quod_build_entries'(Rest, [attribute(Key) | Seen]).
%% Complete preflight precedes every membership and slot write.
'$quod_constructor_plan'(Class, Instance, Inputs, Order, Attributes) :-
    '$quod_state_check'(once(
        '$quod_constructor_description'(Class, Instance, Inputs, Order, Attributes))).

'$quod_constructor_description'(Class, Instance, Inputs, Order, Attributes) :-
    term_variables(Class-Instance, []),
    '$quod_build_inputs'(Inputs),
    '$quod_constructor_graph'(Class, [], [], Candidates, Edges),
    '$quod_constructor_sort'(Candidates, Edges, [], Order),
    findall(declaration(Owner, Key, Type, Default),
        (member(Owner, Order), '$quod_attribute_declaration'(Owner, Key, Type, Default)),
        Declarations),
    findall(Key, member(declaration(_, Key, _, _), Declarations), RawKeys),
    sort(RawKeys, Keys),
    (member(attribute(Key, _), Inputs), \+ member_eq(Key, Keys) ->
        fail_with_reason(unknown_initial_attribute(Key)); true),
    '$quod_initial_attributes'(Keys, Class, Instance, Inputs, Declarations, Attributes).

'$quod_constructor_graph'(Class, Path, Seen, Classes, Edges) :-
    (member_eq(Class, Path) -> fail_with_reason(constructor_cycle(Class)); true),
    (member_eq(Class, Seen) -> Classes = Seen, Edges = []
    ; '$quod_constructor_metadata'(Class, RawParents, Orders),
      term_variables(RawParents, []), sort(RawParents, Parents),
      '$quod_constructor_parents'(Class, Parents, Orders, Ordered),
      '$quod_constructor_branches'(Ordered, [Class | Path], Seen, Ancestors, Inherited),
      append(Ancestors, [Class], Classes),
      findall(before(Parent, Class), member(Parent, Parents), ParentEdges),
      '$quod_parent_edges'(Ordered, OrderEdges),
      append(ParentEdges, OrderEdges, Own), append(Inherited, Own, Edges)).

'$quod_constructor_metadata'(Class, Parents, Orders) :-
    ('$quod_owner_name'(Class, Ns, Local) ->
        Ns::'$quod_constructor_metadata'(Local, LocalParents, LocalOrders),
        '$quod_qualified_classes'(Ns, LocalParents, Parents),
        findall(Order, (member(LocalOrder, LocalOrders),
            (term_variables(LocalOrder, []), '$quod_qualified_classes'(Ns, LocalOrder, Qualified) -> Order = Qualified
            ; Order = LocalOrder)), Orders)
    ; (clause(constructor(Class, _, _), _) ->
          fail_with_reason(constructor_body(Class)); true),
      findall(Parent, '$quod_direct_isa'(Class, Parent), Parents),
      findall(Order, constructor_order(Class, Order), Orders)).

'$quod_qualified_classes'(_, [], []).
'$quod_qualified_classes'(Ns, [Class | Rest], [Qualified | Classes]) :-
    nonvar(Class), '$quod_qualified_class'(Ns, Class, Qualified),
    '$quod_qualified_classes'(Ns, Rest, Classes).

'$quod_constructor_parents'(Class, Parents, Orders, Ordered) :-
    (Orders == [], (Parents = []; Parents = [_]) -> Ordered = Parents
    ; Orders = [Ordered], term_variables(Ordered, []),
      '$quod_parent_list'(Ordered), sort(Ordered, Parents),
      length(Ordered, Count), length(Parents, Count) -> true
    ; fail_with_reason(constructor_order(Class))).
'$quod_parent_list'([]).
'$quod_parent_list'([_ | Rest]) :- '$quod_parent_list'(Rest).

'$quod_constructor_branches'([], _, Seen, Seen, []).
'$quod_constructor_branches'([Parent | Rest], Path, Seen, Classes, Edges) :-
    '$quod_constructor_graph'(Parent, Path, Seen, Next, First),
    '$quod_constructor_branches'(Rest, Path, Next, Classes, More),
    append(First, More, Edges).
'$quod_parent_edges'([], []).
'$quod_parent_edges'([_], []).
'$quod_parent_edges'([First, Second | Rest], [before(First, Second) | Edges]) :-
    '$quod_parent_edges'([Second | Rest], Edges).

%% Stable topological selection uses the authored traversal as its tie-break.
%% Valid constraints can require revisiting a branch before its DFS position.
'$quod_constructor_sort'([], _, _, []).
'$quod_constructor_sort'([Class | Rest], Edges, Done, [Next | Order]) :-
    (once((member(Next, [Class | Rest]),
           \+ (member(before(Parent, Next), Edges), \+ member_eq(Parent, Done)))) ->
        delete([Class | Rest], Next, Remaining),
        '$quod_constructor_sort'(Remaining, Edges, [Next | Done], Order)
    ; fail_with_reason(constructor_order_cycle)).

'$quod_attribute_declaration'(Class, Key, Type, Default) :-
    have_attribute(Class, Key, Type, Default).
'$quod_attribute_declaration'(Class, Key, Type, optional) :-
    have_attribute(Class, Key, Type).

'$quod_initial_attributes'([], _, _, _, _, []).
'$quod_initial_attributes'([Key | Keys], Class, Instance, Inputs, Declarations, Attributes) :-
    atom(Key),
    (member(attribute(Key, Supplied), Inputs) -> Selected = value(Supplied)
    ; '$quod_attribute_default'(Class, Key, Declarations, Default),
      '$quod_default_value'(Default, Instance, Key, Selected)),
    (Selected = value(Value) ->
        findall(Type, (member(declaration(Owner, Key, Local, _), Declarations),
                       '$quod_class_predicate'(Owner, Local, Type)), RawTypes),
        sort(RawTypes, Types),
        ('$quod_attribute_types'(Types, Value) -> true
        ; fail_with_reason(invalid_initial_attribute(Key))),
        Attributes = [attribute(Key, Value) | Rest]
    ; Selected = absent, Attributes = Rest),
    '$quod_initial_attributes'(Keys, Class, Instance, Inputs, Declarations, Rest).

'$quod_attribute_default'(Class, Key, Declarations, Default) :-
    findall(Owner, (member(declaration(Owner, Key, _, D), Declarations), D \== optional), Owners),
    findall(DefaultValue, (member(declaration(Owner, Key, _, D), Declarations),
                D \== optional, \+ '$quod_stricter_class'(Owner, Owners),
                (D = default_from(Provider) ->
                    '$quod_class_predicate'(Owner, Provider, Owned),
                    DefaultValue = default_from(Owned)
                ; DefaultValue = D)), Defaults),
    term_variables(Defaults, []), sort(Defaults, Unique),
    (Unique = [] -> Default = optional
    ; Unique = [Default] -> true
    ; fail_with_reason(conflicting_attribute_defaults(Class, Key))).

'$quod_default_value'(optional, _, _, absent).
'$quod_default_value'(required, _, Key, _) :- fail_with_reason(missing_initial_attribute(Key)).
'$quod_default_value'(default(Value), _, _, value(Value)).
%% Lazy computed defaults reuse the same metadata. Only the winning provider
%% runs; supplied values never draw a name or execute a discarded default.
'$quod_default_value'(default_from(Provider), Instance, Key, value(Value)) :-
    (once(('$quod_owner_name'(Provider, Ns, Local) ->
              atom(Local), Goal =.. [Local, Instance, Value], Ns::Goal
           ; atom(Provider), Goal =.. [Provider, Instance, Value], call(Goal))) -> true
    ; fail_with_reason(initial_default_failed(Key, Provider))).

'$quod_attribute_types'([], Value) :- term_variables(Value, []).
'$quod_attribute_types'([Type | Rest], Value) :-
    attribute_value(Type, Value), '$quod_attribute_types'(Rest, Value).

%% Type names are ordinary unary Prolog checks (including built-in tests).
%% `term` accepts any ground data; domain-specific types stay with their class.
attribute_value(term, Value) :- !, term_variables(Value, []).
attribute_value(Type, Value) :-
    term_variables(Value, []),
    ('$quod_owner_name'(Type, Ns, Local) -> Ns::attribute_value(Local, Value)
    ; atom(Type), Check =.. [Type, Value], call(Check)).

nonempty_binary(Value) :- binary(Value), Value \== <<"">>.
boolean(true).
boolean(false).
positive_integer(Value) :- integer(Value), Value > 0.
nonnegative_integer(Value) :- integer(Value), Value >= 0.

'$quod_initial_attribute_writes'(_, []).
'$quod_initial_attribute_writes'(Instance, [attribute(Key, Value) | Rest]) :-
    assertz(attribute(Instance, Key, Value)),
    '$quod_initial_attribute_writes'(Instance, Rest).

no_follow(with_build_plan/2).
no_follow('$quod_assert_instance'/3).
no_follow('$quod_membership_clause'/3).
no_follow(attribute_value/2).
no_follow(nonempty_binary/1).
no_follow(boolean/1).
no_follow(positive_integer/1).
no_follow(nonnegative_integer/1).
no_follow(constructor/3).
no_follow(constructor_order/2).
no_follow('$quod_build_inputs'/1).
no_follow('$quod_build_entries'/2).
no_follow('$quod_constructor_plan'/5).
no_follow('$quod_constructor_description'/5).
no_follow('$quod_constructor_graph'/5).
no_follow('$quod_constructor_metadata'/3).
no_follow('$quod_qualified_classes'/3).
no_follow('$quod_constructor_parents'/4).
no_follow('$quod_parent_list'/1).
no_follow('$quod_constructor_branches'/5).
no_follow('$quod_parent_edges'/2).
no_follow('$quod_constructor_sort'/4).
no_follow('$quod_attribute_declaration'/4).
no_follow('$quod_initial_attributes'/6).
no_follow('$quod_attribute_default'/4).
no_follow('$quod_default_value'/4).
no_follow('$quod_attribute_types'/2).
no_follow('$quod_initial_attribute_writes'/2).
