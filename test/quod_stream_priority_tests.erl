-module(quod_stream_priority_tests).
-include_lib("eunit/include/eunit.hrl").

channel_classes_test() ->
    Cases = [{{log, <<"a">>}, {0, false}},
             {{catchup, <<"a">>}, {1, true}},
             {{ingress, <<"a">>}, {2, false}},
             {{quod_dtx, <<"a">>}, {2, false}},
             {quod_directory_control, {2, false}},
             {{feed, <<"a">>}, {4, true}},
             {{quod_scope, <<"a">>}, {4, true}},
             {{quod_scope_return, <<1:256>>}, {4, true}},
             {quod_client_goal_v1, {6, true}}],
    [?assertEqual(Priority, element(1, quod_link:channel_config(
                             term_to_binary(Channel, [deterministic]), requester)))
     || {Channel, Priority} <- Cases].

untrusted_channel_cannot_claim_control_priority_test() ->
    Log = term_to_binary({log, <<"a">>}, [deterministic]),
    Inputs = [<<"log">>, <<>>, <<Log/binary, 0>>,
              term_to_binary({log, <<>>}),
              term_to_binary({log, [a]}),
              term_to_binary({log, binary:copy(<<"a">>, 100)}, [compressed]),
              binary:copy(<<0>>, 65536),
              term_to_binary({quod_scope_return, <<1>>})],
    [?assertEqual({6, true}, element(1, quod_link:channel_config(Input, requester)))
     || Input <- Inputs].

priority_precedes_header_and_authenticated_ack_test_() ->
    [?_test(priority_before_send(Direction)) || Direction <- [out, in]].

priority_failure_sends_nothing_and_resets_stream_test_() ->
    [?_test(priority_failure(Direction)) || Direction <- [out, in]].

priority_before_send(Direction) ->
    with_link(Direction,
      fun(Link, MRef, Conn, Ref) ->
          receive {priority, Ref, From, {0, false}} ->
              gen_server:reply(From, ok);
              {wire, Ref, _} -> error(sent_before_priority)
          after 1000 -> error(no_priority_request) end,
          receive {wire, Ref, _Bytes} -> ok
          after 1000 -> error(no_header_or_ack) end,
          stop(Link, MRef),
          Conn ! stop
      end).

priority_failure(Direction) ->
    with_link(Direction,
      fun(Link, MRef, Conn, Ref) ->
          receive {priority, Ref, From, {0, false}} ->
              gen_server:reply(From, {error, unknown_stream});
              {wire, Ref, _} -> error(sent_before_priority)
          after 1000 -> error(no_priority_request) end,
          receive {reset, Ref} -> ok
          after 1000 -> error(no_failed_stream_reset) end,
          receive {'DOWN', MRef, process, Link, stream_priority_failed} -> ok
          after 1000 -> error(no_failed_link_exit) end,
          %% The same connection sends wire/reset evidence in processing order.
          receive {wire, Ref, _} -> error(sent_without_priority)
          after 0 -> ok end,
          Conn ! stop
      end).

with_link(Direction, Fun) ->
    Parent = self(), Ref = make_ref(),
    Conn = spawn(fun() -> connection(Parent, Ref) end),
    Peer = {<<1:256>>, {"127.0.0.1", 1}},
    Channel = term_to_binary({log, <<"priority">>}, [deterministic]),
    Link = case Direction of
               out -> quod_link:start_outbound(
                        Conn, 0, Peer, Channel, Peer, self(), no_learn);
               in -> quod_link:start_inbound(Conn, 0, self())
           end,
    MRef = monitor(process, Link),
    try
        case Direction of
            out -> ok;
            in ->
                Link ! {data, quod_link:header(Peer, Channel, no_learn), false},
                receive {authenticate_link, Link, Auth, Channel, Peer, no_learn} ->
                    Link ! {link_authenticated, self(), Auth}
                after 1000 -> error(no_authentication_request) end
        end,
        Fun(Link, MRef, Conn, Ref)
    after
        exit(Link, kill), exit(Conn, kill), demonitor(MRef, [flush])
    end.

connection(Parent, Ref) ->
    receive
        {'$gen_call', From, {set_stream_priority, 0, U, I}} ->
            Parent ! {priority, Ref, From, {U, I}},
            connection(Parent, Ref);
        {'$gen_call', From, {send_data, 0, Bytes, false}} ->
            Parent ! {wire, Ref, Bytes},
            gen_server:reply(From, ok), connection(Parent, Ref);
        {'$gen_call', From, {close_stream, 0, 0}} ->
            Parent ! {reset, Ref},
            gen_server:reply(From, ok), connection(Parent, Ref);
        stop -> ok
    end.

stop(Link, MRef) ->
    quod_link:close(Link),
    receive {'DOWN', MRef, process, Link, normal} -> ok
    after 1000 -> error(link_not_closed) end.
