-module(quod_catchup_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%%%===================================================================
%%% quod_catchup:serve_blocks/4 — the catch-up server's read path (read a committed block+cert range from
%%% a read-only store view, clamped to the height, a per-request count cap, AND a byte budget so the
%%% response fits one quod_link frame). The over-the-wire request/response is exercised end-to-end by the
%%% multi-node join CT.
%%%===================================================================

setup() ->
    Dir = filename:join("/tmp", "quod_catchup_test_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Ns  = <<"catchup:test">>,
    {ok, S0} = quod_ledger_store:open(Ns, Dir),
    %% entry 5 carries a real #cert{} — proving the cert (de)serializes through the store frame, which is
    %% exactly what a joiner reads back to verify the block.
    Cert = #cert{kind = commit, slot = 5, block_hash = crypto:hash(sha256, <<"blk5">>),
                 sigs = [{<<1, 2, 3>>, <<4, 5, 6>>}]},
    Es = [#entry{index = I, data = {batch, [tx(I)]}, cert = none}
          || I <- lists:seq(1, 4)]
         ++ [#entry{index = 5, data = {batch, [tx(5)]}, cert = Cert}],
    {ok, S1} = quod_ledger_store:append(S0, Es),
    ok = quod_ledger_store:close(S1),
    {Dir, Ns, Cert}.

cleanup({Dir, _, _}) -> _ = file:del_dir_r(Dir), ok.

tx(I) -> #transaction{tx_id = integer_to_binary(I), origin = {<<"catchup:test">>, <<0:256>>},
                      diff = [{assert, {{fact, I}, true}}], read_check = #{},
                      author = <<"a">>, sig = none}.

serve_blocks_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun({Dir, Ns, Cert}) ->
         [ %% a sub-range in index order, with the server's committed height
           ?_assertMatch({ok, [#entry{index = 2}, #entry{index = 3}, #entry{index = 4}], 5},
                         quod_catchup:serve_blocks(Ns, Dir, 2, 4)),
           %% To is clamped to the committed height
           ?_assertMatch({ok, [#entry{index = 1} | _], 5}, quod_catchup:serve_blocks(Ns, Dir, 1, 1000)),
           ?_assertEqual(5, length(element(2, quod_catchup:serve_blocks(Ns, Dir, 1, 1000)))),
           %% From beyond the tail ⇒ empty (nothing to send); From clamped to ≥ 1
           ?_assertMatch({ok, [], 5}, quod_catchup:serve_blocks(Ns, Dir, 10, 20)),
           ?_assertMatch({ok, [#entry{index = 1} | _], 5}, quod_catchup:serve_blocks(Ns, Dir, 0, 3)),
           %% the persisted cert round-trips intact through the store frame
           ?_assertMatch({ok, [#entry{index = 5, cert = Cert}], 5}, quod_catchup:serve_blocks(Ns, Dir, 5, 5)),
           %% a namespace with no local log ⇒ error (the joiner tries another contact)
           ?_assertEqual({error, no_log}, quod_catchup:serve_blocks(<<"nope:x">>, Dir, 1, 1)) ]
     end}.

%% The byte budget caps the response so it fits one quod_link frame (1 MiB) — a window of large blocks is
%% returned as a shorter prefix (the joiner loops for the rest), never an oversized frame that kills the link.
byte_cap_test() ->
    Dir = filename:join("/tmp", "quod_catchup_big_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Ns  = <<"catchup:big">>,
    Big = binary:copy(<<0>>, 200 * 1024),   %% ~200 KiB payload per entry
    _ = file:del_dir_r(Dir),
    try
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        Es = [#entry{index = I, cert = none,
                     data = {batch,
                             [#transaction{tx_id = integer_to_binary(I), origin = {Ns, <<0:256>>},
                                           diff = [{assert, {{blob, I}, Big}}], read_check = #{},
                                           author = <<"a">>, sig = none}]}}
              || I <- lists:seq(1, 8)],      %% 8 × ~200 KiB = ~1.6 MiB total, over the ~900 KiB budget
        {ok, S1} = quod_ledger_store:append(S0, Es),
        ok = quod_ledger_store:close(S1),
        {ok, Served, 8} = quod_catchup:serve_blocks(Ns, Dir, 1, 1000),
        ?assert(length(Served) >= 1),      %% always makes progress
        ?assert(length(Served) < 8),       %% but byte-capped below the full window
        Bytes = lists:sum([byte_size(term_to_binary(E, [deterministic])) || E <- Served]),
        ?assert(Bytes < 1024 * 1024)       %% the served entries fit under quod_link's 1 MiB frame cap
    after
        _ = file:del_dir_r(Dir)
    end.

%% Every response is bound to an authenticated node key. A keyed contact starts
%% bound; an endpoint contact becomes bound during its identified open, before
%% the request is sent.
peer_binding_test() ->
    A = <<"peer-a">>, B = <<"peer-b">>,
    ?assert(quod_catchup:peer_matches(A, {bound, A})),
    ?assertNot(quod_catchup:peer_matches(B, {bound, A})).

%% A catch-up response belongs to the authenticated stream that carried its
%% request.  Threading that exact link through the read worker avoids a reverse
%% resolver/dial dependency and also works for directory-pinned no-learn links.
same_link_response_test() ->
    Fixture = {Dir, Ns, _Cert} = setup(),
    Peer = <<9:256>>,
    Endpoint = {"127.0.0.1", 14569},
    RequestId = make_ref(),
    Channel = quod_catchup:channel(Ns),
    try
        S0 = quod_catchup:test_state(Ns, Dir),
        Request = quod_catchup:encode_frame(
                    Ns, {blocks_req, RequestId, 2, 3}),
        {noreply, S1} = quod_catchup:handle_info(
                          {quod_message,
                           {{Peer, Endpoint}, self()}, Channel, Request},
                          S0),
        SendResponse =
            receive
                {'$gen_cast',
                 {send_resp, _OwnerRef, ReplyLink, _Response, _Result} = Cast}
                  when ReplyLink =:= self() -> Cast
            after 2000 ->
                error(catchup_worker_did_not_reply)
            end,
        {noreply, S2} = quod_catchup:handle_cast(SendResponse, S1),
        {reply, Stats, S2} = quod_catchup:handle_call(stats, self(), S2),
        ?assertEqual(0, maps:get(server_inflight, Stats)),
        ?assertEqual(1, maps:get(server_inflight_peak, Stats)),
        receive
            {send_ordered, ResponseFrame} ->
                ?assertMatch(
                   {ok, {blocks_resp, RequestId,
                         [#entry{index = 2}, #entry{index = 3}], 5}, _},
                   quod_catchup:decode_frame(Ns, ResponseFrame))
        after 1000 ->
            error(catchup_response_not_sent_on_request_link)
        end
    after
        cleanup(Fixture)
    end.

identified_endpoint_binds_live_key_before_request_test() ->
    quod_quic:ensure_cache(),
    Ns = <<"catchup:identified-endpoint">>,
    Peer = <<10:256>>,
    Endpoint = {"127.0.0.1", 14570},
    RequestId = make_ref(),
    OpenRef = make_ref(),
    CallRef = make_ref(),
    Timer = erlang:send_after(5000, self(), identified_test_timeout),
    Frame = quod_catchup:encode_frame(
              Ns, {blocks_req, RequestId, 1, 2}),
    S0 = quod_catchup:test_state(
           Ns, "/tmp",
           #{pending =>
                 #{RequestId =>
                       {{self(), CallRef}, Timer, {opening, OpenRef}}},
             openings =>
                 #{OpenRef => {RequestId, Endpoint, Frame}}}),
    _ = ets:delete(quod_addr_cache, Peer),
    try
        {noreply, S1} = quod_catchup:handle_info(
                          {link_up, OpenRef, Peer,
                           quod_catchup:channel(Ns), self()}, S0),
        ?assertEqual({ok, Endpoint}, quod_quic:resolve(Peer)),
        receive
            {send, Frame} -> ok
        after 1000 ->
            error(identified_request_not_sent_on_opened_link)
        end,
        ErrorFrame = quod_catchup:encode_frame(
                       Ns, {blocks_err, RequestId}),
        {noreply, S2} = quod_catchup:handle_info(
                          {quod_message, {Peer, self()},
                           quod_catchup:channel(Ns), ErrorFrame}, S1),
        {reply, Stats, S2} = quod_catchup:handle_call(stats, self(), S2),
        ?assertEqual(0, maps:get(client_pending, Stats)),
        ?assertEqual(1, maps:get(client_pending_peak, Stats)),
        receive
            {CallRef, {error, server_error}} -> ok
        after 1000 ->
            error(identified_response_not_bound_to_tls_key)
        end
    after
        _ = erlang:cancel_timer(Timer),
        _ = ets:delete(quod_addr_cache, Peer)
    end.

identified_endpoint_failure_drops_late_link_test() ->
    Ns = <<"catchup:identified-failure">>,
    Peer = <<11:256>>,
    Endpoint = {"127.0.0.1", 14571},
    RequestId = make_ref(),
    OpenRef = make_ref(),
    CallRef = make_ref(),
    Timer = erlang:send_after(5000, self(), identified_failure_timeout),
    Frame = quod_catchup:encode_frame(
              Ns, {blocks_req, RequestId, 1, 2}),
    S0 = quod_catchup:test_state(
           Ns, "/tmp",
           #{pending =>
                 #{RequestId =>
                       {{self(), CallRef}, Timer, {opening, OpenRef}}},
             openings =>
                 #{OpenRef => {RequestId, Endpoint, Frame}}}),
    {noreply, S1} = quod_catchup:handle_info(
                      {link_error, OpenRef, Endpoint,
                       quod_catchup:channel(Ns)}, S0),
    receive
        {CallRef, {error, timeout}} -> ok
    after 1000 ->
        error(identified_link_failure_not_replied)
    end,
    {noreply, _S2} = quod_catchup:handle_info(
                       {link_up, OpenRef, Peer,
                        quod_catchup:channel(Ns), self()}, S1),
    receive
        {send, Frame} -> error(late_identified_link_reused)
    after 0 ->
        ok
    end.

%% Cold recovery begins with endpoint seeds, not pubkey resolver hints. Candidate discovery must keep the
%% endpoint form (so a direct authenticated pull can teach the hint), exclude self, deduplicate, and cap.
contact_candidates_test() ->
    Ns = <<"catchup:no-process">>,
    Self = {"127.0.0.1", 14567},
    A = {"10.0.0.1", 1001}, B = {"10.0.0.2", 1002},
    application:set_env(quod, node_addr, Self),
    try
        Candidates = quod_catchup:contact_candidates(Ns, [Self, A, A, B], 8),
        ?assertEqual(lists:sort([A, B]), lists:sort(Candidates)),
        ?assertEqual(1, length(quod_catchup:contact_candidates(Ns, [A, B], 1)))
    after
        application:unset_env(quod, node_addr)
    end.
