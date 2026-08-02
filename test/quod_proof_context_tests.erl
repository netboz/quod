-module(quod_proof_context_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

context_test_() ->
    [?_test(with_context(fun reuses_exact_identity/1)),
     ?_test(with_context(fun rejects_anchor_conflict/1)),
     ?_test(with_context(fun bounds_distinct_scopes/1)),
     ?_test(with_context(fun bounds_invocation_proxies/1)),
     ?_test(with_context(fun binds_proxies_to_registered_owner/1)),
     ?_test(with_context(fun tracks_foreign_dirty/1)),
     ?_test(with_context(fun closes_each_scope_once/1))].

with_context(Test) ->
    ProofId = crypto:strong_rand_bytes(32),
    Handle = quod_proof_context:start(ProofId, false),
    try Test(#{proof_id => ProofId, handle => Handle})
    after quod_proof_context:stop(
            fun(_Scope) -> ok end, fun(_Proxy) -> ok end)
    end.

reuses_exact_identity(#{proof_id := ProofId, handle := Handle}) ->
    ?assertEqual({quod_proof_context, ProofId, self()}, Handle),
    ScopePid = spawn(fun wait/0),
    Identity = {<<"b">>, <<1:256>>},
    try
        {ok, first} = quod_proof_context:get_or_open_scope(
                        Identity, fun() -> {ok, ScopePid, first} end),
        {ok, first} = quod_proof_context:get_or_open_scope(
                        Identity, fun() -> error(opened_twice) end),
        ?assert(quod_proof_context:registered_scope(ScopePid)),
        ?assertEqual([first], quod_proof_context:scopes())
    after
        ScopePid ! stop
    end.

rejects_anchor_conflict(_Ctx) ->
    ScopePid = spawn(fun wait/0),
    try
        {ok, first} = quod_proof_context:get_or_open_scope(
                        {<<"b">>, <<1:256>>},
                        fun() -> {ok, ScopePid, first} end),
        ?assertEqual(
           {error, {anchor_conflict, <<"b">>}},
           quod_proof_context:get_or_open_scope(
             {<<"b">>, <<2:256>>},
             fun() -> error(must_not_open) end))
    after
        ScopePid ! stop
    end.

bounds_distinct_scopes(_Ctx) ->
    Pids = [spawn(fun wait/0) || _ <- lists:seq(1, 9)],
    try
        lists:foreach(
          fun({Index, Pid}) ->
              Ns = integer_to_binary(Index),
              Anchor = <<Index:256>>,
              {ok, Index} = quod_proof_context:get_or_open_scope(
                              {Ns, Anchor},
                              fun() -> {ok, Pid, Index} end)
          end,
          lists:zip(lists:seq(1, 8), lists:sublist(Pids, 8))),
        Ninth = lists:nth(9, Pids),
        ?assertEqual(
           {error, too_many_scopes},
           quod_proof_context:get_or_open_scope(
             {<<"9">>, <<9:256>>}, fun() -> {ok, Ninth, 9} end))
    after
        lists:foreach(fun(Pid) -> Pid ! stop end, Pids)
    end.

bounds_invocation_proxies(_Ctx) ->
    lists:foreach(
      fun(_) ->
          ?assertMatch({ok, _},
                       quod_proof_context:new_proxy(self(), stream))
      end,
      lists:seq(1, ?QUOD_MAX_PROXIES_PER_PROOF)),
    ?assertEqual(
       {error, too_many_proxies},
       quod_proof_context:new_proxy(self(), overflow)).

binds_proxies_to_registered_owner(_Ctx) ->
    ScopePid = spawn(fun wait/0),
    Stranger = spawn(fun wait/0),
    try
        {ok, scope} = quod_proof_context:get_or_open_scope(
                        {<<"b">>, <<1:256>>},
                        fun() -> {ok, ScopePid, scope} end),
        {ok, Ref} = quod_proof_context:new_proxy(ScopePid, stream0),
        ?assertEqual({ok, stream0}, quod_proof_context:proxy(Ref, ScopePid)),
        ?assertEqual({error, not_allowed},
                     quod_proof_context:proxy(Ref, Stranger)),
        ok = quod_proof_context:update_proxy(Ref, ScopePid, stream1),
        ?assertEqual({ok, stream1}, quod_proof_context:proxy(Ref, ScopePid)),
        ok = quod_proof_context:drop_proxy(Ref, ScopePid),
        ?assertEqual({error, unknown_proxy},
                     quod_proof_context:proxy(Ref, ScopePid))
    after
        ScopePid ! stop,
        Stranger ! stop
    end.

tracks_foreign_dirty(_Ctx) ->
    ScopePid = spawn(fun wait/0),
    try
        {ok, scope} = quod_proof_context:get_or_open_scope(
                        {<<"b">>, <<1:256>>},
                        fun() -> {ok, ScopePid, scope} end),
        ?assertNot(quod_proof_context:foreign_dirty()),
        ok = quod_proof_context:mark_dirty(ScopePid, true),
        ?assert(quod_proof_context:foreign_dirty()),
        ok = quod_proof_context:mark_dirty(ScopePid, false),
        ?assertNot(quod_proof_context:foreign_dirty())
    after
        ScopePid ! stop
    end.

closes_each_scope_once(_Ctx) ->
    Parent = self(),
    Pid1 = spawn(fun wait/0),
    Pid2 = spawn(fun wait/0),
    {ok, one} = quod_proof_context:get_or_open_scope(
                  {<<"b">>, <<1:256>>}, fun() -> {ok, Pid1, one} end),
    {ok, two} = quod_proof_context:get_or_open_scope(
                  {<<"c">>, <<2:256>>}, fun() -> {ok, Pid2, two} end),
    NoProxy = fun(_Proxy) -> ok end,
    ok = quod_proof_context:stop(
           fun(Scope) -> Parent ! {closed, Scope} end, NoProxy),
    Closed = lists:sort([receive {closed, S1} -> S1 end,
                         receive {closed, S2} -> S2 end]),
    ?assertEqual([one, two], Closed),
    ?assertEqual(
       ok,
       quod_proof_context:stop(
         fun(_) -> error(double_close) end, NoProxy)),
    Pid1 ! stop,
    Pid2 ! stop.

wait() ->
    receive stop -> ok end.
