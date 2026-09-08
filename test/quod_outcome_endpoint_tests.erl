-module(quod_outcome_endpoint_tests).

-include_lib("eunit/include/eunit.hrl").

%% Real endpoint workers and owner transitions, with only the Prolog snapshot
%% reply held by a message-controlled fixture. No ledger timing is assumed.
replay_ready_at_unchanged_height_releases_the_same_request_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        assert_subscribed(F, Worker),
        gen_server:reply(From, {error, {ontology_rebuilding, maps:get(ns, F)}}),
        await_result(F, {error, not_ready}),
        ?assertEqual(1, worker_count(F)),
        update_owner(F, #{prolog_ready => true}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        assert_outcome(F, outcome, 3),
        assert_worker_gone(F, Worker)
    end).

snapshot_result_racing_newer_head_is_resampled_test() ->
    with_endpoint(true, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        update_owner(F, #{slot => 4, last_applied => 4}),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(4)),
        assert_outcome(F, outcome, 4),
        assert_worker_gone(F, Worker)
    end).

unchanged_stale_snapshot_parks_without_a_resampling_loop_test() ->
    with_endpoint(true, fun(F) ->
        update_owner(F, #{slot => 4, last_applied => 4}),
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        assert_no_snapshot(F),
        ?assertEqual(1, worker_count(F)),
        Ns = maps:get(ns, F),
        quod_reg:publish({runtime, Ns}, {projection_advanced, self(), 3}),
        assert_no_snapshot(F),
        quod_reg:publish({runtime, Ns}, {projection_advanced, self(), 4}),
        {Worker, From3} = snapshot_call(F),
        gen_server:reply(From3, snapshot(4)),
        assert_outcome(F, outcome, 4),
        assert_worker_gone(F, Worker)
    end).

runtime_edge_queued_before_owner_decision_is_not_lost_test() ->
    with_endpoint(true, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        assert_subscribed(F, Worker),
        Ns = maps:get(ns, F),
        %% The subscription precedes the query. This ready edge arrives while
        %% the helper still awaits its first reply, before parent parking.
        quod_reg:publish({runtime, Ns}, {replay_ready, make_ref(), 3}),
        gen_server:reply(From, {error, {ontology_rebuilding, Ns}}),
        await_result(F, {error, not_ready}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        assert_outcome(F, outcome, 3),
        assert_worker_gone(F, Worker)
    end).

outcome_barrier_uses_the_same_readiness_wait_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome_barrier, 3000),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        ?assertEqual(1, worker_count(F)),
        update_owner(F, #{prolog_ready => true}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        assert_outcome(F, outcome_barrier, 3),
        assert_worker_gone(F, Worker)
    end).

wrong_anchor_or_era_is_refused_without_a_worker_test() ->
    with_endpoint(false, fun(F) ->
        Request = request(F, outcome),
        {transaction, Ns, _Anchor, TxId} = element(3, Request),
        BadAnchor = setelement(3, Request, {transaction, Ns, <<99:256>>, TxId}),
        BadEra = setelement(4, Request, <<98:256>>),
        ?assertEqual({error, not_ready}, admit(F, BadAnchor, 3000)),
        ?assertEqual({error, not_ready}, admit(F, BadEra, 3000)),
        ?assertEqual(0, worker_count(F)),
        ?assertEqual([], subscribers(F)),
        assert_no_snapshot(F)
    end).

parked_request_refuses_a_changed_committee_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        update_owner(F, #{committee_id => <<98:256>>}),
        {Worker, From2} = snapshot_call(F),
        gen_server:reply(From2, snapshot(3)),
        assert_refused(F),
        assert_worker_gone(F, Worker)
    end).

parked_deadline_removes_worker_and_subscription_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 100),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        assert_refused(F),
        assert_worker_gone(F, Worker)
    end).

owner_death_releases_parked_worker_and_subscription_test() ->
    with_endpoint(false, fun(F) ->
        start_request(F, outcome, 3000),
        {Worker, From} = snapshot_call(F),
        gen_server:reply(From, snapshot(3)),
        await_result(F, {outcome_state, element(2, snapshot(3))}),
        Monitor = monitor(process, Worker),
        exit(maps:get(owner, F), kill),
        receive {'DOWN', Monitor, process, Worker, normal} -> ok
        after 1000 -> error(worker_retained_after_owner_death)
        end,
        ?assertEqual([], subscribers(F))
    end).

with_endpoint(Ready, Test) ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"outcome-wait-", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    Anchor = <<11:256>>,
    Committee = <<12:256>>,
    Key = <<13:256>>,
    Parent = self(),
    Stub = spawn(fun() ->
        true = quod_reg:reg({quod_prolog, Ns}),
        Parent ! {stub_ready, self()},
        prolog_stub(Ns, Parent)
    end),
    receive {stub_ready, Stub} -> ok after 1000 -> error(stub_not_ready) end,
    S = quod_simplex:test_state(#{ns => Ns, self => Key, validators => [Key],
          genesis_hash => Anchor, committee_id => Committee, slot => 3,
          last_applied => 3, sync => ready, prolog_ready => Ready, store => memory}),
    Owner = spawn(fun() -> owner_loop(Parent, S) end),
    F = #{ns => Ns, anchor => Anchor, committee => Committee, owner => Owner,
          tag => make_ref(), request_id => crypto:strong_rand_bytes(16)},
    try Test(F)
    after
        stop_process(Owner),
        stop_process(Stub)
    end.

prolog_stub(Ns, Parent) ->
    receive
        {'$gen_call', {Worker, _} = From, {outcome_snapshot, _Ref}} ->
            Parent ! {snapshot_call, Ns, Worker, From},
            prolog_stub(Ns, Parent)
    end.

owner_loop(Parent, S) ->
    receive
        {call, Ref, {start, Request, Timeout, From}} ->
            case quod_simplex:test_start_local_dtx_endpoint_request(
                   Request, [], Timeout, From, S) of
                {ok, S1} -> Parent ! {Ref, ok}, owner_loop(Parent, S1);
                Error -> Parent ! {Ref, Error}, owner_loop(Parent, S)
            end;
        {call, Ref, {update, Overrides}} ->
            S1 = maps:fold(fun quod_simplex:test_state_set/3, S, Overrides),
            ok = quod_simplex:test_wake_dtx_snapshot_workers(S, S1),
            Parent ! {Ref, ok}, owner_loop(Parent, S1);
        {call, Ref, count} ->
            Parent ! {Ref, maps:get(workers, quod_simplex:test_dtx_endpoint_counts(S))},
            owner_loop(Parent, S);
        {dtx_endpoint_worker_result, Worker, Result} ->
            {S1, Actions} = quod_simplex:test_finish_dtx_worker(Worker, Result, S),
            Parent ! {endpoint_result, self(), Result},
            lists:foreach(fun({reply, From, Reply}) -> gen_statem:reply(From, Reply) end,
                          Actions),
            owner_loop(Parent, S1);
        {'DOWN', _, process, _, _} -> owner_loop(Parent, S)
    end.

request(F, Kind) ->
    #{ns := Ns, anchor := Anchor, committee := Cid, request_id := Id} = F,
    Ref = case Kind of
        outcome -> {transaction, Ns, Anchor, <<14:256>>};
        outcome_barrier ->
            {group, Ns, Anchor, <<13:256>>,
             quod_simplex:test_author_admission(<<13:256>>), <<16:256>>}
    end,
    {Kind, Id, Ref, Cid, 3}.

snapshot(Height) -> {ok, #{applied_floor => Height, outcome => not_found}}.

start_request(F, Kind, Timeout) -> ?assertEqual(ok, admit(F, request(F, Kind), Timeout)).
admit(F, Request, Timeout) ->
    owner_call(F, {start, Request, Timeout, {self(), maps:get(tag, F)}}).
update_owner(F, Overrides) -> ?assertEqual(ok, owner_call(F, {update, Overrides})).
worker_count(F) -> owner_call(F, count).
owner_call(#{owner := Owner}, Message) ->
    Ref = make_ref(),
    Owner ! {call, Ref, Message},
    receive {Ref, Reply} -> Reply after 1000 -> error(owner_not_responding) end.

snapshot_call(#{ns := Ns}) ->
    receive {snapshot_call, Ns, Worker, From} -> {Worker, From}
    after 1000 -> error(snapshot_not_requested)
    end.
await_result(#{owner := Owner}, Result) ->
    receive {endpoint_result, Owner, Result} -> ok
    after 1000 -> error({result_not_processed, Result})
    end.
assert_no_snapshot(#{ns := Ns}) ->
    receive {snapshot_call, Ns, _, _} -> error(snapshot_spun_without_progress)
    after 30 -> ok
    end.
subscribers(#{ns := Ns}) -> gproc:lookup_pids({p, l, {runtime, Ns}}).
assert_subscribed(F, Worker) -> ?assertEqual([Worker], subscribers(F)).
assert_outcome(#{tag := Tag, request_id := Id, ns := Ns,
                 anchor := Anchor, committee := Cid}, Kind, Floor) ->
    receive {Tag, Reply} ->
        ?assertEqual({ok, {Kind, Id, {Ns, Anchor}, Cid, Floor, not_found}, []}, Reply)
    after 1000 -> error(endpoint_never_replied)
    end.
assert_refused(#{tag := Tag, request_id := Id}) ->
    receive {Tag, Reply} -> ?assertEqual({ok, {error, Id, not_ready}, []}, Reply)
    after 1000 -> error(endpoint_never_refused)
    end.
assert_worker_gone(F, Worker) ->
    Monitor = monitor(process, Worker),
    receive {'DOWN', Monitor, process, Worker, _} -> ok
    after 1000 -> error(worker_retained_after_reply)
    end,
    ?assertEqual(0, worker_count(F)),
    ?assertEqual([], subscribers(F)).
stop_process(Pid) ->
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(fixture_process_did_not_stop)
    end.
