-module(quod_dtx_group_trace_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include("quod_ledger.hrl").

%% Shared only by the observation-owner regressions. These are signed Begin
%% admission fixtures, not an assertion of full consensus-node readiness.
-export([with_fixture/1, with_live_admission/1]).

%% Real Prolog and Simplex callbacks own reserve -> admission -> activation;
%% the real coordinator and endpoint submit worker then cross both spawn
%% boundaries. Consensus is deliberately not ready, so this fixture observes
%% a parked durable Begin without fabricating a successful transaction.
group_admission_spawn_and_endpoint_keep_request_context_test_() ->
    [{atom_to_list(Sampling), fun() -> group_admission_trace(Sampling) end}
     || Sampling <- [recording, unsampled]].

group_admission_trace(Sampling) ->
    quod_trace_tests:with_tracer(fun() ->
      with_live_admission(fun(F, Engine, Owner, Ref) ->
      {Ambient, AmbientSpan} = quod_trace:start_span(
        otel_ctx:new(), <<"unrelated.group.caller">>, internal, #{}),
      try quod_trace:with_context(Ambient, fun() ->
            Begin = maps:get('begin', F),
            {ok, GroupRef} = quod_dtx:begin_group_ref(Begin),
            {ok, BeginBytes} = quod_dtx:encode_record(Begin),
            GroupId = quod_dtx:group_id(Begin),
            ParentCtx = case Sampling of
                recording -> otel_ctx:new();
                unsampled -> unsampled_context()
            end,
            {RootCtx, RootSpan} = quod_trace:start_span(
              ParentCtx, <<"group.request">>, internal, #{}),
            true = erlang:trace(Owner, true, ['receive', {tracer, self()}]) =:= 1,
            ?assertEqual(ok, gen_server:call(Engine,
              {reserve_dtx_begin, Ref, Begin, GroupRef, RootCtx})),
            ?assertEqual(ok, gen_server:call(Engine,
              {activate_dtx_begin, Ref, GroupRef})),
            {EndpointRequest, EndpointCtx} = take_endpoint_request(Owner),
            EndpointSpan = otel_tracer:current_span_ctx(EndpointCtx),
            ?assertEqual(otel_span:trace_id(RootSpan),
                         otel_span:trace_id(EndpointSpan)),
            ?assertNotEqual(otel_span:span_id(RootSpan),
                            otel_span:span_id(EndpointSpan)),
            ?assertMatch({submit, _, BeginBytes}, EndpointRequest),
            %% Exercise the existing endpoint carrier/decoder, not a newly
            %% invented transport representation. The semantic inner bytes
            %% remain identical with and without observation.
            {Ns, _} = maps:get(target, F),
            Carrier = quod_trace:inject(EndpointCtx),
            ?assertMatch([_ | _], Carrier),
            {ok, Traced} = quod_dtx_endpoint:encode_request(
                            Ns, EndpointRequest, [], Carrier),
            {ok, Plain} = quod_dtx_endpoint:encode_request(
                           Ns, EndpointRequest, []),
            {quod_dtx_endpoint, 10, Ns, Semantic, Carrier} =
                binary_to_term(Traced, [safe]),
            ?assertEqual({quod_dtx_endpoint, 10, Ns, Semantic, []},
                         binary_to_term(Plain, [safe])),
            ?assertEqual({ok, EndpointRequest, [], Carrier},
                         quod_dtx_endpoint:decode_request(Ns, Traced)),
            {running, S1} = sys:get_state(Owner),
            Owners1 = quod_simplex:test_dtx_coordinator_state(S1),
            #{GroupId := #{pid := Worker}} = Owners1,
            Monitor = monitor(process, Worker),
            %% A later/different caller does not alter identity, restart the
            %% coordinator, or replace its already-established parent.
            {LateCtx, LateSpan} = quod_trace:start_span(
              otel_ctx:new(), <<"group.late">>, internal, #{}),
            ?assertEqual({error, cancelled}, gen_server:call(Engine,
              {reserve_dtx_begin, Ref, Begin, GroupRef, LateCtx})),
            ?assertEqual({error, cancelled}, gen_server:call(Engine,
              {activate_dtx_begin, Ref, GroupRef})),
            {running, S2} = sys:get_state(Owner),
            ?assertEqual(Owners1, quod_simplex:test_dtx_coordinator_state(S2)),
            ?assertEqual({ok, BeginBytes}, quod_dtx:encode_record(Begin)),
            quod_trace:finish_span(LateSpan, ok),
            %% A graceful owner stop runs the real Simplex terminate callback.
            %% Untrappable owner death cannot promise export of a volatile
            %% owner-held span; this case does not claim to cover that loss.
            ok = gen_statem:stop(Owner),
            receive {'DOWN', Monitor, process, Worker, shutdown} -> ok
            after 3000 -> error(group_worker_survived_owner)
            end,
            case Sampling of
                recording ->
                    Coordinate = quod_trace_tests:take_span(<<"quod.dtx.coordinate">>),
                    ?assertEqual(otel_span:trace_id(RootSpan), Coordinate#span.trace_id),
                    ?assertEqual(otel_span:span_id(RootSpan), Coordinate#span.parent_span_id),
                    ?assertEqual(Coordinate#span.span_id, otel_span:span_id(EndpointSpan)),
                    ?assertEqual(<<"owner_terminating">>, maps:get(
                      'quod.dtx.closure', otel_attributes:map(Coordinate#span.attributes))),
                    ?assertEqual(quod_trace:tx_id(GroupId), maps:get(
                      'quod.dtx.group_id', otel_attributes:map(Coordinate#span.attributes)));
                unsampled ->
                    receive
                        {quod_test_span, #span{name = <<"quod.dtx.coordinate">>}} ->
                            error(unsampled_group_manufactured_recording_root)
                    after 0 -> ok
                    end
            end,
            quod_trace:finish_span(RootSpan, ok)
      end),
      %% Explicit request context never falls back to this unrelated ambient
      %% span, even when the request's sampling decision is off.
      AmbientTrace = otel_span:trace_id(AmbientSpan),
      receive {quod_test_span, #span{trace_id = AmbientTrace}} ->
          error(child_exported_under_unrelated_ambient)
      after 0 -> ok end
      after quod_trace:finish_span(AmbientSpan, ok) end
      end)
    end).

mixed_local_group_wave_links_recording_request_without_reparenting_test_() ->
    %% This production-callback fixture receives projection casts as well as
    %% spans. Keep its mailbox private: unrelated admission tests must not
    %% mistake these casts for their own one-row/two-row acknowledgements.
    {spawn, fun mixed_local_group_wave_links_recording_request_without_reparenting/0}.

mixed_local_group_wave_links_recording_request_without_reparenting() ->
    quod_trace_tests:with_tracer(fun() ->
        with_fixture(fun(F, S0, _Journal) ->
            {Ns, _} = Origin = maps:get(target, F),
            true = quod_reg:reg({quod_prolog, Ns}),
            {Ctx, Parent} = quod_trace:start_span(
              otel_ctx:new(), <<"mixed.group.request">>, internal, #{}),
            Unsampled = unsampled_context(),
            F2 = quod_ct:signed_dtx_begin_fixture(#{target => Origin,
              node_identity => maps:get(node_identity, F),
              key_pair => maps:get(key_pair, F), admission => maps:get(admission, F),
              proof_id => <<41:256>>, operation_id => <<42:256>>,
              goal_text => <<"assertz(other_group(ok)).">>}),
            Begin1 = maps:get('begin', F),
            Begin2 = maps:get('begin', F2),
            try
                {ok, S1} = quod_trace:with_context(Unsampled, fun() ->
                    quod_simplex:test_retain_dtx_record(Begin1, none, S0)
                end),
                {ok, S2} = quod_trace:with_context(Ctx, fun() ->
                    quod_simplex:test_retain_dtx_record(Begin2, none, S1)
                end),
                %% Duplicate or late contexts cannot change row lifetime,
                %% signed bytes, ordering, or the selected group's parent.
                PlainDuplicate = quod_trace:with_context(otel_ctx:new(), fun() ->
                    quod_simplex:test_retain_dtx_record(Begin1, none, S2)
                end),
                LateDuplicate = quod_trace:with_context(Ctx, fun() ->
                    quod_simplex:test_retain_dtx_record(Begin1, none, S2)
                end),
                ?assertEqual(PlainDuplicate, LateDuplicate),
                {ok, Retained} = LateDuplicate,
                Rows = maps:get(rows, quod_simplex:test_retained_dtx_state(Retained)),
                Envelopes = [maps:get(envelope, maps:get(quod_dtx:record_digest(B), Rows))
                             || B <- [Begin1, Begin2]],
                S3 = quod_simplex:test_propose_dtx_wave(2, Envelopes, [], Retained),
                ?assertEqual(unchanged, quod_simplex:test_trace_block(
                  2, none, <<"mixed.group.validation">>, S3, fun() -> unchanged end)),
                Span = quod_trace_tests:take_span(<<"mixed.group.validation">>),
                ?assertEqual(otel_span:trace_id(Parent), Span#span.trace_id),
                ?assertEqual(otel_span:span_id(Parent), Span#span.parent_span_id),
                [Link] = otel_links:list(Span#span.links),
                Other = otel_tracer:current_span_ctx(Unsampled),
                ?assertEqual(otel_span:trace_id(Other), Link#link.trace_id),
                ?assertEqual(otel_span:span_id(Other), Link#link.span_id)
            after
                quod_trace:finish_span(Parent, ok),
                gproc:unreg(quod_reg:name({quod_prolog, Ns}))
            end
        end)
    end).

unsampled_context() ->
    quod_trace:extract([{<<"traceparent">>,
      <<"00-123456789abcdef0123456789abcdef0-123456789abcdef0-00">>}]).

%% The source has no retained caller after reconstruction. An unrelated
%% ambient owner span must never become the historical group's parent.
history_only_group_recovery_has_no_ambient_parent_test() ->
    quod_trace_tests:with_tracer(fun() ->
        with_fixture(fun(F, S0, _Journal) ->
            Begin = maps:get('begin', F),
            {ok, GroupRef} = quod_dtx:begin_group_ref(Begin),
            GroupId = quod_dtx:group_id(Begin),
            Self = self(),
            {Ambient, Span} = quod_trace:start_span(
              otel_ctx:new(), <<"unrelated.owner.turn">>, internal, #{}),
            Owner = spawn(fun() ->
                S = quod_trace:with_context(Ambient, fun() ->
                    quod_simplex:test_reconcile_dtx_coordinators(
                      #{GroupId => {record, GroupId, Begin, GroupRef}}, S0)
                end),
                Self ! {started, self(), quod_simplex:test_dtx_coordinator_state(S)},
                receive stop ->
                    _ = quod_simplex:test_stop_dtx_coordinator(S),
                    ok
                end
            end),
            #{GroupId := #{pid := Worker}} = receive
                {started, Owner, Rows} -> Rows
            after 2000 -> error(no_recovery_worker)
            end,
            Monitor = monitor(process, Worker),
            Owner ! stop,
            receive {'DOWN', Monitor, process, Worker, shutdown} -> ok
            after 3000 -> error(recovery_survived_owner)
            end,
            Coordinate = quod_trace_tests:take_span(<<"quod.dtx.coordinate">>),
            ?assertNotEqual(otel_span:trace_id(Span), Coordinate#span.trace_id),
            ?assertEqual(undefined, Coordinate#span.parent_span_id),
            ?assertEqual(<<"retirement_requested">>, maps:get(
              'quod.dtx.closure', otel_attributes:map(Coordinate#span.attributes))),
            quod_trace:finish_span(Span, ok)
        end)
    end).

group_submit_fanout_preserves_context_and_result_test() ->
    quod_trace_tests:with_tracer(fun() ->
        {Ctx, Span} = quod_trace:start_span(
          otel_ctx:new(), <<"group.fanout">>, internal, #{}),
        Request = {phase, <<19:128>>, <<20:256>>, prepare},
        Parent = self(),
        RequestFun = fun(Source) ->
            Parent ! {fanout_context, Source, quod_trace:context()},
            {ok, {phase, <<19:128>>, 0, not_found},
             {reply_source, local, []}}
        end,
        Result = quod_trace:with_context(Ctx, fun() ->
            quod_dtx_coordinator:test_submit_endpoint_requests(
              [local], Request, 1000, RequestFun)
        end),
        receive {fanout_context, local, ChildCtx} ->
            ?assertEqual(otel_span:trace_id(Span),
              otel_span:trace_id(otel_tracer:current_span_ctx(ChildCtx)))
        after 1000 -> error(no_fanout_context)
        end,
        ?assertMatch({reply, {phase, <<19:128>>, 0, not_found}, _}, Result),
        quod_trace:finish_span(Span, ok)
    end).

take_endpoint_request(Owner) ->
    receive
        {trace, Owner, 'receive', {'$gen_call', _,
          {dtx_endpoint_local, Request, _, _, Context}}} -> {Request, Context}
    after 3000 -> error(missing_group_endpoint_context)
    end.

with_live_admission(Fun) ->
    with_fixture(fun(F, S0, {Journal, Dir}) ->
        {Ns, Anchor} = maps:get(target, F),
        Parent = self(),
        Ref = make_ref(),
        Engine = proc_lib:spawn(fun() ->
            true = quod_reg:reg({quod_prolog, Ns}),
            Parent ! {engine_ready, self()},
            gen_server:enter_loop(quod_prolog, [],
              quod_prolog:test_dtx_reservation_state(Ns, Anchor, Ref, Parent))
        end),
        EngineMonitor = monitor(process, Engine),
        receive {engine_ready, Engine} -> ok after 1000 -> error(no_engine) end,
        ok = quod_signing_journal:close(Journal),
        Owner = proc_lib:spawn(fun() ->
            true = quod_reg:reg({quod_simplex, Ns}),
            Domain = quod_simplex:consensus_domain(Ns, Anchor),
            {ok, OwnerJournal} = quod_signing_journal:recover(Ns, Domain, Dir),
            Table = binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
            _ = ets:new(Table, [named_table, protected, set]),
            true = ets:insert(Table, {anchor, Anchor}),
            Parent ! {owner_ready, self()},
            gen_statem:enter_loop(quod_simplex, [], running,
              quod_simplex:test_state_set(signing_journal, OwnerJournal, S0))
        end),
        OwnerMonitor = monitor(process, Owner),
        receive {owner_ready, Owner} -> ok after 1000 -> error(no_owner) end,
        try Fun(F, Engine, Owner, Ref)
        after
            Coordinators = fixture_coordinators(Owner),
            kill_and_wait(Owner, OwnerMonitor),
            lists:foreach(fun await_coordinator_down/1, Coordinators),
            kill_and_wait(Engine, EngineMonitor)
        end
    end).

with_fixture(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8)),
    Ns = <<"quod:group-trace-", Suffix/binary>>,
    Anchor = crypto:hash(sha256, Ns),
    F = quod_ct:signed_dtx_begin_fixture(#{target => {Ns, Anchor}}),
    #{pubkey := Author} = Identity = maps:get(node_identity, F),
    Admission = maps:get(admission, F),
    Dir = filename:join("/tmp", "quod_group_trace_" ++ binary_to_list(Suffix)),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    {ok, Journal} = quod_signing_journal:initialize(Ns, Domain, Dir),
    try
        S = quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor,
          consensus_domain => Domain, self => Author, id => Identity,
          validators => [Author], author_admissions => #{Author => Admission},
          sync => ready, slot => 1, approved => 1, last_applied => 0,
          prolog_ready => false, signing_journal => Journal,
          eng => quod_simplex:eng_new(Domain, [Author], 1)}),
        Fun(F, S, {Journal, Dir})
    after
        catch quod_signing_journal:close(Journal),
        file:del_dir_r(Dir)
    end.

kill_and_wait(Pid, Monitor) ->
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 3000 -> error({fixture_owner_survived, Pid})
    end.

fixture_coordinators(Owner) ->
    try sys:get_state(Owner, 1000) of
        {running, S} ->
            [{Pid, monitor(process, Pid)}
             || #{pid := Pid} <- maps:values(
                  quod_simplex:test_dtx_coordinator_state(S))]
    catch exit:_ -> []
    end.

await_coordinator_down({Pid, Monitor}) ->
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 3000 ->
        kill_and_wait(Pid, Monitor),
        error({coordinator_ignored_owner_death, Pid})
    end.
