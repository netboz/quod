-module(quod_link_tests).
-include_lib("eunit/include/eunit.hrl").

%% header/3, parse_header/1, frame/1 and parse/1 are exported only under -ifdef(TEST).
-import(quod_link, [header/3, parse_header/1, frame/1, parse/1]).

peer_key_normalizes_transport_identity_test() ->
    Peer = <<7:256>>,
    ?assertEqual(Peer, quod_link:peer_key(Peer)),
    ?assertEqual(Peer, quod_link:peer_key({Peer, {"127.0.0.1", 14567}})),
    ?assertEqual(undefined, quod_link:peer_key(<<"short">>)),
    ?assertEqual(undefined, quod_link:peer_key({<<"short">>, ignored})),
    ?assertEqual(undefined, quod_link:peer_key(malformed)).

%% --- header: <<NLen:16, NodeId, CLen:16, Channel, LearnPolicy:8>> -------

header_roundtrip_test() ->
    Addr = {"127.0.0.1", 14567},
    Cases = [{{<<0:256>>, Addr}, <<"chan">>, learn},
             {{<<1:256>>, Addr}, <<"a/b">>, no_learn}],
    [?assertEqual({ok, NodeId, Ch, Policy, <<>>},
                  parse_header(header(NodeId, Ch, Policy)))
     || {NodeId, Ch, Policy} <- Cases].

%% the header consumes exactly its bytes; trailing payload frames are the Rest.
header_keeps_remainder_test() ->
    Tail = frame(<<"payload">>),
    Id = {<<0:256>>, {"h", 1}},
    Buf  = <<(header(Id, <<"c">>, no_learn))/binary, Tail/binary>>,
    ?assertEqual({ok, Id, <<"c">>, no_learn, Tail}, parse_header(Buf)).

%% a header that arrives in pieces -> `more` until complete, then decoded.
header_split_buffers_test() ->
    Id = {<<0:256>>, {"h", 1}},
    Full = header(Id, <<"chan">>, learn),
    Half = byte_size(Full) div 2,
    <<A:Half/binary, _/binary>> = Full,
    ?assertEqual(more, parse_header(A)),
    ?assertEqual({ok, Id, <<"chan">>, learn, <<>>}, parse_header(Full)).

%% a structurally complete header whose node id isn't a decodable term -> error
%% (defensive decode), not a crash.
header_bad_nodeid_rejected_test() ->
    ?assertEqual(error, parse_header(<<3:16, "abc", 0:16, 1:8>>)),
    [?assertEqual(error, parse_header(header(Bad, <<"c">>, learn)))
     || Bad <- [node_atom, 42, {a, b, c}, {{"h", 1}, {"h", 1}},
                {<<"short">>, {"h", 1}},
                {<<0:256>>, malformed_endpoint},
                {<<0:256>>, {<<>>, 1}},
                {<<0:256>>, {[], 1}},
                {<<0:256>>, {binary:copy(<<"h">>, 256), 1}},
                {<<0:256>>, {lists:duplicate(256, $h), 1}},
                {<<0:256>>, {{127, 0, 0, 999}, 1}},
                {<<0:256>>, {{arbitrary, tuple}, 1}},
                {<<0:256>>, {[0], 1}}]].

header_bad_learn_policy_rejected_test() ->
    Id = {<<0:256>>, {"h", 1}},
    Valid = header(Id, <<"c">>, learn),
    PrefixLen = byte_size(Valid) - 1,
    <<Prefix:PrefixLen/binary, _Policy:8>> = Valid,
    ?assertEqual(error, parse_header(<<Prefix/binary, 2:8>>)).

compressed_header_identity_rejected_before_expansion_test() ->
    Id = {<<0:256>>, {binary:copy(<<"h">>, 200), 1}},
    Compressed = term_to_binary(Id, [{compressed, 9}]),
    ?assertMatch(<<131, 80, _/binary>>, Compressed),
    Header = <<(byte_size(Compressed)):16, Compressed/binary,
               1:16, "c", 1:8>>,
    ?assertEqual(error, parse_header(Header)).

%% --- payload frames: <<PLen:32, Payload>> -------------------------------

frame_layout_test() ->
    ?assertEqual(<<4:32, "DATA">>, frame(<<"DATA">>)).

frame_roundtrip_test() ->
    Cases = [<<"hello">>, <<>>, <<0, 1, 255>>],
    [?assertEqual({[Pl], <<>>}, parse(frame(Pl))) || Pl <- Cases].

%% QUIC is a byte stream: two frames can coalesce into one buffer -> both parsed.
coalesced_frames_test() ->
    Buf = <<(frame(<<"p1">>))/binary, (frame(<<"p2">>))/binary>>,
    ?assertEqual({[<<"p1">>, <<"p2">>], <<>>}, parse(Buf)).

%% ...or a frame splits across reads -> incomplete kept buffered, then completed.
split_frame_reassembles_test() ->
    Full = frame(<<"payload">>),
    Half = byte_size(Full) div 2,
    <<A:Half/binary, B/binary>> = Full,
    {[], Buf} = parse(A),
    ?assertEqual(A, Buf),
    ?assertEqual({[<<"payload">>], <<>>}, parse(<<Buf/binary, B/binary>>)).

partial_header_buffers_test() ->
    %% fewer than 4 length bytes -> buffered, no crash
    ?assertEqual({[], <<1, 2, 3>>}, parse(<<1, 2, 3>>)).

whole_then_partial_test() ->
    Tail = <<99:32, "x">>,              %% length claims 99 bytes; only 1 present
    Buf  = <<(frame(<<"p">>))/binary, Tail/binary>>,
    {Frames, Rest} = parse(Buf),
    ?assertEqual([<<"p">>], Frames),
    ?assertEqual(Tail, Rest).

oversized_frame_rejected_test() ->
    Huge = <<(1 bsl 21):32, 0:16>>,     %% declares ~2 MiB payload
    ?assertEqual({error, oversized}, parse(Huge)).

%% Exercise real link processes and the real catch-up codec. Only the QUIC
%% connection acceptance boundary is substituted, with its actual call shape.
catchup_bootstrap_and_opaque_page_test() ->
    with_credit_outbound(
      fun(Link, Conn, Tag, Ns, Channel) ->
          Grant = <<1:128>>, Next = <<2:128>>, ReqId = <<3:128>>,
          Link ! {data, frame(<<>>), false},
          receive {link_up, Channel, _, Link, out} -> ?assert(false)
          after 20 -> ok end,
          Credit = frame(quod_catchup:encode_frame(Ns, {blocks_credit, Grant})),
          <<Prefix:5/binary, Rest/binary>> = Credit,
          Link ! {data, Prefix, false},
          Link ! {data, Rest, false},
          receive {link_up, Channel, _, Link, out} -> ok
          after 1000 -> error(no_credit_link_up) end,
          Binding = make_ref(),
          ok = quod_link:bind_catchup(Link, Binding),
          receive {catchup_credit, Link, Binding, Grant} -> ok
          after 1000 -> error(no_initial_credit) end,
          ok = quod_link:bind_catchup(Link, Binding),
          ok = quod_link:request_page(Link, Binding, Grant, ReqId, 1, 1),
          {[Request], <<>>} = parse(credit_wire(Tag)),
          ?assertMatch({ok, {blocks_req, Grant, ReqId, 1, 1}, _},
                       quod_catchup:decode_frame(Ns, Request)),
          %% Transport must not decode entry bytes or mint atoms from them.
          Opaque = <<"entry decoding belongs to the reader">>,
          Response = {blocks_resp_bytes, Grant, ReqId, [Opaque], 1, Next},
          Link ! {data, frame(quod_catchup:encode_frame(Ns, Response)), false},
          receive
              {catchup_page, Link, Binding, Grant, ReqId, {ok, [Opaque], 1}, Next} -> ok
          after 1000 -> error(no_page_result) end,
          receive {catchup_credit, Link, Binding, _} -> ?assert(false)
          after 20 -> ok end,
          %% A duplicate terminal has no live operation and resets the stream.
          MRef = monitor(process, Link),
          Link ! {data, frame(quod_catchup:encode_frame(Ns, Response)), false},
          receive {'DOWN', MRef, process, Link, catchup_response_violation} -> ok
          after 1000 -> error(duplicate_response_not_reset) end,
          ?assert(is_process_alive(Conn))
      end).

catchup_bootstrap_uses_one_absolute_deadline_test_() ->
    {timeout, 8,
     fun() ->
         with_credit_outbound(
           fun(Link, _Conn, _Tag, _Ns, _Channel) ->
               MRef = monitor(process, Link),
               Link ! {data, frame(<<>>), false},
               %% A partial grant arriving later cannot restart the ACK budget.
               Timer = erlang:send_after(3000, Link, {data, <<0>>, false}),
               try
                   receive {'DOWN', MRef, process, Link, no_ack} -> ok
                   after 6000 -> error(bootstrap_deadline_restarted) end
               after erlang:cancel_timer(Timer) end
           end)
     end}.

catchup_bootstrap_atomic_ordered_send_test() ->
    with_credit_inbound(
      [{error, send_queue_full}, ok],
      fun(Link, _Conn, Tag, Ns, _Channel) ->
          First = credit_wire(Tag),
          {[<<>>, Payload], <<>>} = parse(First),
          ?assertMatch({ok, {blocks_credit, _}, _},
                       quod_catchup:decode_frame(Ns, Payload)),
          {ok, _} = quod_link:test_transport(Link),
          receive {credit_wire, Tag, _} -> ?assert(false)
          after 20 -> ok end,
          Link ! {send_ready, 0},
          ?assertEqual(First, credit_wire(Tag))
      end).

catchup_server_send_acceptance_precedes_next_admission_test() ->
    with_credit_inbound(
      [],
      fun(Link, _Conn, Tag, Ns, _Channel) ->
          true = quod_reg:reg({quod_catchup, Ns}),
          try
              Grant = initial_server_grant(Tag, Ns), ReqId = <<11:128>>,
              Link ! {data, credit_request(Ns, Grant, ReqId), false},
              Operation = receive
                              {catchup_request, Link, Op, 1, 1, StartedMs}
                                when is_integer(StartedMs) -> Op
                          after 1000 -> error(no_admitted_page) end,
              ok = quod_link:test_fail_next_ordered(Link, send_queue_full),
              ok = quod_link:complete_page(Link, Operation, {ok, [], 0}),
              {ok, _} = quod_link:test_transport(Link),
              receive {catchup_page_sent, Link, Operation} -> ?assert(false)
              after 20 -> ok end,
              Link ! {send_ready, 0},
              {[Response], <<>>} = parse(credit_wire(Tag)),
              {ok, {blocks_resp_bytes, Grant, ReqId, [], 0, Next}, _} =
                  quod_catchup:decode_frame(Ns, Response),
              ?assertNotEqual(Grant, Next),
              Link ! {data, credit_request(Ns, Next, <<12:128>>), false},
              %% Both callbacks have this exact link sender: cleanup wins.
              receive
                  {catchup_page_sent, Link, Operation} -> ok;
                  {catchup_request, Link, _, _, _, _} -> error(admission_overtook_cleanup)
              after 1000 -> error(no_send_acceptance) end,
              receive {catchup_request, Link, NextOp, 1, 1, _} ->
                  ?assertNotEqual(Operation, NextOp)
              after 1000 -> error(no_successor_admission) end
          after gproc:unreg(quod_reg:name({quod_catchup, Ns})) end
      end).

catchup_batch_violation_stops_publication_test() ->
    with_credit_inbound(
      [],
      fun(Link, Conn, Tag, Ns, Channel) ->
          true = quod_reg:reg({quod_catchup, Ns}),
          true = quod_reg:subscribe({channel, Channel}),
          try
              Grant = initial_server_grant(Tag, Ns),
              Request = credit_request(Ns, Grant, <<20:128>>),
              MRef = monitor(process, Link),
              Link ! {data, <<Request/binary, Request/binary, Request/binary>>, false},
              receive {catchup_request, Link, _, 1, 1, _} -> ok
              after 1000 -> error(no_first_admission) end,
              receive {'DOWN', MRef, process, Link, catchup_credit_violation} -> ok
              after 1000 -> error(overlap_not_reset) end,
              receive
                  {catchup_request, Link, _, _, _, _} -> ?assert(false);
                  {quod_message, _, Channel, _} -> ?assert(false)
              after 20 -> ok end,
              ?assert(is_process_alive(Conn))
          after
              quod_reg:unsubscribe({channel, Channel}),
              gproc:unreg(quod_reg:name({quod_catchup, Ns}))
          end
      end).

catchup_missing_owner_returns_credit_test() ->
    with_credit_inbound(
      [],
      fun(Link, _Conn, Tag, Ns, _Channel) ->
          Grant = initial_server_grant(Tag, Ns), ReqId = <<30:128>>,
          Link ! {data, credit_request(Ns, Grant, ReqId), false},
          {[Response], <<>>} = parse(credit_wire(Tag)),
          {ok, {blocks_err, Grant, ReqId, not_ready, Next}, _} =
              quod_catchup:decode_frame(Ns, Response),
          ?assertNotEqual(Grant, Next)
      end).

catchup_source_owner_death_resets_exact_link_test() ->
    with_credit_inbound(
      [],
      fun(Link, Conn, Tag, Ns, _Channel) ->
          Parent = self(),
          Owner = spawn(fun() ->
                            true = quod_reg:reg({quod_catchup, Ns}),
                            Parent ! {credit_owner_ready, self()},
                            receive Request -> Parent ! {owner_request, Request} end,
                            receive stop -> ok end
                        end),
          try
              receive {credit_owner_ready, Owner} -> ok end,
              Grant = initial_server_grant(Tag, Ns),
              Link ! {data, credit_request(Ns, Grant, <<40:128>>), false},
              receive {owner_request, {catchup_request, Link, _, 1, 1, _}} -> ok
              after 1000 -> error(no_owner_request) end,
              MRef = monitor(process, Link),
              exit(Owner, kill),
              receive {'DOWN', MRef, process, Link, catchup_owner_down} -> ok
              after 1000 -> error(owner_death_not_reset) end,
              ?assert(is_process_alive(Conn))
          after exit(Owner, kill) end
      end).

catchup_changed_binding_retires_link_test() ->
    with_credit_outbound(
      fun(Link, _Conn, _Tag, Ns, Channel) ->
          Grant = <<50:128>>,
          Link ! {data, <<(frame(<<>>))/binary,
                          (frame(quod_catchup:encode_frame(Ns, {blocks_credit, Grant})))/binary>>,
                  false},
          receive {link_up, Channel, _, Link, out} -> ok
          after 1000 -> error(no_link_up) end,
          Binding = make_ref(),
          ok = quod_link:bind_catchup(Link, Binding),
          receive {catchup_credit, Link, Binding, Grant} -> ok
          after 1000 -> error(no_credit) end,
          MRef = monitor(process, Link),
          ok = quod_link:bind_catchup(Link, make_ref()),
          receive {'DOWN', MRef, process, Link, catchup_producer_replaced} -> ok
          after 1000 -> error(changed_binding_not_retired) end
      end).

catchup_producer_death_retires_link_test() ->
    with_credit_outbound(
      fun(Link, Conn, _Tag, Ns, Channel) ->
          Grant = <<51:128>>,
          Link ! {data, <<(frame(<<>>))/binary,
                          (frame(quod_catchup:encode_frame(Ns, {blocks_credit, Grant})))/binary>>,
                  false},
          receive {link_up, Channel, _, Link, out} -> ok
          after 1000 -> error(no_link_up) end,
          Parent = self(), Binding = make_ref(),
          Producer = spawn(fun() ->
                               ok = quod_link:bind_catchup(Link, Binding),
                               receive Credit -> Parent ! {bound_producer, self(), Credit} end,
                               receive stop -> ok end
                           end),
          try
              receive {bound_producer, Producer, {catchup_credit, Link, Binding, Grant}} -> ok
              after 1000 -> error(producer_not_bound) end,
              MRef = monitor(process, Link),
              exit(Producer, kill),
              receive {'DOWN', MRef, process, Link, catchup_owner_down} -> ok
              after 1000 -> error(producer_death_not_reset) end,
              ?assert(is_process_alive(Conn))
          after exit(Producer, kill) end
      end).

catchup_failed_terminal_send_never_returns_credit_test() ->
    with_credit_inbound(
      [],
      fun(Link, Conn, Tag, Ns, _Channel) ->
          true = quod_reg:reg({quod_catchup, Ns}),
          try
              Grant = initial_server_grant(Tag, Ns),
              Link ! {data, credit_request(Ns, Grant, <<52:128>>), false},
              Operation = receive {catchup_request, Link, Op, 1, 1, _} -> Op
                          after 1000 -> error(no_request) end,
              ok = quod_link:test_fail_next_ordered(Link, backpressure_timeout),
              MRef = monitor(process, Link),
              ok = quod_link:complete_page(Link, Operation, {error, server_error}),
              receive
                  {'DOWN', MRef, process, Link, {ordered_send_failed, backpressure_timeout}} -> ok
              after 1000 -> error(failed_terminal_not_reset) end,
              receive
                  {catchup_page_sent, Link, Operation} -> ?assert(false);
                  {credit_wire, Tag, _} -> ?assert(false)
              after 0 -> ok end,
              ?assert(is_process_alive(Conn))
          after gproc:unreg(quod_reg:name({quod_catchup, Ns})) end
      end).

with_credit_outbound(Fun) ->
    with_credit_connection(
      [], fun(Conn, Tag, Ns, Channel) ->
              Peer = {<<1:256>>, {"127.0.0.1", 1}},
              Link = quod_link:start_outbound(Conn, 0, Peer, Channel, Peer, self(), no_learn),
              try
                  _Header = credit_wire(Tag),
                  Fun(Link, Conn, Tag, Ns, Channel)
              after stop_credit_link(Link) end
          end).

with_credit_inbound(Results, Fun) ->
    with_credit_connection(
      Results, fun(Conn, Tag, Ns, Channel) ->
                   Link = quod_link:start_inbound(Conn, 0, self()),
                   try
                       Peer = {<<1:256>>, {"127.0.0.1", 1}},
                       Link ! {data, header(Peer, Channel, no_learn), false},
                       receive {authenticate_link, Link, Ref, Channel, Peer, no_learn} ->
                           Link ! {link_authenticated, self(), Ref}
                       after 1000 -> error(no_authentication_request) end,
                       Fun(Link, Conn, Tag, Ns, Channel)
                   after stop_credit_link(Link) end
               end).

with_credit_connection(Results, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Tag = make_ref(), Parent = self(),
    Ns = term_to_binary(Tag), Channel = quod_catchup:channel(Ns),
    Conn = spawn(fun() -> credit_connection(Parent, Tag, Results) end),
    try Fun(Conn, Tag, Ns, Channel)
    after
        exit(Conn, kill),
        flush_credit_wire(Tag)
    end.

credit_connection(Parent, Tag, Results) ->
    receive
        {'$gen_call', From, {send_data, 0, Data, false}} ->
            Parent ! {credit_wire, Tag, iolist_to_binary(Data)},
            {Result, Rest} = case Results of
                                 [Head | Tail] -> {Head, Tail};
                                 [] -> {ok, []}
                             end,
            gen_server:reply(From, Result),
            credit_connection(Parent, Tag, Rest);
        {'$gen_call', From, {close_stream, 0, 0}} ->
            gen_server:reply(From, ok),
            credit_connection(Parent, Tag, Results)
    end.

credit_wire(Tag) ->
    receive {credit_wire, Tag, Bytes} -> Bytes
    after 1000 -> error(no_credit_wire) end.

initial_server_grant(Tag, Ns) ->
    {[<<>>, Payload], <<>>} = parse(credit_wire(Tag)),
    {ok, {blocks_credit, Grant}, _} = quod_catchup:decode_frame(Ns, Payload),
    Grant.

credit_request(Ns, Grant, ReqId) ->
    frame(quod_catchup:encode_frame(Ns, {blocks_req, Grant, ReqId, 1, 1})).

stop_credit_link(Link) ->
    MRef = monitor(process, Link),
    quod_link:close(Link),
    receive {'DOWN', MRef, process, Link, _} -> ok
    after 1000 -> exit(Link, kill), demonitor(MRef, [flush]) end.

flush_credit_wire(Tag) ->
    receive {credit_wire, Tag, _} -> flush_credit_wire(Tag)
    after 0 -> ok end.
