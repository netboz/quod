-module(quod_atomic_delivery_tests).
-include_lib("eunit/include/eunit.hrl").

%% Real signed plans, codec, gateway preparation and production wave/endpoint
%% calls. Target owner interfaces are protocol fixtures, not consensus nodes;
%% their accepted references assert correlation, not quorum authenticity.

gateway_keeps_foreign_material_out_of_the_source_handoff_test() ->
    F = fixture(), {G, M, Votes} = prepared(F),
    O = maps:get(target, F),
    ?assertEqual(O, quod_atomic:record_target(element(1, M))),
    ?assertEqual(lists:sort(maps:get(targets, F)),
                 lists:sort([quod_atomic:record_target(V) || V <- Votes])),
    {ok, Ref} = quod_atomic:source_group_ref(M),
    ?assertEqual({ok, O}, quod_outcome:ref_identity(Ref)),
    lists:foreach(fun({T, _, Blob, _}) ->
        case T of O -> ok; _ -> ?assertEqual(nomatch, binary:match(term_to_binary(M), Blob)) end
    end, maps:get(bundles, F)),
    lists:foreach(fun({quod_dtx_vote, 4, G0, T, Own, prepared} = V) ->
        ?assertEqual(G, G0),
        ?assertEqual(lists:keyfind(T, 1, maps:get(bundles, F)), Own),
        {ok, TargetMaterial} = quod_atomic:admission_material(V),
        ?assertEqual(error, quod_atomic:source_group_ref(TargetMaterial))
    end, Votes).

initial_delivery_is_parallel_own_only_and_never_retries_a_temporary_reply_test() ->
    with_targets(fun(F) ->
        {G, _M, Votes} = prepared(F), Deadline = quod_time:mono_ms() + 3000,
        {Gateway, Monitor} = start_delivery(self(), F, G, Votes, Deadline),
        try
            Calls = calls(2), %% Neither target receives a reply before both requests arrive.
            assert_own_requests(F, Calls),
            #{protocol := delivery, pending_phases := #{},
              wave := #{meta := #{request_deadline := Deadline}}} =
                quod_dtx_coordinator:test_state(Gateway),
            [A, B] = Calls,
            reply(A, accepted), reply(B, not_ready),
            finished(Gateway, Monitor, ok),
            receive {delivery_call, _, _, _, _} -> error(initial_vote_resubmitted)
            after 0 -> ok end,
            lists:foreach(fun(T) ->
                ?assertEqual([], gproc:lookup_pids(quod_reg:prop({directory_route, T})))
            end, maps:get(targets, F))
        after stop(Gateway) end
    end).

initial_delivery_deadline_cleans_held_endpoint_workers_test() ->
    with_targets(fun(F) ->
        {G, _M, Votes} = prepared(F),
        {Gateway, Monitor} = start_delivery(self(), F, G, Votes, quod_time:mono_ms() + 500),
        try
            Calls = calls(2),
            Children = [{element(1, From), monitor(process, element(1, From))}
                        || {_, From, _, _} <- Calls],
            finished(Gateway, Monitor, ok),
            [down(Pid, MRef) || {Pid, MRef} <- Children],
            %% A timeout finishes only the gateway's delivery attempt. It
            %% supplies no refusal vote and cannot finalize the atomic group.
            receive {delivery_call, _, _, _, _} -> error(timeout_resubmitted_vote)
            after 0 -> ok end
        after stop(Gateway) end
    end).

long_caller_budget_uses_the_existing_bounded_wave_allowance_test() ->
    with_targets(fun(F) ->
        {G, _M, Votes} = prepared(F), Started = quod_time:mono_ms(),
        CallerDeadline = Started + 60000,
        {Gateway, Monitor} = start_delivery(self(), F, G, Votes, CallerDeadline),
        try
            Calls = calls(2),
            #{wave := #{meta := #{request_deadline := WaveDeadline}}} =
                quod_dtx_coordinator:test_state(Gateway),
            ?assert(WaveDeadline < CallerDeadline),
            ?assert(WaveDeadline =< quod_time:mono_ms() + 5000),
            ?assert(WaveDeadline >= Started + 5000),
            [?assert(Remaining > 0 andalso Remaining =< 5000)
             || {_, _, _, Remaining} <- Calls],
            [reply(Call, accepted) || Call <- Calls],
            finished(Gateway, Monitor, ok)
        after stop(Gateway) end
    end).

source_engine_death_cancels_the_initial_wave_test() ->
    with_targets(fun(F) ->
        Engine = spawn(fun() -> receive stop -> ok end end),
        {G, _M, Votes} = prepared(F),
        {Gateway, Monitor} = start_delivery(Engine, F, G, Votes, quod_time:mono_ms() + 3000),
        try
            Calls = calls(2),
            Children = [{element(1, From), monitor(process, element(1, From))}
                        || {_, From, _, _} <- Calls],
            stop(Engine),
            finished(Gateway, Monitor, {error, outcome_unknown}),
            [down(Pid, MRef) || {Pid, MRef} <- Children]
        after stop(Gateway), stop(Engine) end
    end).

prepared(F) ->
    {ok, G, M, Votes} = quod_prolog:test_prepare_group_delivery(
                         maps:get(manifest, F), maps:get(auth, F), maps:get(bundles, F)),
    {G, M, Votes}.

fixture() ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    O = {<<"delivery:o:", Suffix/binary>>, <<1:256>>},
    Targets = [{<<"delivery:b:", Suffix/binary>>, <<2:256>>},
               {<<"delivery:c:", Suffix/binary>>, <<3:256>>}],
    (quod_ct:signed_plan_fixture(#{target => O, atomic => true}, [O | Targets]))#{targets => Targets}.

with_targets(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    ?assertEqual(undefined, quod_reg:where({foreign_log, node})),
    F = fixture(), Test = self(),
    Targets = [begin
        Pid = spawn(fun() ->
            Table = ets:new(binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
                            [named_table, protected, set]),
            true = ets:insert(Table, {anchor, Anchor}),
            true = quod_reg:reg({quod_simplex, Ns}),
            Test ! {target_ready, self()}, target_loop(Test, Target)
        end),
        receive {target_ready, Pid} -> Pid after 1000 -> error(target_registration_missing) end
    end || {Ns, Anchor} = Target <- maps:get(targets, F)],
    try Fun(F)
    after [stop(Pid) || Pid <- Targets]
    end.

target_loop(Test, Target) ->
    receive
        {'$gen_call', From, {dtx_endpoint_local, Request, [], Remaining, _Trace}} ->
            Test ! {delivery_call, Target, From, Request, Remaining},
            target_loop(Test, Target);
        Other -> Test ! {unexpected_delivery_message, Other}, target_loop(Test, Target)
    end.

start_delivery(Engine, F, G, Votes, Deadline) ->
    Test = self(), {Ns, _} = maps:get(target, F),
    spawn_monitor(fun() ->
        Result = quod_dtx_coordinator:deliver_votes(Engine, Ns, G, Votes, Deadline),
        Test ! {delivery_finished, self(), Result}
    end).

calls(0) -> [];
calls(N) ->
    receive
        {delivery_call, T, From, Request, Remaining} ->
            [{T, From, Request, Remaining} | calls(N - 1)];
        {unexpected_delivery_message, Message} -> error({unexpected_delivery_message, Message})
    after 1000 -> error({initial_delivery_not_parallel, N})
    end.

assert_own_requests(F, Calls) ->
    ?assertEqual(lists:sort(maps:get(targets, F)), lists:sort([T || {T, _, _, _} <- Calls])),
    Ids = [Id || {_, _, {submit, Id, _}, _} <- Calls],
    ?assertEqual(length(Calls), length(lists:usort(Ids))),
    lists:foreach(fun({T, _, {submit, _, Blob}, Remaining}) ->
        ?assert(Remaining > 0 andalso Remaining =< 3000),
        {ok, {{quod_dtx_vote, 4, _, T, Own, prepared}, _, #{plans := Plans}}} =
            quod_atomic:decode_material(Blob),
        ?assertEqual([T], maps:keys(Plans)),
        ?assertEqual(lists:keyfind(T, 1, maps:get(bundles, F)), Own)
    end, Calls).

reply({T = {Ns, Anchor}, From, {submit, Id, Blob}, _}, accepted) ->
    {ok, Digest} = quod_atomic:encoded_record_digest(Blob),
    {ok, Ref} = quod_dtx:certified_ref(Ns, Anchor, 2, <<2:256>>, Digest, <<"protocol-fixture">>),
    ?assertMatch({ok, T, 2, Digest}, quod_dtx:certified_ref_binding(Ref)),
    gen_statem:reply(From, {ok, {accepted, Id, Digest, Ref}, []});
reply({_, From, {submit, Id, _}, _}, not_ready) ->
    gen_statem:reply(From, {ok, {error, Id, not_ready}, []}).

finished(Pid, Monitor, Expected) ->
    receive {delivery_finished, Pid, Actual} -> ?assertEqual(Expected, Actual)
    after 1500 -> error(initial_delivery_did_not_finish) end,
    receive {'DOWN', Monitor, process, Pid, Reason} -> ?assertEqual(normal, Reason)
    after 1000 -> error(initial_delivery_did_not_exit) end.

down(Pid, Monitor) ->
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(endpoint_worker_survived_delivery) end.

stop(Pid) ->
    Monitor = monitor(process, Pid), exit(Pid, kill), down(Pid, Monitor).
