-module(quod_proof_answer_tests).
-include("retired_presentation_sizes.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_proof_limits.hrl").

default_answer_allocation_is_authored_test() ->
    with_session([], fun(Session) ->
        ?assertEqual(ok, quod_proof_session:admit_answer(Session, answer(80000))),
        Reads = quod_proof_session:proof_policy_reads(Session),
        ?assert(maps:is_key({material_limit, 3}, Reads)),
        ?assert(maps:is_key({material_default_limit, 3}, Reads)),
        ?assert(maps:is_key({material_limit_override, 3}, Reads))
    end).

producer_enforces_exact_canonical_quantity_test() ->
    Value = binary:copy(<<"a">>, 160000),
    Answer = {answer_value, Value},
    {ok, Bytes} = quod_wire_term:encode_canonical(Answer),
    Actual = byte_size(Bytes),
    lists:foreach(fun(Limit) ->
        with_session([{material_limit_override, proof, answer_bytes, Limit},
                      Answer], fun(Session) ->
            Invocation = open(Session, {answer_value, {'Value'}}),
            case Limit of
                Actual -> ?assertEqual({solution, Answer},
                                      quod_proof_session:next(Session, Invocation));
                _ ->
                    ?assertEqual({error, {material_limit, proof, answer_bytes, Actual, Limit}},
                                 quod_proof_session:next(Session, Invocation)),
                    ?assertEqual({error, unknown_invocation},
                                 quod_proof_session:next(Session, Invocation))
            end
        end)
    end, [Actual, Actual - 1, 0]).

receiver_uses_own_policy_and_atom_safe_measurement_test() ->
    Term = {answer_value, familiar_name},
    Opaque = {answer_value, {'$quod_symbol', <<"familiar_name">>}},
    {ok, Bytes} = quod_wire_term:encode_canonical(Term),
    ?assertEqual({ok, Bytes}, quod_wire_term:encode_canonical(Opaque)),
    Limit = byte_size(Bytes) - 1,
    with_session([{material_limit_override, proof, answer_bytes, Limit}],
      fun(Session) ->
          Expected = {error, {material_limit, proof, answer_bytes, byte_size(Bytes), Limit}},
          ?assertEqual(Expected, quod_proof_session:admit_answer(Session, Term)),
          ?assertEqual(Expected, quod_proof_session:admit_answer(Session, Opaque))
      end).

answer_policy_is_pinned_and_concurrent_change_conflicts_test() ->
    Rule = {':-', {material_limit_override, proof, answer_bytes, {'Limit'}},
                  {answer_allowance, {'Limit'}}},
    with_session([Rule, {answer_allowance, 1000}], fun(Session) ->
        Invocation = open(Session, {',', {retract, {answer_allowance, 1000}},
                                         {assertz, {answer_allowance, unlimited}}}),
        ?assertMatch({solution, _}, quod_proof_session:next(Session, Invocation)),
        {ok, Bytes} = quod_wire_term:encode_canonical(answer(80000)),
        ?assertEqual({error, {material_limit, proof, answer_bytes, byte_size(Bytes), 1000}},
                     quod_proof_session:admit_answer(Session, answer(80000))),
        Bind = #{target => {<<"answer:test">>, <<1:256>>}, base_height => 1,
                 proof_id => <<2:256>>, origin => {<<"answer:test">>, <<1:256>>},
                 principal => anonymous, request_binding => none},
        {ok, Plan} = quod_proof_session:seal(Session, Bind),
        {ok, #{read_check := Reads}} = quod_dtx:material(Plan),
        ?assert(maps:is_key({answer_allowance, 1}, Reads)),
        Est = quod_proof_session:committed_state(Session),
        {ok, Changed} = quod_diff:apply_ops(Est, quod_ct:diff_for({answer_allowance, 2000})),
        Published = quod_ct:commit_kb(Changed, 2, 1),
        ?assertEqual({conflict, {answer_allowance, 1}},
                     quod_diff:validate(Reads, (Published#est.db)#db.ref)),
        %% A history decoder validates accepted bytes without readmitting the
        %% original operation against a newer policy.
        {ok, Encoded} = quod_dtx:encode(Plan),
        ?assertEqual({ok, Plan}, quod_dtx:decode(Encoded))
    end).

invalid_ambiguous_and_missing_answer_policy_refuse_test() ->
    lists:foreach(fun(Facts) ->
        #est{db = #db{ref = Ref}} = Est = quod_ct:committed_kb(Facts),
        try
            ?assertEqual({error, {invalid_material_policy, proof}},
                         quod_material_admission:policy(proof, Est))
        after quod_erlog_db_mvcc:delete(Ref)
        end
    end, [[{material_limit_override, proof, answer_bytes, -1}],
          [{material_limit_override, proof, answer_bytes, {'Any'}}],
          [{material_limit_override, proof, answer_bytes, 10},
           {material_limit_override, proof, answer_bytes, 20}]]),
    #est{db = #db{ref = Ref}} = Est = quod_ct:committed_kb([]),
    try
        {succeed, Missing} = erlog_int:prove_goal(
                              {abolish, {'/', material_default_limit, 3}}, Est),
        Published = quod_ct:commit_kb(Missing, 2, 1),
        ?assertEqual({error, {invalid_material_policy, proof}},
                     quod_material_admission:policy(proof, Published))
    after quod_erlog_db_mvcc:delete(Ref)
    end.

encoding_and_complete_envelope_safety_remain_test() ->
    with_session([], fun(Session) ->
        ?assertEqual({error, {protocol_error, bad_payload}},
                     quod_proof_session:admit_answer(Session, self()))
    end),
    Value = binary:copy(<<0>>, ?LEGACY_SCOPE_WIRE_MAX_ENVELOPE_BYTES),
    {ok, Encoded} = quod_scope_wire:encode_payload(answer, Value),
    ?assertEqual({ok, Value}, quod_scope_wire:decode_payload(answer, Encoded)),
    ?assertEqual({error, {protocol_error, bad_payload}},
                 quod_scope_wire:decode_payload(answer, <<131, 80, 0, 0, 0, 1>>)),
    Reason = {material_limit, proof, answer_bytes, 80026, 1000},
    ?assert(quod_scope_wire:valid_public_error(Reason)),
    ?assertEqual({413, #{error => material_limit, kind => proof,
                        resource => answer_bytes, actual => <<"80026">>, limit => <<"1000">>}},
                 quod_client_result:http_error({error, Reason})).

cancellation_keeps_original_policy_and_discards_continuation_test() ->
    with_session([{choice, first}, {choice, second}], fun(Session) ->
        Invocation = open(Session, {choice, {'Value'}}),
        ?assertMatch({solution, _}, quod_proof_session:next(Session, Invocation)),
        Reads = quod_proof_session:proof_policy_reads(Session),
        ok = quod_proof_session:cancel(Session, Invocation),
        ?assertEqual({error, unknown_invocation}, quod_proof_session:next(Session, Invocation)),
        ?assertEqual(Reads, quod_proof_session:proof_policy_reads(Session))
    end).

pinned_answer_admission_reuses_selection_without_history_or_io_test() ->
    %% These owners run synchronously in this isolated EUnit VM. Count actual
    %% named work, not elapsed time; the committed view exists before tracing.
    Est = quod_ct:committed_kb([{answer_value, <<"small">>}]),
    Calls = [{quod_material_admission, policy, 2},
             {quod_committed_projection, read_terms, 1},
             {quod_committed_projection, new_est, 0},
             {quod_ledger_store, fold, 5}, {quod_ledger_store, fold_groups, 3},
             {quod_ledger_store, batch_sync, 1}, {file, write_file, 2},
             {file, write, 2}, {file, sync, 1}, {file, datasync, 1}],
    lists:foreach(fun({M, _, _} = MFA) ->
        {module, M} = code:ensure_loaded(M),
        1 = erlang:trace_pattern(MFA, true, [call_count])
    end, Calls),
    {max_heap_size, Previous} = process_info(self(), max_heap_size),
    try
        Session = quod_proof_session:start(Est,
            #{read_set => true, proof_context => {origin, test}}),
        try
            lists:foreach(fun(_) ->
                Invocation = open(Session, {answer_value, {'Value'}}),
                ?assertEqual({solution, {answer_value, <<"small">>}},
                             quod_proof_session:next(Session, Invocation)),
                ok = quod_proof_session:cancel(Session, Invocation)
            end, lists:seq(1, 20)),
            ?assertEqual({call_count, 1}, erlang:trace_info(hd(Calls), call_count)),
            [?assertEqual({call_count, 0}, erlang:trace_info(MFA, call_count))
             || MFA <- tl(Calls)]
        after quod_proof_session:stop(Session) end
    after
        process_flag(max_heap_size, Previous),
        [erlang:trace_pattern(MFA, false, [call_count]) || MFA <- Calls],
        quod_erlog_db_mvcc:delete((Est#est.db)#db.ref)
    end.

answer(N) -> {answer_value, binary:copy(<<"a">>, N)}.

with_session(Facts, Fun) ->
    #est{db = #db{ref = Ref}} = Est = quod_ct:committed_kb(Facts),
    {max_heap_size, Previous} = process_info(self(), max_heap_size),
    Session = quod_proof_session:start(Est,
        #{read_set => true, proof_context => {origin, test}}),
    try Fun(Session)
    after
        process_flag(max_heap_size, Previous),
        quod_proof_session:stop(Session), quod_erlog_db_mvcc:delete(Ref)
    end.

open(Session, Goal) ->
    Invocation = crypto:strong_rand_bytes(16),
    Context = quod_predicates:proof_context(<<"answer:test">>, 1, undefined, []),
    ok = quod_proof_session:open(Session, Invocation, Goal, allowed, Context,
                                quod_transaction_scope:empty_selection()),
    Invocation.
