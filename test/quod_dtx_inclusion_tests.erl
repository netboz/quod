-module(quod_dtx_inclusion_tests).
-include_lib("eunit/include/eunit.hrl").

%% The fixture has real signed local certificates and the production history
%% reducer/index. Its foreign references are protocol fixtures, not a claim of
%% full multi-node proof admission. This scope tests exact local inclusion.
late_prepare_returns_exact_reference_without_new_custody_test_() ->
    [{atom_to_list(Path), fun() -> with_target(fun(F, S) ->
        Ref = maps:get(prepare_ref, F), Control = maps:get(control, F),
        Record = quod_dtx:control_body(Control),
        {ok, Blob} = quod_dtx:encode_record(Record),
        Request = {submit, <<55:128>>, Blob},
        Ns = maps:get(ns, F), Pub = maps:get(pub, F),
        Journal = quod_simplex:test_signing_journal(S),
        Lane = {maps:get(admission, F), Pub},
        Floor = quod_signing_journal:dtx_floor(Journal, Lane),
        {Next, Response} = deliver(Path, F, Request, S),
        ?assertEqual({accepted, <<55:128>>, quod_dtx:record_digest(Record), Ref}, Response),
        ?assert(quod_dtx_endpoint:correlates(Request, Response)),
        ?assertEqual(0, maps:get(retained, quod_simplex:test_retained_dtx_state(Next))),
        ?assertNot(quod_simplex:test_dtx_drive_scheduled(Next)),
        ?assertEqual(Floor, quod_signing_journal:dtx_floor(
                            quod_simplex:test_signing_journal(Next), Lane)),
        ?assertMatch({ok, {Ns, _}, _, _}, quod_dtx:certified_ref_binding(Ref))
    end) end} || Path <- [local, remote] ].

late_relayed_prepare_does_not_reenter_consensus_test() ->
    with_target(fun(F, S) ->
        Record = quod_dtx:control_body(maps:get(control, F)),
        Target = {maps:get(ns, F), maps:get(anchor, F)},
        %% A current, newly signed outer envelope for the same semantic phase
        %% passes the ordinary signature/sequence gate. Inclusion must still
        %% suppress it; this is not merely rejection of a consumed sequence.
        {ok, Control} = quod_dtx:sign_control(
                         Target, Record, maps:get(admission, F), 3, 3, maps:get(signer, F)),
        {ok, Envelope} = quod_dtx:encode_control(Control),
        Next = quod_simplex:dispatch(maps:get(pub, F), {dtx_submit, [Envelope], []}, S),
        ?assertEqual(0, maps:get(retained, quod_simplex:test_retained_dtx_state(Next))),
        ?assertNot(quod_simplex:test_dtx_drive_scheduled(Next))
    end).

same_phase_different_digest_is_not_accepted_test() ->
    with_target(fun(F, S) ->
        Record = quod_dtx:control_body(maps:get(control, F)),
        %% A changed manifest nonce is still a well-shaped request, but is
        %% not the record certified by this target's existing Prepare.
        Changed = setelement(5, Record, setelement(5, element(5, Record), <<127:256>>)),
        ?assertMatch({ok, _}, quod_dtx:encode_record(Changed)),
        ?assertNotEqual(quod_dtx:record_digest(Record), quod_dtx:record_digest(Changed)),
        ?assertEqual({error, stale_dtx_submission},
                     quod_simplex:test_retain_dtx_record(Changed, none, S))
    end).

deliver(local, _F, Request, S) ->
    From = {self(), make_ref()},
    {ok, Started} = quod_simplex:test_start_local_dtx_endpoint_request(
                      Request, [], 1000, From, S),
    {Pid, Result} = worker_result(),
    {Done, [{reply, From, {ok, Response, []}}]} =
        quod_simplex:test_finish_dtx_worker(Pid, Result, Started),
    {Done, Response};
deliver(remote, F, Request, S) ->
    Ns = maps:get(ns, F), Peer = {maps:get(pub, F), {{127, 0, 0, 1}, 45678}},
    {ok, Frame} = quod_dtx_endpoint:encode_request(Ns, Request, []),
    {Started, []} = quod_simplex:test_dtx_endpoint_frame(Ns, serve, Peer, self(), Frame, S),
    {Pid, Result} = worker_result(),
    {Done, []} = quod_simplex:test_finish_dtx_worker(Pid, Result, Started),
    receive {send_ordered, ResponseFrame} ->
        {ok, Response, []} = quod_dtx_endpoint:decode_response(Ns, ResponseFrame),
        {Done, Response}
    after 1000 -> error(no_endpoint_response)
    end.

worker_result() ->
    receive
        {dtx_endpoint_worker_result, _, {submit_result, _, {error, timeout}}} ->
            error(certified_phase_was_resubmitted);
        {dtx_endpoint_worker_result, Pid, Result} -> {Pid, Result}
    after 1500 -> error(certified_phase_was_resubmitted)
    end.

with_target(Fun) ->
    Parent = self(), Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Result = try target(Fun), ok catch C:R:St -> {raise, C, R, St} end,
        Parent ! {Ref, Result}
    end),
    receive {Ref, Result} ->
        receive {'DOWN', Mon, process, Pid, normal} -> ok end,
        case Result of ok -> ok; {raise, C, R, St} -> erlang:raise(C, R, St) end
    end.

target(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"quod:included-", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    F = quod_foreign_log_tests:prepared_then_committed_fixture(Ns),
    Anchor = maps:get(anchor, F), Target = {Ns, Anchor},
    Root = filename:join("/tmp", binary_to_list(Ns)),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    {ok, Index} = quod_dtx_phase_index:open(Root, Ns),
    {ok, Journal} = quod_signing_journal:initialize(Ns, Domain, Root),
    {ok, Store} = quod_ledger_store:open(Ns, Root),
    try
        P = lists:foldl(fun(Entry, Acc) ->
                {ok, Next, _} = quod_simplex:history_advance(Target, Entry, Acc, Index), Next
            end, quod_simplex:history_projection(Target), maps:get(chain, F)),
        ?assertEqual(#{}, maps:get(groups, maps:get(dtx, P))),
        {ok, Written} = quod_ledger_store:append(Store, maps:get(chain, F)),
        {ok, Reconciled} = quod_dtx_owner:reconcile_journal(3, P, Index, Journal),
        Pub = maps:get(pub, F),
        S = quod_simplex:test_install_projection(P, quod_simplex:test_state(
              #{ns => Ns, genesis_hash => Anchor, self => Pub, id => maps:get(signer, F),
                slot => 3, last_applied => 3, sync => ready, prolog_ready => true,
                phase_index => Index, signing_journal => Reconciled, store => Written,
                consensus_domain => Domain, eng => quod_simplex:eng_new(Domain, [Pub], 3)})),
        Fun(F, S)
    after
        _ = catch quod_signing_journal:close(Journal),
        ok = quod_ledger_store:close(Store),
        ok = quod_dtx_phase_index:close(Index),
        ok = file:del_dir_r(Root)
    end.
