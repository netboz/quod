-module(quod_common_primitives_tests).

%% `'$quod_draw'/3` and `binary_codes/2` on the base engine every ontology
%% starts from. The draw runs inside real proof sessions: an origin session
%% with a started proof context, a scope session carrying the same proof id,
%% and the contexts where it must refuse (no proof, verdict engines).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_vm_limits.hrl").

-define(NS, <<"test:primitives">>).
-define(DRAW, '$quod_draw').

voxel_primitive_is_pure_and_preserves_unification_test() ->
    with_authored([],fun(St) ->
        Request = {sample,{field_v1,1,500,[{plane,250}],7},
                   {vector,0,0,0},{dimensions,2,2,2}},
        Limits = {sampling_limits,8,8,0,24},
        Result = value({'Samples'},{'$quod_voxel',Request,Limits,{'Samples'}},St),
        ?assertMatch({samples_v1,<<_:64>>,<<_:128>>},Result),
        ?assertMatch({succeed,_},erlog_int:prove_goal({'$quod_voxel',Request,Limits,Result},St)),
        ?assertMatch({fail,_},erlog_int:prove_goal({'$quod_voxel',Request,Limits,wrong},St)),
        ?assertMatch({erlog_error,instantiation_error,_},catch erlog_int:prove_goal(
            {'$quod_voxel',{'Request'},Limits,{'Samples'}},St)),
        ?assertEqual([],quod_erlog_db_local_prove:get_local_changes(db_ref(St)))
    end).

agent_request_bytes_are_inert_exact_intent_test() ->
    with_authored([], fun(St) ->
        Agent = {agent_instance_ref, ?NS, <<2:256>>, {worker, <<"one">>}},
        Intent = {agent_goal_v1, <<1:256>>, Agent, <<"worker(<<\"one\">>).">>,
                  <<3:256>>, <<4:256>>, 123456, execute, 3, <<"save(42).">>},
        Bytes = value({'B'}, {agent_request_bytes, Intent, {'B'}}, St),
        {ok, Request} = quod_client_goal:decode(Bytes),
        ?assertMatch(#{agent_namespace := ?NS, agent_genesis_anchor := <<2:256>>,
                       signing_public_key := <<3:256>>, operation_id := <<4:256>>,
                       not_after_ms := 123456, mode := execute, goal_text := <<"save(42).">>}, Request),
        ?assertEqual(Bytes, value({'B'}, {agent_request_bytes, Intent, {'B'}}, St)),
        ?assertEqual(Intent, value({'T'}, {agent_request_bytes, {'T'}, Bytes}, St)),
        ?assertMatch({fail, _}, erlog_int:prove_goal({agent_request_bytes, Intent, <<>>}, St)),
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(St))),
        lists:foreach(fun(Bad) ->
            ?assertMatch({erlog_error, {domain_error, agent_request, Bad}, _},
                catch erlog_int:prove_goal({agent_request_bytes, Bad, {'B'}}, St))
        end, [setelement(4, Intent, <<"worker(<<\"two\">>).">>),
              setelement(5, Intent, <<>>), setelement(7, Intent, -1),
              setelement(8, Intent, unknown_mode),
              setelement(9, Intent, 4), arbitrary]),
        ?assertMatch({erlog_error, instantiation_error, _},
            catch erlog_int:prove_goal(
                {agent_request_bytes, setelement(6, Intent, {'Id'}), {'B'}}, St))
    end).

signed_request_verification_is_data_not_authority_test() ->
    {Key, _} = Pair = quod_identity:generate(),
    Intent = {agent_goal_v1, <<1:256>>, {agent_instance_ref, ?NS, <<2:256>>, actor},
              <<"actor.">>, Key, <<4:256>>, 123456, execute, 3, <<"save(42).">>},
    {ok, _, Bytes} = quod_client_goal:encode_typed(Intent),
    Signature = quod_identity:sign(Bytes, quod_identity:key_term(Pair)),
    with_authored([], fun(St) ->
        %% No key or policy facts are installed, and the signed expiry is past.
        %% This pure verifier establishes only the exact authenticated data.
        ?assertEqual(Intent, value({'T'}, {signed_agent_request, Bytes, Signature, {'T'}}, St)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
            {signed_agent_request, Bytes, <<0:512>>, {'T'}}, St)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
            {signed_agent_request, Bytes, Signature, setelement(6, Intent, <<5:256>>)}, St)),
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(St)))
    end).

binary_type_test() ->
    St = bare(),
    ?assertMatch({succeed, _}, erlog_int:prove_goal({binary, <<>>}, St)),
    lists:foreach(fun(Value) ->
        ?assertMatch({fail, _}, erlog_int:prove_goal({binary, Value}, St))
    end, [42, text, "text", {compound, text}, {'Unbound'}]),
    ?assertMatch({succeed, _}, erlog_int:prove_goal(
        {',', {'\\+', {binary, {'Value'}}}, {var, {'Value'}}}, St)).

ontology_name_uses_selector_grammar_test() ->
    St = bare(),
    lists:foreach(fun(Name) ->
        ?assertEqual(<<"quod:gui">>,
                     value({'N'}, {ontology_name, Name, {'N'}}, St))
    end, [<<"quod:gui">>, 'quod:gui', "quod:gui", {':', quod, gui}]),
    ?assertEqual(<<"a:b:c">>, value({'N'},
        {ontology_name, {':', {':', a, b}, c}, {'N'}}, St)),
    ?assertEqual(<<"a:b:c">>, value({'N'},
        {ontology_name, {':', a, {':', b, c}}, {'N'}}, St)),
    ?assertMatch({fail, _}, erlog_int:prove_goal(
        {ontology_name, {':', quod, gui}, <<"quod:other">>}, St)),
    ?assertMatch({erlog_error, instantiation_error, _},
        catch erlog_int:prove_goal({ontology_name, {':', quod, {'N'}}, {'B'}}, St)).

term_digest_test() ->
    with_authored([],fun(St) ->
        Digest = value({'D'},{term_digest,{geometry,{ball,500},1},{'D'}},St),
        ?assertMatch(<<_:256>>,Digest),
        ?assertEqual(Digest,value({'D'},
            {term_digest,{{'$quod_symbol',<<"geometry">>},{{'$quod_symbol',<<"ball">>},500},1},{'D'}},St)),
        ?assertNotEqual(Digest,value({'D'},{term_digest,{geometry,{ball,501},1},{'D'}},St)),
        ?assertMatch({erlog_error,instantiation_error,_},
            catch erlog_int:prove_goal({term_digest,{geometry,{'Shape'},1},{'D'}},St))
    end).

variant_digest_preserves_variable_sharing_without_binding_test() ->
    with_authored([], fun(St) ->
        Digest = value({'D'}, {variant_digest, {fields, {'X'}, {'X'}}, {'D'}}, St),
        ?assertEqual(Digest, value({'D'},
            {variant_digest, {fields, {'Renamed'}, {'Renamed'}}, {'D'}}, St)),
        ?assertNotEqual(Digest, value({'D'},
            {variant_digest, {fields, {'X'}, {'Y'}}, {'D'}}, St)),
        ?assertNotEqual(Digest, value({'D'},
            {variant_digest, {fields, {'$VAR', 0}, {'$VAR', 0}}, {'D'}}, St)),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
            {',', {variant_digest, {fields, {'X'}}, {'D'}}, {var, {'X'}}}, St)),
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(St)))
    end).

binary_codes_test() ->
    St = bare(),
    ?assertEqual([$U, $g], value({'C'}, {binary_codes, <<"Ug">>, {'C'}}, St)),
    ?assertEqual(<<"Ug">>, value({'B'}, {binary_codes, {'B'}, [$U, $g]}, St)),
    ?assertEqual([], value({'C'}, {binary_codes, <<>>, {'C'}}, St)),
    ?assertEqual(<<>>, value({'B'}, {binary_codes, {'B'}, []}, St)),
    ?assertEqual(<<0, 255>>, value({'B'}, {binary_codes, {'B'}, [0, 255]}, St)),
    ?assertMatch({succeed, _},
                 erlog_int:prove_goal({binary_codes, <<"Ug">>, [$U, $g]}, St)),
    ?assertMatch({fail,_},erlog_int:prove_goal({binary_codes,<<"Ug">>,[$U]},St)),
    lists:foreach(fun({Goal,Error}) ->
        ?assertMatch({erlog_error,Error,_},catch erlog_int:prove_goal(Goal,St))
    end,[{{binary_codes,ug,{'C'}},{type_error,binary,ug}},
         {{binary_codes,42,{'C'}},{type_error,binary,42}},
         {{binary_codes,[$U],{'C'}},{type_error,binary,[$U]}},
         {{binary_codes,{'B'},[300]},{domain_error,byte_list,[300]}},
         {{binary_codes,{'B'},[-1]},{domain_error,byte_list,[-1]}},
         {{binary_codes,{'B'},[a]},{domain_error,byte_list,[a]}},
         {{binary_codes,{'B'},foo},{type_error,list,foo}},
         {{binary_codes,{'B'},[$U|{'T'}]},instantiation_error},
         {{binary_codes,{'B'},{'C'}},instantiation_error}]).

source_chunk_empty_source_test() ->
    {ok, Engine} = erlog:new(quod_erlog_db_mvcc, null),
    #est{db = Db} = St0 = element(3, Engine),
    EmptyDb = lists:foldl(fun erlog_int:abolish_clauses/2, Db,
                          [{delete, 3}, {last, 2}, {perm, 2}, {phrase, 2}]),
    #db{ref = EmptyRef} = EmptyDb,
    St1 = quod_common_primitives:load(
            St0#est{db = EmptyDb#db{
                      ref = quod_erlog_db_mvcc:publish_base(EmptyRef)}}),
    St = quod_erlog_db_local_prove:wrap_state(St1),
    try
        ?assertEqual({source_chunk, done, <<>>}, value({'Chunk'},
            {'$quod_source_chunk', all, 4096, {'Chunk'}}, St))
    after
        quod_erlog_db_mvcc:delete(EmptyRef)
    end.

source_chunk_full_source_test() ->
    with_authored([{source_chunk_marker, preserved}], fun(St) ->
        {source_chunk, done, Text} = value({'Chunk'},
            {'$quod_source_chunk', all, 1048576, {'Chunk'}}, St),
        ?assertNotEqual(nomatch, binary:match(
            Text, <<"source_chunk_marker(preserved) :- true.\n">>)),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
            {'$quod_source_chunk', all, 4096,
             {source_chunk, done, <<"different">>}}, St))
    end).

source_chunk_argument_errors_test() ->
    St = bare(),
    lists:foreach(fun({Bytes, Error}) ->
        ?assertMatch({erlog_error, Error, _}, catch erlog_int:prove_goal(
            {'$quod_source_chunk', all, Bytes, {'Chunk'}}, St))
    end, [{{'Bytes'}, instantiation_error},
          {bytes, {type_error, integer, bytes}},
          {0, {domain_error, source_chunk_bytes, 0}},
          {-1, {domain_error, source_chunk_bytes, -1}}]).

filtered_source_uses_the_same_chunker_and_records_absence_test() ->
    with_authored([{chosen, first}, {chosen, second}, {hidden, secret}], fun(St) ->
        Selection = {predicates, [{'/', chosen, 1}, {'/', absent_policy, 4}]},
        Goal = {findall, {'Chunk'}, {'$quod_source_chunk', Selection, 7, {'Chunk'}}, {'Chunks'}},
        Chunks = value({'Chunks'}, Goal, St),
        ?assertEqual(done, element(2, lists:last(Chunks))),
        ?assert(lists:all(fun({source_chunk, _, B}) -> byte_size(B) =< 7 end, Chunks)),
        ?assertEqual(<<"chosen(first) :- true.\nchosen(second) :- true.\n">>,
                     iolist_to_binary([B || {source_chunk, _, B} <- Chunks])),
        ?assert(maps:is_key({absent_policy, 4},
            quod_erlog_db_local_prove:get_read_set(db_ref(St)))),
        ?assertEqual({source_chunk, done, <<"route_status(live, unavailable).\n">>},
            value({'Chunk'}, {'$quod_source_chunk',
                {terms, [{route_status, live, unavailable}]}, 4096, {'Chunk'}}, St))
    end).

shared_framework_source_keeps_local_edit_semantics_test() ->
    with_authored([], fun(St) ->
        %% Framework availability does not install an application API or state.
        ?assertMatch([_], authored({gui_compile, 6}, St)),
        [BodySchema] = authored({physics_valid_body, 6}, St),
        ?assertMatch({fail,_},erlog_int:prove_goal({physics_world_position,
            {':',foreign_geometry,{vector,1,2,3}}},St)),
        [?assertEqual([], authored(F, St)) || F <-
            [{ontology_interface, 2}, {gui_question, 6}, {can_invoke, 4},
             {physics_space, 3}, {physics_body_definition, 6}]],
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(St))),
        %% Source edits use the same local overlay as every common predicate;
        %% they cannot mutate a different owner or the retained base snapshot.
        {succeed, Edited} = erlog_int:prove_goal({'$quod_retract_exact', BodySchema}, St),
        ?assertEqual([], authored({physics_valid_body, 6}, Edited)),
        ?assertEqual([BodySchema], authored({physics_valid_body, 6}, St)),
        with_authored([], fun(Other) ->
            ?assertEqual([BodySchema], authored({physics_valid_body, 6}, Other))
        end)
    end).

authored_clauses_hide_followers_and_preserve_scope_test() ->
    with_authored([{choice, first}, {choice, second}], fun(St) ->
        ?assertEqual([{':-', {choice, first}, true},
                      {':-', {choice, second}, true}],
                     authored({choice, 1}, St)),
        ?assertEqual([], authored({missing, 1}, St)),
        %% Introspection does not disable following for the rest of the proof.
        Goal = {',', {'$quod_predicate_source', {'/', choice, 1}, {'Source'}},
                {findall, {'H'}, {clause, {choice, {'H'}}, {'Body'}}, {'Heads'}}},
        ?assertEqual(4, length(value({'Heads'}, Goal, St))),
        Reads = quod_erlog_db_local_prove:get_read_set(db_ref(St)),
        ?assert(maps:is_key({choice, 1}, Reads)),
        ?assert(maps:is_key({missing, 1}, Reads)),
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(St)))
    end).

authored_clauses_fresh_variables_and_control_bodies_test() ->
    X = {'X'}, Y = {'Y'},
    Body = {',', {pair, X, Y}, {',', '!', {';', {left, Y}, {right, X}}}},
    with_authored([{':-', {shared, X}, Body}, {':-', {shared, X}, {pair, X, X}}],
      fun(St) ->
          [First, Second] = authored({shared, 1}, St),
          ?assertEqual(canonical_source({':-', {shared, X}, Body}),
                       canonical_source(First)),
          ?assertEqual(canonical_source({':-', {shared, X}, {pair, X, X}}),
                       canonical_source(Second)),
          {':-', {shared, FirstVariable}, _} = First,
          {':-', {shared, SecondVariable}, _} = Second,
          ?assertNotEqual(FirstVariable, SecondVariable),
          %% Caller variables cannot alias the fresh variables in returned code.
          Goal = {',', {'=', {'Caller'}, untouched},
                  {',', {'$quod_predicate_source', {'/', shared, 1}, {'Source'}},
                   {',', {'$quod_program_source', [
                          {':-', {shared, {'V'}}, {'B'}}, {'Other'}], {'Source'}},
                    {'=', {'V'}, bound}}}},
          ?assertEqual(untouched, value({'Caller'}, Goal, St))
      end).

exact_retract_does_not_remove_general_clause_test() ->
    with_authored([{choice, {'X'}}, {choice, specific}], fun(St) ->
        {succeed, Final} = erlog_int:prove_goal(
                            {'$quod_retract_exact', {choice, specific}}, St),
        [Remaining] = authored({choice, 1}, Final),
        ?assertEqual(canonical_source({':-', {choice, {'X'}}, true}),
                     canonical_source(Remaining)),
        ?assertEqual([{retract, {{choice, specific}, {[], false}}}],
                     quod_erlog_db_local_prove:get_local_changes(db_ref(Final))),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
                                  {'$quod_retract_exact', {choice, specific}}, Final))
    end).

exact_retract_preserves_variable_sharing_test() ->
    X = {'X'}, Y = {'Y'},
    General = {':-', {pair, X, Y}, {same, X, Y}},
    Specific = {':-', {pair, X, X}, {same, X, X}},
    with_authored([General, Specific], fun(St) ->
        Z = {'Renamed'},
        {succeed, Final} = erlog_int:prove_goal(
          {'$quod_retract_exact', {':-', {pair, Z, Z}, {same, Z, Z}}}, St),
        ?assertEqual([canonical_source(General)],
                     [canonical_source(C) || C <- authored({pair, 2}, Final)])
    end).

exact_retract_compiler_control_forms_test() ->
    X = {'X'}, Tail = {'Tail'},
    Bodies = [{once, {same, X, X}},
              {'->', {condition, X}, {then_do, X}},
              {';', {'->', {condition, X}, {then_do, X}}, {otherwise, X}},
              {',', {items, [X | Tail]}, {',', '!', {rest, Tail}}}],
    lists:foreach(fun(Body) ->
        Rule = {':-', {control_example, X}, Body},
        with_authored([Rule], fun(St) ->
            ?assertEqual([canonical_source(Rule)],
              [canonical_source(C) || C <- authored({control_example, 1}, St)]),
            {succeed, Final} = erlog_int:prove_goal({'$quod_retract_exact', Rule}, St),
            ?assertEqual([], authored({control_example, 1}, Final))
        end)
    end, Bodies).

exact_retract_accepts_existing_opaque_symbols_test() ->
    with_authored([{choice, wood}], fun(St) ->
        Opaque = {'$quod_symbol', <<"wood">>},
        ?assertEqual(<<"choice(wood) :- true.\n">>,
          value({'Source'}, {'$quod_predicate_source',
                 {'/', {'$quod_symbol', <<"choice">>}, 1}, {'Source'}}, St)),
        {succeed, Final} = erlog_int:prove_goal(
          {'$quod_retract_exact', {choice, Opaque}}, St),
        ?assertEqual([], authored({choice, 1}, Final))
    end).

authored_cold_predicate_has_empty_baseline_without_atom_allocation_test() ->
    Name = <<"editor_new_predicate_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    with_authored([], fun(St) ->
        ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
        ?assertEqual([], authored({{'$quod_symbol', Name}, 2}, St)),
        ?assertError(badarg, binary_to_existing_atom(Name, utf8))
    end).

admitted_cold_absence_guard_records_read_test() ->
    Name = <<"source_guard_", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    with_authored([], fun(St) ->
        ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
        Goal = {'\\+', {{'$quod_symbol', Name}, {'X'}, {'Y'}, {'Z'}}},
        {ok, Admitted} = quod_wire_term:materialize_goal_symbols(Goal),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(Admitted, St)),
        Functor = {binary_to_existing_atom(Name, utf8), 3},
        ?assert(maps:is_key(Functor, quod_erlog_db_local_prove:get_read_set(db_ref(St)))),
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(St)))
    end).

predicate_source_compares_bound_text_without_parsing_or_unifying_code_test() ->
    with_authored([{choice, {'X'}}], fun(St) ->
        Source = value({'Source'}, {'$quod_predicate_source', {'/', choice, 1}, {'Source'}}, St),
        ?assertMatch({succeed, _}, erlog_int:prove_goal(
            {'$quod_predicate_source', {'/', choice, 1}, Source}, St)),
        lists:foreach(fun(Other) ->
            ?assertMatch({fail, _}, erlog_int:prove_goal(
                {'$quod_predicate_source', {'/', choice, 1}, Other}, St))
        end, [<<"choice(specific) :- true.\n">>, <<"choice(.\n">>,
              <<"choice(Renamed).\n">>]),
        ?assert(maps:is_key({choice, 1}, quod_erlog_db_local_prove:get_read_set(db_ref(St))))
    end).

authored_introspection_and_exact_retract_include_staged_clauses_test() ->
    with_authored([{choice, original}], fun(St) ->
        Goal = {',', {asserta, {choice, first}},
                {',', {assertz, {choice, last}},
                 {'$quod_retract_exact', {choice, first}}}},
        {succeed, Final} = erlog_int:prove_goal(Goal, St),
        ?assertEqual([{':-', {choice, original}, true},
                      {':-', {choice, last}, true}], authored({choice, 1}, Final)),
        ?assertEqual([{assert, {{choice, last}, {[], false}}}],
                     quod_erlog_db_local_prove:get_local_changes(db_ref(Final)))
    end).

exact_retract_transaction_rollback_retains_reads_test() ->
    with_authored([{choice, original}], fun(St) ->
        Goal = {';', {transaction,
                       {',', {'$quod_retract_exact', {choice, original}}, fail}},
                true},
        {succeed, Final} = erlog_int:prove_goal(Goal, St),
        ?assertEqual([{':-', {choice, original}, true}], authored({choice, 1}, Final)),
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(Final))),
        ?assert(maps:is_key({choice, 1},
                  quod_erlog_db_local_prove:get_read_set(db_ref(Final))))
    end).

exact_retract_refuses_read_only_session_test() ->
    with_authored([{choice, original}], fun(St) ->
        {_Frame, ReadOnly} = quod_erlog_db_local_prove:enter_read_only(St),
        ?assertThrow({erlog_error, {permission_error, modify, static_procedure,
                                    {'/', choice, 1}}},
                     erlog_int:prove_goal(
                       {'$quod_retract_exact', {choice, original}}, ReadOnly)),
        ?assertEqual([{':-', {choice, original}, true}], authored({choice, 1}, St))
    end).

program_source_preserves_independent_clause_variables_test() ->
    with_authored([], fun(St) ->
        Text = <<"pair(X, X). pair(X, Y) :- once(same(X, Y)).">>,
        [First, Second] = value({'Program'},
          {'$quod_program_source', {'Program'}, Text}, St),
        {pair, A, A} = First,
        {':-', {pair, B, C}, {once, {same, B, C}}} = Second,
        ?assertNotEqual(A, B),
        ?assertNotEqual(B, C),
        Printed = value({'Source'}, {'$quod_program_source', [First, Second], {'Source'}}, St),
        Again = value({'Program'}, {'$quod_program_source', {'Program'}, Printed}, St),
        ?assertEqual([canonical_source(First), canonical_source(Second)],
                     [canonical_source(Clause) || Clause <- Again]),
        ?assertEqual([], value({'Program'},
          {'$quod_program_source', {'Program'}, <<"% Empty program\n">>}, St)),
        ?assertEqual(<<>>, value({'Source'}, {'$quod_program_source', [], {'Source'}}, St)),
        ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(St)))
    end).

program_source_does_not_allocate_callable_or_data_atoms_test() ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Name = <<"quod_edit_callable_", Suffix/binary>>,
    Datum = <<"quod_edit_datum_", Suffix/binary>>,
    Text = <<Name/binary, "(", Datum/binary, ").">>,
    with_authored([], fun(St) ->
        [Clause] = value({'Program'}, {'$quod_program_source', {'Program'}, Text}, St),
        ?assertEqual({{'$quod_symbol', Name}, {'$quod_symbol', Datum}}, Clause),
        ?assertError(badarg, binary_to_existing_atom(Name, utf8)),
        ?assertError(badarg, binary_to_existing_atom(Datum, utf8))
    end).

program_source_large_draft_still_allocates_no_atoms_test() ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Names = [<<"quod_edit_budget_", Suffix/binary, "_", (integer_to_binary(N))/binary>>
             || N <- lists:seq(1, ?QUOD_MAX_NEW_MATERIAL_ATOMS + 1)],
    Text = iolist_to_binary([[Name, ".\n"] || Name <- Names]),
    with_authored([], fun(St) ->
        Clauses = value({'Program'}, {'$quod_program_source', {'Program'}, Text}, St),
        ?assertEqual(length(Names), length(Clauses)),
        ?assertError(badarg, binary_to_existing_atom(hd(Names), utf8)),
        ?assertError(badarg, binary_to_existing_atom(lists:last(Names), utf8))
    end).

program_source_reports_syntax_errors_test() ->
    with_authored([], fun(St) ->
        {fail, Refused} = erlog_int:prove_goal(
            {'$quod_program_source', {'Program'}, <<"broken(.">>}, St),
        ?assert(lists:member({syntax_error, invalid_syntax}, Refused#est.fail_reasons))
    end).

origin_draw_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    with_committed(fun(Committed) ->
        with_origin(ProofId, fun() ->
            Draw = fun(Salt, N) ->
                           draw(Committed, {origin, test}, Salt, N)
                   end,
            ?assertEqual(expected(ProofId, salt, 10), Draw(salt, 10)),
            ?assertEqual(Draw(salt, 10), Draw(salt, 10)),
            ?assertEqual(expected(ProofId, {agent, 1, [x]}, 1000),
                         Draw({agent, 1, [x]}, 1000)),
            ?assertEqual(0, Draw(salt, 1)),
            ?assert(lists:all(fun(I) -> I >= 0 andalso I < 7 end,
                              [Draw(S, 7) || S <- lists:seq(1, 20)])),
            Spread = [Draw(S, 1000000) || S <- lists:seq(1, 8)],
            ?assert(length(lists:usort(Spread)) > 1),
            %% The wrapper every ontology calls.
            ?assertEqual(Draw(salt, 10),
                         solve(Committed, {origin, test},
                               {proof_draw, salt, 10, {'I'}}, 'I')),
            %% Backtracking re-asks the same question and gets the same answer.
            ?assertEqual([Draw(s, 100), Draw(s, 100)],
                         solve(Committed, {origin, test},
                               {findall, {'I'},
                                {';', {?DRAW, s, 100, {'I'}},
                                 {?DRAW, s, 100, {'I'}}}, {'L'}}, 'L'))
        end)
    end).

scope_draw_matches_origin_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Scope = {scope, ProofId, self(), make_ref(), <<1:128>>},
    with_committed(fun(Committed) ->
        ?assertEqual(expected(ProofId, salt, 10),
                     draw(Committed, Scope, salt, 10)),
        with_origin(ProofId, fun() ->
            ?assertEqual(draw(Committed, {origin, test}, salt, 10),
                         draw(Committed, Scope, salt, 10))
        end)
    end).

refuses_outside_a_proof_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Scope = {scope, ProofId, self(), make_ref(), <<1:128>>},
    Goal = {?DRAW, salt, 10, {'I'}},
    with_committed(fun(Committed) ->
        %% No session metadata at all, and an origin whose proof context was
        %% never started.
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, undefined, proof_ctx(), Goal)),
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, {origin, test}, proof_ctx(), Goal)),
        %% Verdict engines never draw, whatever the session carries.
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, Scope,
                             quod_predicates:verdict_context(?NS, 1), Goal)),
        ?assertEqual(fail, quod_ct:session_prove(
                             Committed, Scope,
                             quod_predicates:policy_verdict_context(?NS, 1),
                             Goal)),
        %% A bare engine without any session fails plainly too.
        ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, bare())),
        ?assertMatch({fail, _}, erlog_int:prove_goal(
                                  {proof_draw, salt, 10, {'I'}}, bare()))
    end).

invalid_inputs_are_errors_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Scope = {scope, ProofId, self(), make_ref(), <<1:128>>},
    with_committed(fun(Committed) ->
        lists:foreach(fun({Goal,Error}) ->
            ?assertMatch({error,{erlog,Error}},quod_ct:session_prove(Committed,Scope,proof_ctx(),Goal))
        end,[{{?DRAW,salt,0,{'I'}},{domain_error,proof_draw_divisor,0}},
             {{?DRAW,salt,-3,{'I'}},{domain_error,proof_draw_divisor,-3}},
             {{?DRAW,salt,ten,{'I'}},{type_error,integer,ten}},
             {{?DRAW,salt,{'N'},{'I'}},instantiation_error},
             {{?DRAW,{'Salt'},10,{'I'}},instantiation_error},
             {{?DRAW,{f,{'X'}},10,{'I'}},instantiation_error},
             {{?DRAW,[a|{'T'}],10,{'I'}},instantiation_error}]),
        ?assertEqual(fail,quod_ct:session_prove(Committed,Scope,proof_ctx(),{?DRAW,salt,10,99})),
        %% A ground compound salt, and a bound I that matches, succeed.
        I = draw(Committed, Scope, {f, [1, <<"b">>, c]}, 10),
        ?assertMatch({ok, _}, quod_ct:session_prove(
                                Committed, Scope, proof_ctx(),
                                {?DRAW, {f, [1, <<"b">>, c]}, 10, I}))
    end).

%% Symbol admission counts semantic names equally in warm and cold VMs.
symbol_vocabulary_is_independent_of_loaded_modules_test() ->
    Name = <<"quod_material_warm_cold_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Cold = {{'$quod_symbol', Name}, x},
    {ok, Before} = quod_wire_term:symbol_names(Cold),
    ?assertEqual(lists:sort([Name, <<"x">>]), Before),
    {ok, Warm} = quod_wire_term:materialize_symbols(Cold),
    ?assertEqual({ok, Before}, quod_wire_term:symbol_names(Warm)),
    ?assertEqual({ok, Before}, quod_wire_term:symbol_names(Cold)).

%% --- helpers ---------------------------------------------------------------

expected(ProofId, Salt, N) ->
    {ok, Bytes} = quod_wire_term:encode_canonical(Salt),
    binary:decode_unsigned(crypto:mac(hmac, sha256, ProofId, Bytes)) rem N.

draw(Committed, Metadata, Salt, N) ->
    solve(Committed, Metadata, {?DRAW, Salt, N, {'I'}}, 'I').

solve(Committed, Metadata, Goal, Var) ->
    {ok, Bindings} = quod_ct:session_prove(
                       Committed, Metadata, proof_ctx(), Goal),
    maps:get(Var, Bindings).

proof_ctx() -> quod_predicates:proof_context(?NS, 1, undefined).

with_origin(ProofId, Fun) ->
    _ = quod_proof_context:start(
          ProofId, false, {?NS, <<0:256>>},
          quod_time:mono_ms() + 60000, anonymous),
    try Fun()
    after quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end)
    end.

with_committed(Fun) ->
    Committed = quod_ct:commit_kb(quod_committed_projection:new_est()),
    try Fun(Committed)
    after
        #est{db = #db{ref = Ref}} = Committed,
        quod_erlog_db_mvcc:delete(Ref)
    end.

bare() ->
    quod_erlog_db_local_prove:wrap_state(
      quod_ct:commit_kb(quod_committed_projection:new_est()),
      #{read_set => true}).

value(Var, Goal, St) ->
    {succeed, Final} = erlog_int:prove_goal(Goal, St),
    erlog_int:dderef(Var, Final#est.bs).

authored({Name, Arity}, St) ->
    value({'Clauses'}, {',', {'$quod_predicate_source', {'/', Name, Arity}, {'Source'}},
                       {'$quod_program_source', {'Clauses'}, {'Source'}}}, St).

canonical_source(Clause) ->
    {Canonical, _, _} = erlog_int:term_instance(Clause, 0),
    Canonical.

db_ref(#est{db = #db{ref = Ref}}) -> Ref.

with_authored(Terms, Fun) ->
    #est{db = Db} = Base = quod_committed_projection:new_est(),
    Loaded = Base#est{db = lists:foldl(fun erlog_int:assertz_clause/2, Db, Terms)},
    Committed = quod_ct:commit_kb(Loaded),
    St = quod_erlog_db_local_prove:wrap_state(Committed, #{read_set => true}),
    try Fun(St)
    after
        quod_erlog_db_local_prove:cleanup_read_set(St),
        quod_erlog_db_mvcc:delete(db_ref(Committed))
    end.
