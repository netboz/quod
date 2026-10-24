-module(quod_operation_receipt_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

remote_receipt_recovers_claim_bindings_test_() ->
    [{lists:flatten(io_lib:format("~p", [Verdict])), fun() -> recovered_receipt(Verdict) end}
     || Verdict <- [applied, {rejected, conflict_retry}]].

recovered_receipt(Verdict) ->
    Named = #{<<"Ref">> => recovered},
    quod_operation_fixture:with(1, [], Verdict,
      #{bindings => Named, goal_text => <<"Ref = recovered, assertz(created(Ref)).">>}, fun(F) ->
        Ns = maps:get(source_ns, F), Op = maps:get(operation_ref, F),
        Identity = {Ns, element(3, Op)}, OwnerNs = <<Ns/binary, "-gateway">>,
        Complete = maps:get(completion, F),
        {ok, Ref} = quod_dtx:certified_entry_ref(Identity, maps:get(source_entry, F), Complete),
        {ok, Encoded} = quod_transaction:encode_evidence(Ref, Complete),
        Test = self(),
        {Owner, Monitor} = spawn_monitor(fun() ->
            true = quod_reg:reg({foreign_log, node}),
            [true = quod_reg:reg({quod_simplex, N}) || N <- [OwnerNs, Ns |
                [T || {T, _} <- maps:get(targets, F)]]],
            SourceView = quod_operation_fixture:view(maps:get(source_store, F),
                maps:get(source_projection, F), maps:get(source_entry, F)),
            TargetViews = maps:map(fun(_, D) ->
                quod_operation_fixture:view(maps:get(store, D), maps:get(projection, D), maps:get(entry, D))
            end, maps:get(target_data, F)),
            Test ! {receipt_fixture_ready, self()},
            verified_receipt_owner(Identity, Op, Encoded, SourceView, TargetViews)
        end),
        receive {receipt_fixture_ready, Owner} -> ok
        after 1000 -> error(receipt_fixture_not_ready) end,
        try
            Digest = maps:get(request_digest, F),
            Projection = #{ref => Op, request_digest => Digest, height => 2,
                           operation_state => terminal, receipt_height => 3},
            %% Route transport is a fixture. Exact ledger verification, receipt
            %% validation and application-certificate checks are production code.
            {ok, Rows, Result} = quod_dtx_current_view:operation_result(
                OwnerNs, Op, Digest, Projection, quod_time:mono_ms() + 3000),
            ExpectedVerdict = case Verdict of applied -> committed; _ -> Verdict end,
            ?assertMatch([{_, {ExpectedVerdict, _}}], Rows),
            {ok, Outcome} = quod_outcome:result_bindings(
                #{status => completed, ref => Op, targets => Rows}, Result),
            ?assertEqual(lists:sort(maps:to_list(Named)), maps:get(bindings, Outcome)),
            Evidence = #{request_digest => Digest, request => #{operation_id => element(5, Op)}},
            {200, Json} = quod_client_http:signed_goal_result(
                {ok, Evidence, {operation_outcome, #{height => 2}, Outcome}}),
            ?assertEqual([quod_client_result:binding_json(maps:to_list(Named))], maps:get(bindings, Json))
        after
            Owner ! stop,
            receive {'DOWN', Monitor, process, Owner, normal} -> ok
            after 1000 -> exit(Owner, kill), error(receipt_fixture_not_stopped) end
        end
    end).

verified_receipt_owner({Ns, _} = Identity, Op, Encoded, SourceView, TargetViews) ->
    receive
        {'$gen_call', From, {history_view, Target, {committed, _}, _Deadline}} ->
            Reply = case Target of
                Identity -> {error, invalid_identity};
                _ -> {ok, maps:get(Target, TargetViews)}
            end,
            gen:reply(From, Reply);
        {'$gen_call', From, {route_hints, Identity, []}} ->
            gen:reply(From, {ok, [{<<91:256>>, [{"127.0.0.1", 34391}]}]});
        {'$gen_call', From,
         {dtx_endpoint_request, Ns, <<91:256>>, {"127.0.0.1", 34391},
          {operation_receipt, RequestId, Op, 3}, [], _, _}} ->
            gen:reply(From, {ok, {operation_receipt, RequestId, Op, 3, Encoded}, []});
        {'$gen_call', From, {verification, Deadline, _, _,
                            {verify_reference, Ref, transaction, none, none, _}}} ->
            gen:reply(From, quod_foreign_log:verify_local_deadline(SourceView, Ref, transaction, Deadline));
        stop -> exit(normal)
    end,
    verified_receipt_owner(Identity, Op, Encoded, SourceView, TargetViews).

remote_receipt_decode_is_a_fail_closed_boundary_test_() ->
    [{atom_to_list(Kind), fun() -> receipt_case(Kind) end}
     || Kind <- [malformed, uncorrelated, valid_unavailable, expired]].

remote_receipt_checks_correlation_once_test() ->
    {module, quod_dtx_endpoint} = code:ensure_loaded(quod_dtx_endpoint),
    {module, quod_transaction} = code:ensure_loaded(quod_transaction),
    {ok, {call_count, Counts}} = tprof:profile(fun() -> receipt_case(valid_unavailable) end,
      #{type => call_count, report => return,
        pattern => [{quod_dtx_endpoint, correlates, 2}, {quod_transaction, decode_evidence, 1}]}),
    lists:foreach(fun({Module, Function, Arity, Expected}) ->
        ?assertEqual(Expected, lists:sum([N || {M, F, A, Ps} <- Counts,
          M =:= Module, F =:= Function, A =:= Arity, {_, N, _} <- Ps]))
    end, [{quod_dtx_endpoint, correlates, 2, 1}, {quod_transaction, decode_evidence, 1, 2}]).

receipt_case(Kind) ->
    quod_operation_fixture:with(1, fun(F) ->
        Ns = maps:get(source_ns, F),
        Op = maps:get(operation_ref, F),
        Identity = {Ns, element(3, Op)},
        OwnerNs = <<Ns/binary, "-gateway">>,
        Entry = maps:get(source_entry, F),
        Complete = maps:get(completion, F),
        {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Entry, Complete),
        {ok, Encoded} = quod_transaction:encode_evidence(Ref, Complete),
        Digest = maps:get(request_digest, F),
        Projection = #{ref => Op, request_digest => Digest, height => 2,
                       operation_state => terminal, receipt_height => 3},
        Deadline = quod_time:mono_ms() + case Kind of expired -> -1; _ -> 1000 end,
        Counts = atomics:new(4, []),
        Test = self(),
        ?assertEqual(undefined, quod_reg:where({foreign_log, node})),
        {Owner, Monitor} = spawn_monitor(fun() ->
            true = quod_reg:reg({foreign_log, node}),
            true = quod_reg:reg({quod_simplex, Ns}),
            true = quod_reg:reg({quod_simplex, OwnerNs}),
            Test ! {receipt_fixture_ready, self()},
            receipt_owner(Kind, Identity, Op, Encoded, Deadline, Counts)
        end),
        receive {receipt_fixture_ready, Owner} -> ok
        after 1000 -> error(receipt_fixture_not_ready)
        end,
        try
            %% Real public lookup, route walk, endpoint correlation and decoder.
            %% Correlation itself validates nested receipt evidence: malformed
            %% bytes were already refused at baseline, before the second decode.
            %% The registered owners are protocol fixtures, not consensus nodes:
            %% they deliberately cannot certify the valid discovery bytes.
            ?assertEqual({error, retry}, quod_dtx_current_view:operation_result(
                           OwnerNs, Op, Digest, Projection, Deadline)),
            Expected = case Kind of
                           valid_unavailable -> [2, 1, 1, 1];
                           expired -> [0, 0, 0, 0];
                           _ -> [1, 1, 1, 0]
                       end,
            ?assertEqual(Expected, [atomics:get(Counts, I) || I <- lists:seq(1, 4)])
        after
            Owner ! stop,
            receive {'DOWN', Monitor, process, Owner, normal} -> ok
            after 1000 -> exit(Owner, kill), error(receipt_fixture_not_stopped)
            end
        end
    end).

receipt_owner(Kind, {Ns, _} = Identity, Op, Encoded, Deadline, Counts) ->
    receive
        {'$gen_call', From, {history_view, Identity, {committed, _}, Deadline}} ->
            atomics:add(Counts, 1, 1),
            gen:reply(From, {error, invalid_identity}),
            receipt_owner(Kind, Identity, Op, Encoded, Deadline, Counts);
        {'$gen_call', From, {route_hints, Identity, []}} ->
            atomics:add(Counts, 2, 1),
            gen:reply(From, {ok, [{<<91:256>>, [{"127.0.0.1", 34391}]}]}),
            receipt_owner(Kind, Identity, Op, Encoded, Deadline, Counts);
        {'$gen_call', From,
         {dtx_endpoint_request, Ns, <<91:256>>, {"127.0.0.1", 34391},
          {operation_receipt, RequestId, Op, 3}, [], Remaining, _Trace}}
          when Remaining > 0 ->
            atomics:add(Counts, 3, 1),
            ResponseId = case Kind of uncorrelated -> <<0:128>>; _ -> RequestId end,
            Blob = case Kind of malformed -> <<"not-an-evidence-envelope">>; _ -> Encoded end,
            gen:reply(From, {ok, {operation_receipt, ResponseId, Op, 3, Blob}, []}),
            receipt_owner(Kind, Identity, Op, Encoded, Deadline, Counts);
        {'$gen_call', From,
         {verification, Deadline, _Trace, _Enqueued,
          {verify_reference, _Ref, transaction, none, none, Remaining}}}
          when Remaining > 0 ->
            atomics:add(Counts, 4, 1),
            gen:reply(From, {error, not_ready}),
            receipt_owner(Kind, Identity, Op, Encoded, Deadline, Counts);
        stop -> ok
    end.
