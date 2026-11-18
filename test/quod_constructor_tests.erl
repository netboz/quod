-module(quod_constructor_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

ordered_diamond_and_initial_values_test() ->
    with_fixture([], fun(St) ->
        Inputs = [{attribute, wheels, 8}, {attribute, name, <<"Amphi">>}],
        S = prove({with_build_plan, Inputs, {test_initialize, amphibious, id}}, St),
        holds({'$quod_constructor_plan', amphibious, id, Inputs,
               [thing, vehicle, car, boat, amphibious], {'_'}}, St),
        holds({attribute, id, wheels, 8}, S),
        holds({attribute, id, name, <<"Amphi">>}, S),
        holds({'$quod_build_plan', []}, S),
        %% No instance creation executor or assertion hook is installed here.
        fails({instance_of, amphibious, id}, S)
    end).

inherited_slots_need_no_own_declarations_test() ->
    with_fixture([], fun(St) ->
        S = prove({test_initialize, trailer, id}, St),
        holds({attribute, id, wheels, 4}, S),
        holds({attribute, id, name, <<"Vehicle">>}, S)
    end).

invalid_orders_are_preflight_failures_test_() ->
    [{Label, fun() -> with_fixture([], fun(St0) ->
        St1 = prove({retract, {constructor_order, amphibious, {'_'}}}, St0),
        St = load(Terms, St1),
        {fail, Failed} = erlog_int:prove_goal({test_initialize, amphibious, id}, St),
        fails({attribute, id, {'_'}, {'_'}}, Failed),
        ?assertEqual(changes(St), changes(Failed))
    end) end} || {Label, Terms} <- [
        {"missing", []},
        {"omitted parent", [{constructor_order, amphibious, [car]}]},
        {"duplicate parent", [{constructor_order, amphibious, [car, car, boat]}]},
        {"extra parent", [{constructor_order, amphibious, [car, boat, vehicle]}]},
        {"improper list", [{constructor_order, amphibious, [car | boat]}]},
        {"nonground", [{constructor_order, amphibious, [car, {'_'}]}]},
        {"two declarations", [{constructor_order, amphibious, [car, boat]},
                              {constructor_order, amphibious, [boat, car]}]},
        {"contradictory ancestry", [{isa, car, boat},
                                    {constructor_order, car, [vehicle, boat]},
                                    {constructor_order, amphibious, [car, boat]}]},
        {"ancestry cycle", [{isa, vehicle, amphibious},
                            {constructor_order, vehicle, [thing, amphibious]},
                            {constructor_order, amphibious, [car, boat]}]}
    ]].

valid_order_can_require_interleaving_branches_test() ->
    with_fixture([{isa, first, x}, {isa, second, x}, {isa, second, y},
                  {isa, joined, first}, {isa, joined, second},
                  {constructor_order, second, [y, x]},
                  {constructor_order, joined, [first, second]}], fun(St) ->
        holds({'$quod_constructor_plan', joined, id, [],
               [y, x, first, second, joined], []}, St)
    end).

conflicting_defaults_need_explicit_resolution_test() ->
    Extra = [{have_attribute, boat, wheels, integer, {default, 2}}],
    with_fixture(Extra, fun(St) ->
        {fail, F} = erlog_int:prove_goal({test_initialize, amphibious, id}, St),
        ?assertEqual([], changes(F)),
        S = prove({with_build_plan, [{attribute, wheels, 6}],
                   {test_initialize, amphibious, supplied}}, St),
        holds({attribute, supplied, wheels, 6}, S),
        S2 = load([{have_attribute, amphibious, wheels, integer, {default, 10}}], St),
        holds({test_initialize, amphibious, resolved}, S2)
    end).

equal_defaults_and_type_only_subclass_test() ->
    with_fixture([{have_attribute, boat, wheels, integer, {default, 4}},
                  {have_attribute, amphibious, wheels, positive_integer}], fun(St) ->
        S = prove({test_initialize, amphibious, id}, St),
        holds({attribute, id, wheels, 4}, S),
        fails({with_build_plan, [{attribute, wheels, 0}], {test_initialize, amphibious, bad}}, St)
    end).

invalid_inputs_never_fall_back_test_() ->
    [?_test(with_fixture([], fun(St) ->
        {fail, F} = erlog_int:prove_goal(
            {with_build_plan, Inputs, {test_initialize, car, id}}, St),
        fails({attribute, id, {'_'}, {'_'}}, F),
        ?assertEqual([], changes(F)),
        holds({'$quod_build_plan', []}, F)
    end)) || Inputs <- [
        [{attribute, wheels, bad}], [{attribute, name, atom_name}],
        [{attribute, unknown, 4}], [{attribute, wheels, 1}, {attribute, wheels, 2}],
        [{attribute, wheels, {'_'}}], [invalid],
        [{part, left_eye, [invalid]}], [{attribute, wheels, 4} | invalid]
    ]].

constructor_bodies_are_refused_without_execution_test_() ->
    [?_test(with_fixture([], fun(St) ->
        {fail, F} = erlog_int:prove_goal({test_initialize, Class, id}, St),
        fails(should_not_run, F)
    end)) || Class <- [failing_child, parent_failure_child]].

parts_are_initialized_explicitly_with_separate_inputs_test() ->
    with_fixture([], fun(St) ->
        S = prove(conj([
            {with_build_plan, [{attribute, name, <<"Parent">>}, {attribute, color, green}],
             {test_initialize, head, id}},
            {with_build_plan, [{attribute, name, <<"Left eye">>}],
             {test_initialize, eye, {left, id}}},
            {test_initialize, eye, {right, id}}]), St),
        holds({attribute, id, name, <<"Parent">>}, S),
        holds({attribute, {left, id}, name, <<"Left eye">>}, S),
        holds({attribute, {right, id}, name, <<"Eye">>}, S),
        holds({attribute, {left, id}, color, blue}, S),
        holds({attribute, {right, id}, color, blue}, S),
        fails({with_build_plan, [{attribute, color, invalid}],
               {test_initialize, eye, bad}}, St)
    end).

part_inputs_are_refused_before_slot_writes_test() ->
    with_fixture([], fun(St) ->
        refused({test_initialize, head, id}, [{part, left_eye, []}],
                invalid_build_inputs, St),
        refused({test_initialize, head, id}, [{part, left_eye, [{part, nested, []}]}],
                invalid_build_inputs, St),
        ?assertEqual([], changes(St))
    end).

initial_attribute_refusals_identify_the_key_test() ->
    with_fixture([{have_attribute, required_class, size, integer, required},
                  {have_attribute, bad_default, size, integer, {default, wrong}}], fun(St) ->
        refused({test_initialize, car, id}, [invalid], invalid_build_inputs, St),
        refused({test_initialize, car, id}, [{attribute, typo, 4}],
                {unknown_initial_attribute, typo}, St),
        refused({test_initialize, required_class, id}, [],
                {missing_initial_attribute, size}, St),
        refused({test_initialize, car, id}, [{attribute, wheels, wrong}],
                {invalid_initial_attribute, wheels}, St),
        refused({test_initialize, bad_default, id}, [],
                {invalid_initial_attribute, size}, St),
        refused({test_initialize, unsupported_pool, id}, [],
                {initial_default_failed, name, unsupported_name}, St)
    end).

required_and_unrelated_default_need_explicit_resolution_test() ->
    with_fixture([{have_attribute, car, capacity, integer, required},
                  {have_attribute, boat, capacity, integer, {default, 2}}], fun(St) ->
        refused({test_initialize, amphibious, id}, [],
                {conflicting_attribute_defaults, amphibious, capacity}, St),
        holds({with_build_plan, [{attribute, capacity, 3}],
               {test_initialize, amphibious, id}}, St),
        Resolved = load([{have_attribute, amphibious, capacity, integer, {default, 4}}], St),
        holds({test_initialize, amphibious, resolved}, Resolved)
    end).

absent_optional_declaration_predicates_test() ->
    with_terms([], fun(St) ->
        holds({'$quod_constructor_plan', standalone, id, [], [standalone], []}, St),
        refused({'$quod_constructor_plan', standalone, id, [{part, typo, []}], {'_'}, {'_'}},
                [], invalid_build_inputs, St)
    end).

name_metadata_is_not_class_membership_evidence_test() ->
    with_terms([], fun(St) ->
        holds({have_attribute, standalone, name, binary}, St),
        holds({have_attribute, {arbitrary, term}, name, binary}, St),
        fails({isa, standalone, thing}, St),
        fails({have_attribute, {'Unbound'}, name, binary}, St)
    end).

descriptive_types_require_executable_validators_test() ->
    with_fixture([{have_attribute, measured, size, {quantity, metres}, required},
                  {have_attribute, measured, angle, degrees, required}], fun(St) ->
        Inputs = [{attribute, size, 4}, {attribute, angle, 90}],
        refused({test_initialize, measured, id}, Inputs,
                {invalid_initial_attribute, angle}, St),
        Typed = load([{':-', {degrees, {'V'}}, conj([{integer, {'V'}}, {'>=', {'V'}, 0}])}], St),
        refused({test_initialize, measured, id}, Inputs,
                {invalid_initial_attribute, size}, Typed)
    end).

names_are_stored_mutable_and_nonunique_test() ->
    with_fixture([], fun(St) ->
        S1 = prove({test_initialize, car, one}, St),
        S2 = prove({test_initialize, car, two}, S1),
        S3 = prove({retract, {have_attribute, vehicle, name, binary, {'_'}}}, S2),
        S4 = prove({assertz, {have_attribute, vehicle, name, binary, {default, <<"New">>}}}, S3),
        holds({attribute, one, name, <<"Vehicle">>}, S4),
        holds({attribute, two, name, <<"Vehicle">>}, S4),
        S5 = prove({test_initialize, car, three}, S4),
        holds({attribute, three, name, <<"New">>}, S5),
        S6 = prove({retract, {attribute, one, name, <<"Vehicle">>}}, S5),
        S7 = prove({assertz, {attribute, one, name, <<"Renamed">>}}, S6),
        holds({attribute, one, wheels, 4}, S7),
        holds({attribute, two, name, <<"Vehicle">>}, S7)
    end).

scope_success_failure_backtracking_cut_and_exceptions_test() ->
    with_fixture([], fun(St) ->
        Inputs = [{attribute, name, <<"Outer">>}],
        Current = {'$quod_build_plan', Inputs},
        Inner = {'$quod_build_plan', []},
        holds({with_build_plan, Inputs, conj([Current, {with_build_plan, [], Inner}, Current])}, St),
        holds(conj([{with_build_plan, Inputs, {';', fail, Current}}, Inner]), St),
        holds(conj([{'once', {with_build_plan, Inputs, conj([Current, '!'])}}, Inner]), St),
        holds(conj([{';', {with_build_plan, Inputs, fail}, true}, Inner]), St),
        Goal = {findall, {'V'},
                conj([{with_build_plan, Inputs, {member, {'V'}, [a,b]}}, Inner]), [a,b]},
        holds(Goal, St),
        try erlog_int:prove_goal({with_build_plan, Inputs, {is, {'X'}, bad_arithmetic}}, St) of
            Other -> error({expected_error, Other})
        catch throw:{erlog_error, _, ErrorSt} ->
            ?assertMatch({succeed, _}, erlog_int:prove_body([Inner], ErrorSt)) end,
        ?assertEqual([], changes(St))
    end).

conflicting_branch_orders_fail_before_writes_test() ->
    with_fixture([{isa, first, x}, {isa, first, y},
                  {isa, second, x}, {isa, second, y},
                  {isa, joined, first}, {isa, joined, second},
                  {constructor_order, first, [x, y]},
                  {constructor_order, second, [y, x]},
                  {constructor_order, joined, [first, second]}], fun(St) ->
        {fail, Failed} = erlog_int:prove_goal({test_initialize, joined, id}, St),
        ?assertEqual([], changes(Failed)),
        ?assert(lists:member(constructor_order_cycle, Failed#est.fail_reasons))
    end).

declared_constructor_head_mismatch_is_failure_test() ->
    with_fixture([{isa, specialized, thing},
                  {constructor, specialized, another_id, []}], fun(St) ->
        fails({test_initialize, specialized, id}, St)
    end).

resolved_values_are_stored_once_test() ->
    with_fixture([{isa, base, thing}, {isa, child, base},
                  {have_attribute, base, size, integer, {default, 4}}], fun(St) ->
        S = prove(conj([
            {'$quod_constructor_plan', child, id, [], {'_'}, {'Attributes'}},
            {retract, {have_attribute, base, size, integer, {default, 4}}},
            {assertz, {have_attribute, base, size, integer, {default, 9}}},
            {'$quod_initial_attribute_writes', id, {'Attributes'}}]), St),
        holds({attribute, id, size, 4}, S),
        holds({have_attribute, base, size, integer, {default, 9}}, S)
    end).

standalone_class_defaults_do_not_require_a_parent_edge_test() ->
    with_fixture([{have_attribute, standalone, name, binary, {default, <<"Standalone">>}}], fun(St) ->
        S = prove({test_initialize, standalone, id}, St),
        holds({attribute, id, name, <<"Standalone">>}, S),
        holds({'$quod_constructor_plan', empty_class, id, [], [empty_class], []}, St),
        holds({'$quod_constructor_plan', empty_class, id, [{attribute, name, <<"Named">>}],
               [empty_class], [{attribute, name, <<"Named">>}]}, St),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
            {'$quod_constructor_plan', empty_class, id, [{attribute, name, 7}], {'_'}, {'_'}}, St))
    end).

binary_and_compound_class_names_test() ->
    with_fixture([{isa, <<"tool">>, thing}, {isa, {tool, special}, <<"tool">>},
                  {have_attribute, <<"tool">>, name, binary, {default, <<"Tool">>}}], fun(St) ->
        S = prove({test_initialize, {tool, special}, id}, St),
        holds({attribute, id, name, <<"Tool">>}, S)
    end).

gui_types_and_defaults_are_shared_test() ->
    with_fixture(quod_ct:gui_terms(), fun(St) ->
        Inputs = [{attribute, label, <<"Grid">>}],
        S = prove({with_build_plan, Inputs, {test_initialize, grid, id}}, St),
        holds({attribute, id, layout, grid}, S),
        holds({attribute, id, columns, 2}, S),
        fails({with_build_plan, Inputs ++ [{attribute, columns, 0}],
               {test_initialize, grid, bad}}, St),
        fails({test_initialize, grid, missing_required}, St)
    end).

naming_pool_is_explicit_lazy_and_stored_test() ->
    Terms = source("quod_names.pl") ++ [
        {isa, <<"fixture">>, <<"thing">>},
        {pool, <<"fixture">>, <<"place">>, <<"neutral">>, listed},
        {listed, <<"fixture">>, <<"place">>, <<"neutral">>, [<<"Harbor">>]}],
    with_fixture(Terms, fun(St) ->
        %% Supplied and ordinary defaults work even without a naming proof.
        holds({with_build_plan, [{attribute, name, <<"Chosen">>}],
               {test_initialize, unsupported_pool, id}}, St),
        fails({test_initialize, unsupported_pool, id}, St),
        ProofId = <<1:256>>,
        Ctx = quod_predicates:proof_context(<<"constructor-test">>, 1, undefined),
        Metadata = {scope, ProofId, self(), make_ref(), <<1:128>>},
        Goal = conj([{test_initialize, place, id},
                      {attribute, id, name, <<"Harbor">>},
                      {retract, {listed, <<"fixture">>, <<"place">>, <<"neutral">>, {'_'}}},
                      {attribute, id, name, <<"Harbor">>}]),
        ?assertMatch({ok, _}, quod_ct:session_prove(quod_erlog_db_local_prove:committed_state(St),
                                                  Metadata, Ctx, Goal))
    end).

preflight_cannot_execute_mutating_default_code_test() ->
    with_fixture([{isa, invalid_default, thing},
        {have_attribute, invalid_default, name, binary, {default_from, mutating_name}},
        {':-', {mutating_name, {'_'}, <<"Name">>}, {assertz, leaked}}], fun(St) ->
        ?assertThrow({erlog_error, _, _},
            erlog_int:prove_goal({test_initialize, invalid_default, id}, St)),
        fails(leaked, St)
    end).

scoped_redo_error_and_caller_error_restore_correct_inputs_test() ->
    with_fixture([], fun(St) ->
        Inputs = [{attribute, name, <<"Outer">>}],
        Error = {is, {'X'}, bad_arithmetic},
        %% Enumerating the second solution resumes inside the scope.
        S = prove({with_build_plan, Inputs, {';', true, Error}}, St),
        try erlog_int:fail(S) of
            Other -> error({expected_redo_error, Other})
        catch throw:{erlog_error, _, ErrorSt} ->
            ?assertMatch({succeed, _}, erlog_int:prove_body([{'$quod_build_plan', []}], ErrorSt))
        end,
        %% The inner scope has already released; its handler must not restore
        %% outer inputs over the outer scope's own exception cleanup.
        try erlog_int:prove_goal({with_build_plan, Inputs,
                conj([{with_build_plan, [], true}, Error])}, St) of
            Other2 -> error({expected_caller_error, Other2})
        catch throw:{erlog_error, _, ErrorSt2} ->
            ?assertMatch({succeed, _}, erlog_int:prove_body([{'$quod_build_plan', []}], ErrorSt2))
        end
    end).

scopes_preserve_caller_bindings_and_interleaved_read_checks_test() ->
    with_fixture([], fun(St) ->
        Input = [{attribute, name, <<"Outer">>}],
        Current = {'$quod_build_plan', Input},
        Goal = conj([{with_build_plan, Input, {'$quod_state_check',
                     conj([Current, {with_build_plan, [], {member, {'X'}, [one, two]}}, Current])}},
                     {'$quod_build_plan', []}, {'=', {'Y'}, {'X'}}]),
        holds({findall, {pair, {'X'}, {'Y'}}, Goal, [{pair, one, one}, {pair, two, two}]}, St)
    end).

signed_qualified_class_initializes_slots_at_the_storing_ontology_test_() ->
    {timeout, 120, fun signed_qualified_class/0}.

signed_qualified_class() ->
    Dir = filename:join("/tmp", "quod-qualified-construction-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Ctx = quod_lobby_tests:start(Dir),
    {ontology_ref, Lobby, _} = maps:get(lobby, Ctx),
    {_, Base} = maps:get(Lobby, maps:get(ontologies, Ctx)),
    Owner = <<"constructor-owner">>, Store = <<"constructor-store">>,
    Class = fun(Name) -> {':', 'constructor-owner', Name} end,
    Ask = fun(Ns, G) -> {'::', Ns, G} end,
    Terms = quod_prolog:read_terms("test/fixtures/constructors.pl") ++ [
        {can_invoke, {'_'}, {'_'}, {'_'}, Owner},
        {class_permission, vehicle, create, allow},
        {class_permission, vehicle, place, allow},
        {have_attribute, amphibious, flag, owner_type, {default_from, owner_default}},
        {owner_type, good}, {owner_default, {'_'}, good},
        {isa, mutating_default, vehicle},
        {have_attribute, mutating_default, name, binary, {default_from, leaking_default}},
        {':-', {leaking_default, {'_'}, <<"Name">>}, {assertz, leaked}}],
    {OwnerSup, _} = quod_lobby_tests:start_namespace(Owner, Base#{
        data_dir => filename:join(Dir, "owner"),
        genesis_diff => quod_prolog:terms_to_diff(Terms)}),
    {StoreSup, _} = quod_lobby_tests:start_namespace(Store, Base#{
        data_dir => filename:join(Dir, "store"),
        genesis_diff => quod_prolog:terms_to_diff([
            {can_invoke, {'_'}, {'_'}, {'_'}, Store},
            {owner_type, bad}, {owner_default, {'_'}, bad}])}),
    Create = {assert, {instance_of, Class(amphibious), {'New'}}},
    try
        commit(Ctx, Ask(Store, conj([
            Create,
            {assertz, {instance_permission, {'New'}, place, deny}},
            {operation_authorized, {instance, {'New'}}, place},
            {assertz, {created, {'New'}}}]))),
        Query = Ask(Store, conj([{created, {'I'}},
            {instance_of, Class(amphibious), {'I'}},
            {attribute, {'I'}, name, <<"Vehicle">>},
            {attribute, {'I'}, wheels, 4}, {attribute, {'I'}, flag, good}])),
        ?assertMatch({ok, [_], _}, quod_lobby_tests:read(Ctx, Query)),
        ?assertMatch(fail, quod_lobby_tests:read(Ctx,
            Ask(Owner, {attribute, {'_'}, flag, good}))),
        ?assertMatch(fail, quod_lobby_tests:read(Ctx, Ask(Store,
            {',', {created, {'I'}}, {operation_authorized, {instance, {'I'}}, place}}))),
        lists:foreach(fun(Goal) ->
            ?assertMatch({ok, _, {normalized, {failed, _}}},
                quod_lobby_tests:submit(Ctx, execute, Ask(Store, Goal)))
        end, [{with_build_plan, [{attribute, flag, bad}], Create},
              {assert, {instance_of, Class(failing_child), {'_'}}},
              {with_build_plan, [{part, wheel, []}], Create}]),
        ?assertMatch({ok, _, {normalized, {error, proof_unavailable}}},
            quod_lobby_tests:submit(Ctx, execute, Ask(Store,
                {assert, {instance_of, Class(mutating_default), {'_'}}}))),
        ?assertMatch(fail, quod_lobby_tests:read(Ctx, Ask(Owner, leaked))),
        %% Invalid owner order remains invalid after qualifying its parent names.
        commit(Ctx, Ask(Owner, conj([
            {retract, {constructor_order, amphibious, [car, boat]}},
            {assertz, {constructor_order, amphibious, [car, boat | {'_'}]}}]))),
        ?assertMatch({ok, _, {normalized, {failed, _}}},
            quod_lobby_tests:submit(Ctx, execute, Ask(Store, Create))),
        commit(Ctx, Ask(Owner, conj([
            {retract, {constructor_order, amphibious, {'_'}}},
            {assertz, {constructor_order, amphibious, [car, boat]}}]))),
        Preflight = Ask(Store, {'$quod_constructor_plan', Class(amphibious), sample,
            [], {'Order'}, {'Attributes'}}),
        ?assertMatch({ok, [_], _}, quod_lobby_tests:read(Ctx, Preflight)),
        quod_lobby_tests:assert_read_has_no_io(fun() ->
            [?assertMatch({ok, [_], _}, quod_lobby_tests:read(Ctx, Preflight))
             || _ <- lists:seq(1, 3)]
        end),
        ?assertMatch({ok, [#{}], _}, quod_lobby_tests:read(Ctx, Ask(Store,
            {findall, {'I'}, {instance_of, Class(amphibious), {'I'}}, [{'_'}]})))
    after
        quod_lobby_tests:stop_process(StoreSup),
        quod_lobby_tests:stop_process(OwnerSup),
        quod_lobby_tests:stop(Ctx)
    end.

signed_owner_stores_defaults_and_reuses_reads_test_() ->
    {timeout, 120, fun signed_owner/0}.

signed_owner() ->
    Dir = filename:join("/tmp", "quod-constructors-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Ctx = quod_lobby_tests:start(Dir, [], extended_system_catalogue, []),
    {ontology_ref, Lobby, _} = maps:get(lobby, Ctx),
    {_, Base} = maps:get(Lobby, maps:get(ontologies, Ctx)),
    Ns = <<"constructor-target">>,
    Terms = quod_prolog:read_terms("test/fixtures/constructors.pl") ++
        [{can_invoke, {'_'}, {'_'}, {'_'}, Ns},
         {have_attribute, foreign_place, name, binary, {default_from, foreign_place_name}},
         {':-', {foreign_place_name, {'I'}, {'Name'}},
                {'::', {':', quod, names},
                 {draw, <<"landscape">>, <<"world">>, <<"neutral">>, {'I'}, {'Name'}}}}],
    {Sup, _} = quod_lobby_tests:start_namespace(Ns, Base#{
        data_dir => filename:join(Dir, "target"),
        genesis_diff => quod_prolog:terms_to_diff(Terms)}),
    Scope = fun(G) -> {'::', Ns, G} end,
    try
        %% The provider runs through the real cross-ontology proof owner while
        %% constructor preflight is read-only; the selected value is stored.
        commit(Ctx, Scope({transaction, {test_initialize, foreign_place, named_id}})),
        ?assertMatch({ok, [_], _}, quod_lobby_tests:read(Ctx, Scope(conj([
            {attribute, named_id, name, {'Name'}},
            {'::', {':', quod, names},
             {name, {'Name'}, <<"landscape">>, <<"world">>, <<"neutral">>}}])))),
        %% Test-only bound-identity composition; no live creation path is added.
        commit(Ctx, Scope({transaction, {test_initialize, amphibious, existing_id}})),
        Query = Scope({attribute, existing_id, name, <<"Vehicle">>}),
        ?assertMatch({ok, [_], _}, quod_lobby_tests:read(Ctx, Query)),
        quod_lobby_tests:assert_read_has_no_io(fun() ->
            [?assertMatch({ok, [_], _}, quod_lobby_tests:read(Ctx, Query))
             || _ <- lists:seq(1, 3)]
        end),
        commit(Ctx, Scope(conj([
            {retract, {have_attribute, vehicle, name, binary, {default, <<"Vehicle">>}}},
            {assertz, {have_attribute, vehicle, name, binary, {default, <<"Updated">>}}}]))),
        ?assertMatch({ok, [_], _}, quod_lobby_tests:read(Ctx, Query)),
        commit(Ctx, Scope({transaction, {test_initialize, trailer, second_id}})),
        ?assertMatch({ok, [_], _}, quod_lobby_tests:read(Ctx,
            Scope({attribute, second_id, name, <<"Updated">>}))),
        commit(Ctx, Scope(conj([{retract, {attribute, existing_id, name, {'_'}}},
                              {assertz, {attribute, existing_id, name, <<"Renamed">>}}]))),
        ?assertMatch({ok, [_], _}, quod_lobby_tests:read(Ctx,
            Scope(conj([{attribute, existing_id, name, <<"Renamed">>},
                        {attribute, existing_id, wheels, 4}])))),
        ?assertMatch({ok, _, {normalized, {failed, _}}}, quod_lobby_tests:submit(Ctx,
            execute, Scope({transaction, {test_initialize, failing_child, refused}}))),
        ?assertMatch(fail, quod_lobby_tests:read(Ctx,
            Scope({attribute, refused, {'_'}, {'_'}})))
    after quod_lobby_tests:stop_process(Sup), quod_lobby_tests:stop(Ctx) end.

commit(Ctx, Goal) ->
    {ok, Evidence, {normalized, {committed, _, _}}} =
        quod_lobby_tests:submit(Ctx, execute, Goal),
    Ref = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state := terminal},
        quod_ct:await_operation_complete(element(2, Ref), Ref, 10000)).

source(Name) -> quod_committed_projection:read_terms(
    filename:join(code:priv_dir(quod), "ontologies/" ++ Name)).

with_fixture(Extra, Fun) ->
    Terms = quod_committed_projection:read_terms("test/fixtures/constructors.pl"),
    with_terms(Terms ++ Extra, Fun).

with_terms(Terms, Fun) ->
    Base = load(Terms, quod_committed_projection:new_est()),
    Committed = quod_ct:commit_kb(Base),
    St = quod_erlog_db_local_prove:wrap_state(Committed, #{read_set => true}),
    try Fun(St)
    after quod_erlog_db_local_prove:cleanup_read_set(St),
          #est{db = #db{ref = Ref}} = Committed, quod_erlog_db_mvcc:delete(Ref) end.

load(Terms, #est{db = Db} = St) ->
    St#est{db = lists:foldl(fun erlog_int:assertz_clause/2, Db, Terms)}.
prove(Goal, St) -> {succeed, Next} = erlog_int:prove_goal(Goal, St), Next.
holds(Goal, St) -> ?assertMatch({succeed, _}, erlog_int:prove_goal(Goal, St)).
fails(Goal, St) -> ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St)).
refused(Goal, Inputs, Reason, St) ->
    {fail, Failed} = erlog_int:prove_goal({with_build_plan, Inputs, Goal}, St),
    ?assert(lists:member(Reason, Failed#est.fail_reasons)).
changes(#est{db = #db{ref = Ref}}) -> quod_erlog_db_local_prove:get_local_changes(Ref).
conj([Goal]) -> Goal;
conj([Goal | Rest]) -> {',', Goal, conj(Rest)}.
