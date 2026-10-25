-module(quod_assertion_construction_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

assertion_spellings_bind_full_ulids_before_constructors_test_() ->
    [?_test(with_state([{instance_of, amphibious, old}], fun(St) ->
        Before = quod_time:now_ms(),
        S = prove({Method, {instance_of, amphibious, {'Id'}}}, St),
        Id = binding('Id', S),
        assert_ulid(Id, Before, quod_time:now_ms()),
        holds({instance_of, amphibious, Id}, S),
        Ids = case Method of asserta -> [Id, old]; _ -> [old, Id] end,
        holds({findall, {'I'}, {instance_of, amphibious, {'I'}}, Ids}, S),
        holds({findall, {'C'}, {ran, {'C'}, Id, 4, []},
               [vehicle, car, boat, amphibious]}, S),
        holds({attribute, Id, name, <<"Vehicle">>}, S)
    end)) || Method <- [assert, asserta, assertz]].

parts_have_independent_ids_and_scoped_inputs_test() ->
    with_state([], fun(St) ->
        Inputs = [{attribute, name, <<"Outer">>},
                  {part, eye, [{attribute, name, <<"Inner">>}]}],
        S = prove({with_build_plan, Inputs, {assert, {instance_of, assembly, {'Id'}}}}, St),
        Parent = binding('Id', S),
        R = prove({parts, Parent, {'Left'}, {'Right'}}, S),
        Left = binding('Left', R), Right = binding('Right', R),
        ?assertEqual(3, length(lists:usort([Parent, Left, Right]))),
        holds({attribute, Parent, name, <<"Outer">>}, R),
        holds({attribute, Left, name, <<"Inner">>}, R),
        holds({attribute, Right, name, <<"Eye">>}, R),
        holds({'$quod_build_plan', []}, R)
    end).

constructors_do_not_use_already_true_goal_shortcut_test() ->
    with_state([], fun(St) ->
        S = prove({assert, {instance_of, checked, {'Id'}}}, St),
        holds({checked, binding('Id', S)}, S)
    end).

queries_rules_and_additional_classifications_are_inert_test() ->
    with_state([{instance_of, car, old}, {derived_identity, derived_only},
                {':-', {instance_of, derived, {'I'}}, {derived_identity, {'I'}}},
                {':-', {instance_of, derived, {'I'}}, {instance_of, car, {'I'}}}], fun(St) ->
        holds({instance_of, derived, old}, St),
        S = prove({assertz, {instance_of, failing_child, old}}, St),
        holds({instance_of, failing_child, old}, S),
        ?assertEqual(1, length(changes(S))),
        D = prove({assertz, {instance_of, failing_child, derived_only}}, St),
        ?assertEqual(1, length(changes(D))),
        R = prove({assertz, {':-', {instance_of, other, {'X'}}, {instance_of, car, {'X'}}}}, St),
        holds({instance_of, other, old}, R),
        ?assertEqual(1, length(changes(R))),
        F = refused({assert, {instance_of, car, chosen}}, St),
        ?assert(lists:member({creation_requires_output_variable, car}, F#est.fail_reasons)),
        ?assertEqual([], changes(F))
    end).

live_collision_refuses_without_overwriting_test() ->
    %% A real derived membership occupies every binary identity. This tests the
    %% collision check without mocking or weakening the secure generator.
    with_state([{':-', {instance_of, occupied, {'I'}}, {binary, {'I'}}}], fun(St) ->
        F = refused({assert, {instance_of, car, {'Id'}}}, St),
        ?assertEqual([], changes(F)),
        ?assert(lists:any(fun({instance_identity_collision, _}) -> true; (_) -> false end,
                         F#est.fail_reasons)),
        ?assertMatch({_}, binding('Id', F))
    end).

failure_and_exception_restore_effects_events_and_bindings_test_() ->
    [?_test(with_state([], fun(St) ->
        Goal = {assert, {instance_of, Class, {'Id'}}},
        F = case Class of
            exceptional ->
                {erlog_error, pinned_stateful_error, Clean} = catch erlog_int:prove_goal(Goal, St),
                %% Resume from the actual caught error state, as the owner does.
                Clean;
            _ -> refused(Goal, St)
        end,
        ?assertEqual([], changes(F)),
        ?assertEqual([], quod_erlog_db_local_prove:get_effects(ref(F))),
        ?assertMatch({_}, binding('Id', F)),
        holds({'$quod_build_plan', []}, F)
    end)) || Class <- [failing_child, parent_failure_child, bad_assembly, exceptional]].

constructor_alternatives_rollback_before_selecting_answer_test() ->
    with_state([], fun(St) ->
        S = prove({assert, {instance_of, alternatives, {'Id'}}}, St),
        holds({kept, binding('Id', S)}, S),
        fails(leaked, S),
        ?assertEqual([], quod_erlog_db_local_prove:get_effects(ref(S))),
        ?assertEqual([], [E || {event, E} <- changes(S)])
    end).

outer_action_and_transaction_backtracking_restore_complete_creation_test() ->
    with_state([], fun(St) ->
        Attempt = {transaction, conj([{assert, {instance_of, assembly, {'Id'}}}, fail])},
        S = prove({';', Attempt, {var, {'Id'}}}, St),
        ?assertEqual([], changes(S)),
        A = prove({goal, finished}, St),
        ?assertEqual([{assert, {finished, {[], false}}}], changes(A))
    end).

nested_creation_preserves_enclosing_choicepoint_rollback_test() ->
    with_state([], fun(St) ->
        Attempt = conj([{assert, {instance_of, assembly, {'Id'}}},
                        stage_fixture_effect, {trigger_event, discarded}, fail]),
        S = prove({transaction, {';', Attempt, {var, {'Id'}}}}, St),
        ?assertEqual([], changes(S)),
        ?assertEqual([], quod_erlog_db_local_prove:get_effects(ref(S))),
        ?assertMatch({_}, binding('Id', S))
    end).

founding_and_live_clauses_have_one_compiled_form_test_() ->
    [?_test(with_state([], fun(St) ->
        S = prove({assertz, Clause}, St),
        ?assertEqual(quod_prolog:terms_to_diff([Clause]), changes(S))
    end)) || Clause <- [{same, {'X'}, {'X'}, {'_'}},
                        {':-', {same, {'X'}, {'_'}}, {'=', {'X'}, known}}]].

authorization_uses_committed_requirements_and_inputs_test() ->
    with_state([{class_requirement, vehicle, create, needs_name},
                {':-', {needs_name, {'_'}, {'_'}, {create, {'Inputs'}}},
                       {member, {attribute, name, <<"Allowed">>}, {'Inputs'}}}], fun(St) ->
        F = refused({assert, {instance_of, car, {'Id'}}}, St),
        ?assertEqual([], changes(F)),
        holds({with_build_plan, [{attribute, name, <<"Allowed">>}],
               {assert, {instance_of, car, {'Id'}}}}, St)
    end),
    with_state([], fun(St) ->
        S = prove({assertz, {class_permission, forbidden, create, allow}}, St),
        F = refused({assert, {instance_of, forbidden, {'Id'}}}, S),
        ?assertEqual(changes(S), changes(F))
    end).

strict_readonly_assertions_remain_forbidden_test_() ->
    [?_test(with_state([{instance_of, car, old}], fun(St) ->
        {_, R} = quod_erlog_db_local_prove:enter_read_only(St),
        ?assertMatch({erlog_error, {permission_error, modify, static_procedure, _}},
                     catch erlog_int:prove_goal({Method, {instance_of, car, {'Id'}}}, R)),
        ?assertEqual([], changes(R)),
        fails({'$quod_instance_id', {'Id'}}, R)
    end)) || Method <- [assert, asserta, assertz]].

founding_compilation_and_apply_restore_without_construction_test() ->
    Terms = [{instance_of, exceptional, <<"01ARZ3NDEKTSV4RRFFQ69G5FAV">>},
             {instance_of, car, {'RuleVariable'}},
             {attribute, <<"01ARZ3NDEKTSV4RRFFQ69G5FAV">>, name, <<"Saved">>}],
    Ops = quod_prolog:terms_to_diff(Terms),
    ?assertEqual(3, length(Ops)),
    with_state([], fun(St) ->
        Base = quod_erlog_db_local_prove:committed_state(St),
        {ok, Applied} = quod_diff:apply_ops(Base, Ops),
        R = quod_erlog_db_local_prove:wrap_state(Applied),
        holds({attribute, <<"01ARZ3NDEKTSV4RRFFQ69G5FAV">>, name, <<"Saved">>}, R),
        ?assertEqual([], changes(R))
    end).

concurrent_creations_use_distinct_secure_ids_test() ->
    Parent = self(),
    Workers = [spawn_monitor(fun() -> with_state([], fun(St) ->
        S = prove({assert, {instance_of, car, {'Id'}}}, St),
        Parent ! {self(), binding('Id', S)}
    end) end) || _ <- lists:seq(1, 16)],
    Ids = [receive {Pid, Id} -> Id after 10000 -> error(creation_timeout) end
           || {Pid, _} <- Workers],
    [receive {'DOWN', Ref, process, Pid, normal} -> ok
     after 10000 -> error(worker_timeout) end || {Pid, Ref} <- Workers],
    ?assertEqual(16, length(lists:usort(Ids))).

with_state(Extra, Fun) ->
    Base0 = quod_ct:action_kb(<<>>, [],
        quod_prolog:read_terms("test/fixtures/constructors.pl") ++ fixture() ++ Extra),
    #est{db = Db0} = Base0,
    Db1 = erlog_int:add_compiled_proc({stage_fixture_effect, 0},
        quod_action_savepoint_tests, stage_fixture_effect_0, Db0),
    Db2 = erlog_int:add_compiled_proc({stateful_fixture_error, 0},
        quod_action_savepoint_tests, stateful_fixture_error_0, Db1),
    Base = Base0#est{db = Db2},
    Handle = quod_proof_context:start(crypto:strong_rand_bytes(32), false,
        {<<"construction:test">>, <<1:256>>}, quod_time:mono_ms() + 60000, anonymous),
    Session = quod_proof_session:start(Base, #{read_set => true,
                                              proof_context => {origin, Handle}}),
    I = crypto:strong_rand_bytes(16),
    Ctx = quod_predicates:proof_context(<<"construction:test">>, 1, undefined),
    ok = quod_proof_session:open(Session, I, true, allowed, Ctx,
                                quod_transaction_scope:empty_selection()),
    {ok, St} = quod_proof_session:test_invocation_state(Session, I),
    try Fun(St)
    after quod_proof_session:stop(Session),
          quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end),
          quod_erlog_db_mvcc:delete(ref(Base)) end.

fixture() ->
    {ok, Terms} = erlog_io:read_string_terms(
      "class_permission(vehicle, create, allow). "
      "class_permission(eye, create, allow). "
      "class_permission(assembly, create, allow). "
      "class_permission(exceptional, create, allow). "
      "class_permission(alternatives, create, allow). "
      "class_permission(checked, create, allow). "
      "class_permission(failing_parent, create, allow). "
      "have_part(assembly, eye). "
      "constructor(assembly, I, Inputs) :- "
      "build_plan_part(Inputs, eye, Eye), "
      "with_build_plan(Eye, assert(instance_of(eye, L))), "
      "assertz(instance_of(eye, R)), assertz(parts(I,L,R)). "
      "isa(bad_assembly, assembly). "
      "constructor(bad_assembly, _, _) :- "
      "stage_fixture_effect, trigger_event(discarded), assert(instance_of(failing_child, _)). "
      "constructor(exceptional, I, _) :- "
      "assertz(leaked(I)), stage_fixture_effect, trigger_event(discarded), stateful_fixture_error. "
      "constructor(alternatives, I, _) :- "
      "(assertz(leaked), stage_fixture_effect, trigger_event(discarded), fail; assertz(kept(I))). "
      "constructor(checked, I, _) :- instance_of(checked,I), assertz(checked(I))."),
    Terms ++ [{action, {assert, {instance_of, assembly, {'_'}}}, [], finished},
              {action, {assertz, finished}, [], finished}].

conj([G]) -> G;
conj([G | Rest]) -> {',', G, conj(Rest)}.
prove(G, St) -> {succeed, S} = erlog_int:prove_goal(G, St), S.
refused(G, St) -> {fail, S} = erlog_int:prove_goal(G, St), S.
holds(G, St) -> ?assertMatch({succeed, _}, erlog_int:prove_goal(G, St)).
fails(G, St) -> ?assertMatch({fail, _}, erlog_int:prove_goal(G, St)).
ref(#est{db = #db{ref = Ref}}) -> Ref.
changes(St) -> quod_erlog_db_local_prove:get_local_changes(ref(St)).
binding(V, St) -> erlog_int:dderef({V}, St#est.bs).
assert_ulid(Id, Low, High) ->
    ?assertEqual(26, byte_size(Id)),
    Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ",
    Value = lists:foldl(fun(C, Acc) ->
        ?assert(lists:member(C, Alphabet)),
        Acc * 32 + length(lists:takewhile(fun(X) -> X =/= C end, Alphabet))
    end, 0, binary_to_list(Id)),
    ?assert(Value < (1 bsl 128)),
    Time = Value bsr 80,
    ?assert(Time >= Low), ?assert(Time =< High).
