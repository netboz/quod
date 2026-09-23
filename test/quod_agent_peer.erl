-module(quod_agent_peer).
-export([start/1, stop/1]).

%% Real isolated transport peer shared by recovery integration tests.
start(Dir) ->
    {ok, Socket} = gen_udp:open(0),
    {ok, Port} = inet:port(Socket),
    ok = gen_udp:close(Socket),
    {Pub, _} = Pair = quod_identity:generate(),
    {ok, Peer, _} = peer:start(#{connection => standard_io,
                                args => ["+S", "2:2", "-pa" | code:get_path()]}),
    try
        ok = peer:call(Peer, application, load, [quod]),
        lists:foreach(fun({K, V}) ->
            ok = peer:call(Peer, application, set_env, [quod, K, V])
        end, [{listen_port, Port}, {node_addr, {"127.0.0.1", Port}},
              {node_pubkey, Pub}, {identity_cert, quod_identity:mint_cert(Pair)},
              {identity_key, quod_identity:key_term(Pair)},
              {effect_journal_data_dir, Dir},
              {foreign_log, #{cache_dir => filename:join(Dir, "foreign-history")}}]),
        {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
        {Peer, Pub, {"127.0.0.1", Port}}
    catch C:R:Stack -> catch peer:stop(Peer), erlang:raise(C, R, Stack)
    end.


stop(Peer) ->
    ok = peer:call(Peer, application, stop, [quod]),
    ok = peer:call(Peer, application, stop, [quic]),
    peer:stop(Peer).
