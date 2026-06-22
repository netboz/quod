-module(quod_reg_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- pure key constructors -----------------------------------------------

name_test() ->
    ?assertEqual({n, l, {conn, foo}}, quod_reg:name({conn, foo})).

prop_test() ->
    ?assertEqual({p, l, {conn, foo}}, quod_reg:prop({conn, foo})).

via_test() ->
    ?assertEqual({via, gproc, {n, l, {transport, node}}},
                 quod_reg:via({transport, node})).

%% --- gproc-backed pub/sub ------------------------------------------------

gproc_test_() ->
    {setup,
     fun() -> {ok, _Started} = application:ensure_all_started(gproc), ok end,
     fun(_) -> ok = application:stop(gproc) end,
     [{"publish reaches a subscriber",        fun pubsub_delivers/0},
      {"unsubscribe stops delivery",          fun unsubscribe_stops/0},
      {"where/1 finds a registered name",     fun where_finds/0},
      {"publish with no subscribers is safe", fun publish_to_nobody/0},
      {"every subscriber receives",           fun fanout/0}]}.

pubsub_delivers() ->
    K = {channel, <<"d1">>},
    true = quod_reg:subscribe(K),
    quod_reg:publish(K, ping),
    receive ping -> ok after 1000 -> erlang:error(timeout) end,
    true = quod_reg:unsubscribe(K).

unsubscribe_stops() ->
    K = {channel, <<"d2">>},
    true = quod_reg:subscribe(K),
    true = quod_reg:unsubscribe(K),
    quod_reg:publish(K, nope),
    receive nope -> erlang:error(should_not_arrive) after 100 -> ok end.

where_finds() ->
    K = {conn, {"127.0.0.1", 14567}},
    Self = self(),
    true = quod_reg:reg(K),
    ?assertEqual(Self, quod_reg:where(K)),
    true = gproc:unreg({n, l, K}).

publish_to_nobody() ->
    %% no registrants -> must not crash; gproc:send returns the event
    ?assertEqual(lonely, quod_reg:publish({channel, <<"void">>}, lonely)).

fanout() ->
    K = {channel, <<"d3">>},
    Parent = self(),
    Sub = fun() ->
              true = quod_reg:subscribe(K),
              Parent ! ready,
              receive Msg -> Parent ! {got, Msg} end
          end,
    _ = spawn(Sub),
    _ = spawn(Sub),
    ok = await(ready),
    ok = await(ready),
    quod_reg:publish(K, broadcast),
    G1 = await_got(),
    G2 = await_got(),
    ?assertEqual([broadcast, broadcast], [G1, G2]).

await(Tag) ->
    receive Tag -> ok after 1000 -> erlang:error({timeout, Tag}) end.

await_got() ->
    receive {got, M} -> M after 1000 -> erlang:error(timeout) end.
