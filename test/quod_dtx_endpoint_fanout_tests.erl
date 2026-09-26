-module(quod_dtx_endpoint_fanout_tests).
-behaviour(gen_statem).
-include_lib("eunit/include/eunit.hrl").
-export([init/1, callback_mode/0, handle_event/4]).

%% Preselected-route entry only. The real coordinator owns its workers/results;
%% the real Simplex running callback owns admission, links, replies and cleanup.
%% Only the transport/remote endpoint is fake. Its reference is a codec fixture,
%% not proof that history or target consensus was verified.
different_peers_deliver_concurrently_and_fast_reply_cancels_sibling_test_() ->
    [{atom_to_list(Reply), fun() -> with_source(fun(F) -> fanout(Reply, F) end) end}
     || Reply <- [prepared, refused]].

fanout(ReplyKind, F = #{source := Owner, owner_ns := OwnerNs, target := Target,
                       blob := Blob, sources := Sources, digest := Digest, ref := Ref}) ->
    Parent = self(), Deadline = quod_time:mono_ms() + 4000,
    {Coordinator, M} = spawn_monitor(fun() ->
        Result = quod_dtx_coordinator:test_submit_endpoint_requests(Sources, Blob,
            #{owner => Parent, owner_ns => OwnerNs, target => Target,
              ready => true, deadline => Deadline}, production),
        Parent ! {wave_result, self(), Result}
    end),
    try
        A = wire(), B = wire(),
        {PeerA, StreamA, {submit, IdA, Blob}} = A,
        {PeerB, StreamB, {submit, IdB, Blob}} = B,
        ?assertNotEqual(PeerA, PeerB), ?assertNotEqual(IdA, IdB),
        ?assertMatch(#{correlations := 2, channels := 1}, counts(Owner)),
        Timers = gen_statem:call(Owner, timers),
        ?assertEqual(2, length(Timers)),
        ?assert(lists:all(fun(T) -> is_integer(erlang:read_timer(T)) end, Timers)),
        ?assertMatch(#{wave := #{workers := 2,
                      meta := #{request_deadline := Deadline}}},
                     quod_dtx_coordinator:test_state(Coordinator)),
        #{opens := Opens, releases := []} = transport_barrier(Owner),
        ?assertEqual(2, length(Opens)),
        %% Consume a wrong-peer response in the ACTUAL source owner. RequestId
        %% alone cannot authorize another peer to complete this correlation.
        {ok, WrongFrame} = quod_dtx_endpoint:encode_response(element(1, Target),
            {accepted, IdB, Digest, Ref}, []),
        Owner ! {quod_message, {PeerA, StreamA}, quod_dtx_endpoint:channel(element(1, Target)), WrongFrame},
        ?assertMatch(#{correlations := 2}, counts(Owner)),
        Response = case ReplyKind of
            prepared -> {accepted, IdB, Digest, Ref};
            %% Refusal is a committed Vote, never an endpoint verdict. The
            %% correlation binds the original proposal, not the chosen vote.
            refused -> {accepted, IdB, Digest, maps:get(refused_ref, F)}
        end,
        StreamB ! {respond, Response},
        receive {wave_result, Coordinator, Result} ->
            ?assertEqual({reply, Response, {reply_source, remote, PeerB, []}}, Result)
        after 1000 -> error(fast_alternate_did_not_finish) end,
        down(M, Coordinator),
        await_empty(Owner, quod_time:mono_ms() + 1000),
        ?assertEqual([false, false], [erlang:read_timer(T) || T <- Timers]),
        #{opens := Opens, releases := Releases} = transport_barrier(Owner),
        ?assertEqual(lists:sort(Opens), lists:sort(Releases)),
        %% The slow endpoint never replied before completion. Late loser and
        %% duplicate winner frames execute the same production receive path.
        StreamA ! {respond, {accepted, IdA, Digest, Ref}},
        StreamB ! {respond, Response},
        stream_barrier(StreamA), stream_barrier(StreamB),
        ?assertMatch(#{correlations := 0, channels := 0}, counts(Owner)),
        ?assertEqual(2, length(maps:get(opens, transport_barrier(Owner)))),
        ?assertEqual(Blob, maps:get(blob, F))
    after
        exit(Coordinator, kill), demonitor(M, [flush])
    end.

wave_timeout_cancels_both_delivered_correlations_test() ->
    with_source(fun(#{source := Owner, owner_ns := OwnerNs, target := Target,
                     sources := Sources, blob := Blob}) ->
        Parent = self(), Deadline = quod_time:mono_ms() + 4000,
        {Coordinator, M} = spawn_monitor(fun() ->
            Result = quod_dtx_coordinator:test_submit_endpoint_requests(Sources, Blob,
                #{owner => Parent, owner_ns => OwnerNs, target => Target,
                  ready => true, deadline => Deadline}, production),
            Parent ! {expired_result, self(), Result}
        end),
        try
            _ = wire(), _ = wire(),
            Timers = gen_statem:call(Owner, timers),
            ?assertEqual(2, length(Timers)),
            #{wave := #{correlation := WaveRef, workers := 2,
                        meta := #{request_deadline := Deadline}}} =
                quod_dtx_coordinator:test_state(Coordinator),
            %% Drive the actual owner's timeout branch with its exact wave
            %% reference. This tests cleanup, not elapsed wall-clock accuracy.
            Coordinator ! {dtx_wave_timeout, WaveRef},
            receive {expired_result, Coordinator, Result} ->
                ?assertEqual(outcome_unknown, Result)
            after 1000 -> error(no_wave_expiry_result) end,
            down(M, Coordinator),
            await_empty(Owner, quod_time:mono_ms() + 1000),
            ?assertEqual([false, false], [erlang:read_timer(T) || T <- Timers]),
            #{opens := Opens, releases := Released} = transport_barrier(Owner),
            ?assertEqual(2, length(Opens)),
            ?assertEqual(lists:sort(Opens), lists:sort(Released))
        after exit(Coordinator, kill), demonitor(M, [flush]) end
    end).

phase_query_reuses_id_only_after_previous_source_is_removed_test_() ->
    [{lists:flatten(io_lib:format("~p", [Reply])),
      fun() -> phase_query_after_peer_reply(Reply, committed) end}
     || Reply <- [not_found, {error, busy}, {error, not_ready}, {error, not_found}]].

unavailable_peer_never_becomes_authoritative_absence_test_() ->
    [{atom_to_list(Reason),
      fun() -> phase_query_after_peer_reply({error, Reason}, not_found) end}
     || Reason <- [busy, not_ready, not_found]].

phase_query_after_peer_reply(FirstReply, LastReply) ->
    with_source(fun(#{source := Owner, owner_ns := OwnerNs, target := Target,
                     sources := Sources0, ref := Ref, record := Record}) ->
        %% The live peer answers, so its retired address must not be dialed.
        %% Real Simplex admission, encoded replies, exact correlation and lease
        %% cleanup run here; only the remote transport/consensus is a fixture.
        [{remote, KeyA, [Live]}, Other] = Sources0,
        Sources = [{remote, KeyA, [Live, {"127.0.0.1", 34203}]}, Other],
        Request = {phase, <<201:128>>, quod_atomic:group_id(Record), vote},
        Parent = self(), Deadline = quod_time:mono_ms() + 4000,
        {Walker, M} = spawn_monitor(fun() ->
            Result = quod_dtx_coordinator:test_phase_command_sources(
                Sources, Target, vote, Request, OwnerNs, Deadline),
            Parent ! {walk_result, self(), Result}
        end),
        try
            {PeerA, StreamA, Request} = wire(),
            ?assertMatch(#{correlations := 1}, counts(Owner)),
            [FirstTimer] = gen_statem:call(Owner, timers),
            #{opens := [{PeerA, OpenA}], releases := []} = transport_barrier(Owner),
            ResponseA = case FirstReply of
                {error, Reason} -> {error, <<201:128>>, Reason};
                not_found -> {phase, <<201:128>>, 0, not_found}
            end,
            StreamA ! {respond, ResponseA},
            {PeerB, StreamB, Request} = wire(),
            ?assertNotEqual(PeerA, PeerB),
            ?assertEqual(false, erlang:read_timer(FirstTimer)),
            ?assertMatch(#{correlations := 1}, counts(Owner)),
            #{opens := Opens, releases := [{PeerA, OpenA}]} = transport_barrier(Owner),
            ?assertEqual(2, length(Opens)),
            ResponseB = case LastReply of committed -> {committed, Ref}; not_found -> not_found end,
            StreamB ! {respond, {phase, <<201:128>>, 0, ResponseB}},
            receive {walk_result, Walker, Result} ->
                Expected = case LastReply of
                    committed -> {committed, Ref, {reply_source, remote, PeerB, []}};
                    not_found -> unresolved
                end,
                ?assertEqual(Expected, Result)
            after 1000 -> error(no_phase_walk_result) end,
            down(M, Walker),
            ?assertMatch(#{correlations := 0}, counts(Owner)),
            #{opens := Opens, releases := Released} = transport_barrier(Owner),
            ?assertEqual(lists:sort(Opens), lists:sort(Released))
        after exit(Walker, kill), demonitor(M, [flush]) end
    end).

with_source(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Parent = self(), Base = quod_ct:signed_atomic_fixture(#{}),
    Target = {Ns, Anchor} = maps:get(target, Base),
    Record = maps:get(vote, Base),
    {ok, Blob} = quod_atomic:encode_record(Record),
    Digest = quod_atomic:record_digest(Record),
    {ok, Ref} = quod_dtx:certified_ref(Ns, Anchor, 7, <<77:256>>, Digest, quod_ct:fixture_finality(6, <<77:256>>)),
    {ok, Refused} = quod_atomic:new_vote(maps:get(group, Base), Target,
        lists:keyfind(Target, 1, maps:get(bundles, Base)), {refused, [vote_deadline]}),
    {ok, RefusedRef} = quod_dtx:certified_ref(Ns, Anchor, 7, <<78:256>>,
        quod_atomic:record_digest(Refused), quod_ct:fixture_finality(6, <<78:256>>)),
    OwnerNs = <<"quod:fanout-owner-", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    {Transport, TM} = spawn_monitor(fun() ->
        true = quod_reg:reg({transport, node}),
        Parent ! {transport_ready, self()}, transport(Parent, Ns, [], [], [])
    end),
    receive {transport_ready, Transport} -> ok after 1000 -> error(no_transport) end,
    {ok, Owner} = gen_statem:start({via, gproc, {n, l, {quod_simplex, OwnerNs}}},
                                 ?MODULE, {Parent, OwnerNs}, []),
    try Fun(#{source => Owner, owner_ns => OwnerNs, target => Target,
              sources => [{remote, <<201:256>>, [{"127.0.0.1", 34201}]},
                          {remote, <<202:256>>, [{"127.0.0.1", 34202}]}],
              record => Record, blob => Blob, digest => Digest, ref => Ref,
              refused_ref => RefusedRef})
    after
        gen_statem:stop(Owner), Transport ! stop, down(TM, Transport),
        flush_admissions(Owner)
    end.

init({Observer, Ns}) ->
    put(observer, Observer),
    Anchor = <<0:256>>,
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    {ok, running, quod_simplex:test_state(#{ns => Ns,
        consensus_domain => Domain, eng => quod_simplex:eng_new(Domain, [], {{quod_ledger:initial_era({Ns, Anchor}), 0, Anchor}, 0})})}.
callback_mode() -> handle_event_function.
handle_event({call, From}, counts, running, S) ->
    {keep_state, S, [{reply, From, quod_simplex:test_dtx_endpoint_counts(S)}]};
handle_event({call, From}, timers, running, S) ->
    {keep_state, S, [{reply, From, quod_simplex:test_dtx_correlation_timers(S)}]};
handle_event({call, From}, {transport_barrier, Ref}, running, S) ->
    gen_server:cast(quod_reg:via({transport, node}), {barrier, get(observer), Ref}),
    {keep_state, S, [{reply, From, ok}]};
handle_event(Type, Message, running, S) ->
    Result = quod_simplex:running(Type, Message, S),
    case {Type, Message} of
        {{call, _}, {dtx_endpoint_request, _, _, _, _, _, Timeout, _}} ->
            get(observer) ! {admission_deadline, self(), Timeout, quod_time:mono_ms()};
        _ -> ok
    end,
    Result.

transport(Observer, Ns, Opens, Released, Streams) ->
    receive
        {'$gen_cast', {open_link_pinned_lease, Peer, _Endpoint, Channel, {Owner, OpenRef}}} ->
            {Stream, M} = spawn_monitor(fun() -> stream(Observer, Ns, Owner, Peer, Channel) end),
            Owner ! {link_up, OpenRef, Peer, Channel, Stream},
            transport(Observer, Ns, Opens ++ [{Peer, OpenRef}], Released, [{Stream, M} | Streams]);
        {'$gen_cast', {release_link_pinned, Peer, _Endpoint, _Channel, {_Owner, OpenRef}}} ->
            transport(Observer, Ns, Opens, Released ++ [{Peer, OpenRef}], Streams);
        {'$gen_cast', {barrier, Caller, Ref}} ->
            Caller ! {transport_barrier, Ref, #{opens => Opens, releases => Released}},
            transport(Observer, Ns, Opens, Released, Streams);
        stop ->
            lists:foreach(fun({Pid, _}) -> Pid ! stop end, Streams),
            lists:foreach(fun({Pid, M}) -> down(M, Pid) end, Streams)
    end.
stream(Observer, Ns, Owner, Peer, Channel) ->
    receive {send_ordered, Frame} ->
        {ok, Request, [], _} = quod_dtx_endpoint:decode_request(Ns, Frame),
        Observer ! {wire_request, Peer, self(), Request},
        stream_replies(Ns, Owner, Peer, Channel)
    after 1000 -> error(no_ordered_frame) end.
stream_replies(Ns, Owner, Peer, Channel) ->
    receive
        {respond, Response} ->
            {ok, Frame} = quod_dtx_endpoint:encode_response(Ns, Response, []),
            Owner ! {quod_message, {Peer, self()}, Channel, Frame},
            stream_replies(Ns, Owner, Peer, Channel);
        {barrier, Caller, Ref} ->
            %% Same-sender source call fences this stream's prior responses.
            _ = counts(Owner), Caller ! {stream_barrier, Ref},
            stream_replies(Ns, Owner, Peer, Channel);
        stop -> ok
    end.
wire() ->
    receive {wire_request, Peer, Stream, Request} -> {Peer, Stream, Request}
    after 1000 -> error(missing_concurrent_endpoint_delivery) end.
counts(Owner) -> gen_statem:call(Owner, counts).
transport_barrier(Owner) ->
    Ref = make_ref(), ok = gen_statem:call(Owner, {transport_barrier, Ref}),
    receive {transport_barrier, Ref, Snapshot} -> Snapshot
    after 1000 -> error(no_transport_barrier) end.
stream_barrier(Stream) ->
    Ref = make_ref(), Stream ! {barrier, self(), Ref},
    receive {stream_barrier, Ref} -> ok after 1000 -> error(no_stream_barrier) end.
await_empty(Owner, Limit) ->
    case counts(Owner) of
        #{correlations := 0, channels := 0} -> ok;
        _ -> true = quod_time:mono_ms() < Limit,
             erlang:yield(), await_empty(Owner, Limit)
    end.
flush_admissions(Owner) ->
    receive {admission_deadline, Owner, _, _} -> flush_admissions(Owner)
    after 0 -> ok end.
down(M, Pid) ->
    receive {'DOWN', M, process, Pid, normal} -> ok
    after 1000 -> error({owner_not_reaped, Pid}) end.
