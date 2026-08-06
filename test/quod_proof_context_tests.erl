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
     ?_test(with_context(fun local_typed_death_wins_finalization/1)),
     ?_test(with_context(fun live_local_scope_is_closed_at_finalization/1)),
     ?_test(with_context(fun binds_one_exact_router_generation/1)),
     ?_test(with_context(fun finalizes_remote_router_once/1)),
     ?_test(with_context(fun retains_finalization_poison/1)),
     ?_test(with_context(fun maps_dead_router_to_target/1)),
     ?_test(with_context(fun closes_each_scope_once/1))].

with_context(Test) ->
    ProofId = crypto:strong_rand_bytes(32),
    OriginIdentity = {<<"origin">>, <<0:256>>},
    Handle = quod_proof_context:start(
               ProofId, false, OriginIdentity,
               quod_time:mono_ms() + 60000),
    try Test(#{proof_id => ProofId, handle => Handle})
    after quod_proof_context:stop(
            fun(_Scope) -> ok end, fun(_Proxy) -> ok end)
    end.

reuses_exact_identity(#{proof_id := ProofId, handle := Handle}) ->
    ?assertEqual({quod_proof_context, ProofId, self()}, Handle),
    ScopePid = spawn(fun wait/0),
    Identity = {<<"b">>, <<1:256>>},
    try
        {ok, ScopeId, first} = quod_proof_context:get_or_open_scope(
                                 Identity,
                                 fun(_Id) -> {ok, ScopePid, first} end),
        {ok, ScopeId, first} = quod_proof_context:get_or_open_scope(
                                 Identity,
                                 fun(_Id) -> error(opened_twice) end),
        ?assert(quod_proof_context:registered_scope(ScopeId)),
        ?assertEqual({ok, ScopePid},
                     quod_proof_context:scope_owner(ScopeId)),
        ?assertEqual([first], quod_proof_context:scopes())
    after
        ScopePid ! stop
    end.

rejects_anchor_conflict(_Ctx) ->
    ScopePid = spawn(fun wait/0),
    try
        {ok, _ScopeId, first} = quod_proof_context:get_or_open_scope(
                        {<<"b">>, <<1:256>>},
                        fun(_Id) -> {ok, ScopePid, first} end),
        ?assertEqual(
           {error, {anchor_conflict, <<"b">>}},
           quod_proof_context:get_or_open_scope(
             {<<"b">>, <<2:256>>},
             fun(_Id) -> error(must_not_open) end))
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
              {ok, _ScopeId, Index} = quod_proof_context:get_or_open_scope(
                              {Ns, Anchor},
                              fun(_Id) -> {ok, Pid, Index} end)
          end,
          lists:zip(lists:seq(1, 8), lists:sublist(Pids, 8))),
        Ninth = lists:nth(9, Pids),
        ?assertEqual(
           {error, {scope_limit_exceeded, ?QUOD_MAX_SCOPES_PER_PROOF}},
           quod_proof_context:get_or_open_scope(
             {<<"9">>, <<9:256>>},
             fun(_Id) -> {ok, Ninth, 9} end))
    after
        lists:foreach(fun(Pid) -> Pid ! stop end, Pids)
    end.

bounds_invocation_proxies(_Ctx) ->
    Actor = register_actor(self(), <<"proxy-owner">>, <<99:256>>),
    lists:foreach(
      fun(_) ->
          ?assertMatch({ok, _},
                       quod_proof_context:new_proxy(
                         Actor, <<"proxy-target">>, stream))
      end,
      lists:seq(1, ?QUOD_MAX_PROXIES_PER_PROOF)),
    ?assertEqual(
       {error, {proof_limit_exceeded, <<"proxy-target">>}},
       quod_proof_context:new_proxy(Actor, <<"proxy-target">>, overflow)),
    quod_proof_context:unregister_invocation(Actor).

binds_proxies_to_registered_owner(_Ctx) ->
    ScopePid = spawn(fun wait/0),
    try
        {ok, ScopeId, scope} = quod_proof_context:get_or_open_scope(
                        {<<"b">>, <<1:256>>},
                        fun(_Id) -> {ok, ScopePid, scope} end),
        Owner = {ScopeId, opaque_id()},
        OtherInvocation = {ScopeId, opaque_id()},
        StrangerActor = {opaque_id(), opaque_id()},
        ok = quod_proof_context:register_invocation(
               Owner, quod_transaction_scope:empty_selection()),
        ok = quod_proof_context:register_invocation(
               OtherInvocation, quod_transaction_scope:empty_selection()),
        {ok, Ref} = quod_proof_context:new_proxy(
                      Owner, <<"b">>, stream0),
        ?assertEqual({ok, stream0}, quod_proof_context:proxy(Ref, Owner)),
        ?assertEqual({error, not_allowed},
                     quod_proof_context:proxy(Ref, OtherInvocation)),
        ?assertEqual({error, not_allowed},
                     quod_proof_context:proxy(Ref, StrangerActor)),
        ?assertEqual({error, bad_request},
                     quod_proof_context:register_invocation(
                       {ScopeId, <<1>>},
                       quod_transaction_scope:empty_selection())),
        ok = quod_proof_context:update_proxy(Ref, Owner, stream1),
        ?assertEqual({ok, stream1}, quod_proof_context:proxy(Ref, Owner)),
        ok = quod_proof_context:drop_proxy(Ref, Owner),
        ?assertEqual({error, unknown_proxy},
                     quod_proof_context:proxy(Ref, Owner)),
        quod_proof_context:unregister_invocation(Owner),
        quod_proof_context:unregister_invocation(OtherInvocation)
    after
        ScopePid ! stop
    end.

tracks_foreign_dirty(_Ctx) ->
    ScopePid = spawn(fun wait/0),
    try
        {ok, ScopeId, scope} = quod_proof_context:get_or_open_scope(
                        {<<"b">>, <<1:256>>},
                        fun(_Id) -> {ok, ScopePid, scope} end),
        ?assertNot(quod_proof_context:foreign_dirty()),
        ok = quod_proof_context:mark_dirty(ScopeId, true),
        ?assert(quod_proof_context:foreign_dirty()),
        ok = quod_proof_context:mark_dirty(ScopeId, false),
        ?assertNot(quod_proof_context:foreign_dirty())
    after
        ScopePid ! stop
    end.

local_typed_death_wins_finalization(#{proof_id := ProofId}) ->
    Parent = self(),
    ScopePid = spawn(
                 fun() ->
                     Parent ! {scope_answer, self(), ok},
                     receive {die, Reason} -> exit(Reason) end
                 end),
    ExternalMRef = monitor(process, ScopePid),
    Ns = <<"local-target">>,
    Anchor = <<14:256>>,
    {ok, _ScopeId, _Handle} = quod_proof_context:get_or_open_scope(
                               {Ns, Anchor},
                               fun(ScopeId) ->
                                   Handle = {quod_scope_session, ScopePid,
                                             ScopeId, ProofId, make_ref(),
                                             Ns, Anchor},
                                   {ok, ScopePid, Handle}
                               end),
    receive {scope_answer, ScopePid, ok} -> ok
    after 1000 -> error(scope_answer_missing)
    end,
    Typed = {scope_error, {scope_expired, Ns}},
    ScopePid ! {die, Typed},
    receive {'DOWN', ExternalMRef, process, ScopePid, Typed} -> ok
    after 1000 -> error(scope_did_not_die)
    end,
    ?assertEqual({error, {scope_expired, Ns}},
                 quod_proof_context:finalize()).

live_local_scope_is_closed_at_finalization(#{proof_id := ProofId}) ->
    Parent = self(),
    ScopePid = spawn(
                 fun Loop() ->
                     receive
                         {scope_close, _Origin, ProofId, _SessionRef} ->
                             Parent ! {scope_closed, self()};
                         _ -> Loop()
                     end
                 end),
    Ns = <<"live-local-target">>,
    Anchor = <<15:256>>,
    {ok, _ScopeId, _Handle} = quod_proof_context:get_or_open_scope(
                               {Ns, Anchor},
                               fun(ScopeId) ->
                                   Handle = {quod_scope_session, ScopePid,
                                             ScopeId, ProofId, make_ref(),
                                             Ns, Anchor},
                                   {ok, ScopePid, Handle}
                               end),
    ?assertEqual(ok, quod_proof_context:finalize()),
    receive {scope_closed, ScopePid} -> ok
    after 1000 -> error(scope_not_closed_at_finalize)
    end.

binds_one_exact_router_generation(_Ctx) ->
    Router = spawn(fun wait/0),
    Successor = spawn(fun wait/0),
    Generation = <<3:128>>,
    try
        Monitors0 = process_monitors(),
        {ok, MRef} = quod_proof_context:bind_router(
                       Router, Generation, <<"remote-b">>),
        ?assertEqual(
           {ok, MRef},
           quod_proof_context:bind_router(
             Router, Generation, <<"remote-a">>)),
        ?assertEqual(
           1, length(process_monitors() -- Monitors0)),
        ?assertEqual(
           {error, {protocol_error, session_binding}},
           quod_proof_context:bind_router(
             Router, <<4:128>>, <<"remote-a">>)),
        ?assertEqual(
           {error, {ontology_unreachable, <<"remote-a">>}},
           quod_proof_context:bind_router(
             Successor, <<5:128>>, <<"remote-a">>))
    after
        Router ! stop,
        Successor ! stop
    end.

finalizes_remote_router_once(#{proof_id := ProofId}) ->
    Router = fake_finalize_router(self(), ok),
    RequestLink = spawn(fun wait/0),
    Owner = self(),
    try
        {ok, _} = bind_remote_router(Router),
        Remote = remote_handle(Router, RequestLink, ProofId, 1),
        {ok, _ScopeId, Remote} = quod_proof_context:get_or_open_scope(
                                  {<<"remote">>, <<11:256>>},
                                  fun(_Id) -> {ok, Router, Remote} end),
        ?assertEqual(ok, quod_proof_context:finalize()),
        receive {router_finalized, Router, Owner, ProofId} -> ok
        after 1000 -> error(finalize_not_called)
        end,
        ?assertEqual(ok, quod_proof_context:finalize()),
        receive {router_finalized, Router, Owner, ProofId} ->
                    error(finalized_twice)
        after 20 -> ok
        end,
        ?assertEqual(
           {error, proof_finalized},
           quod_proof_context:get_or_open_scope(
             {<<"late">>, <<12:256>>},
             fun(_Id) -> error(opened_after_finalize) end))
    after
        Router ! stop,
        RequestLink ! stop
    end.

retains_finalization_poison(#{proof_id := ProofId}) ->
    RouterPoison = {error, {scope_error,
                           {scope_expired, <<"remote">>}}},
    PublicPoison = {error, {scope_expired, <<"remote">>}},
    Router = fake_finalize_router(self(), RouterPoison),
    RequestLink = spawn(fun wait/0),
    Owner = self(),
    try
        {ok, _} = bind_remote_router(Router),
        Remote = remote_handle(Router, RequestLink, ProofId, 2),
        {ok, _ScopeId, Remote} = quod_proof_context:get_or_open_scope(
                                  {<<"remote">>, <<13:256>>},
                                  fun(_Id) -> {ok, Router, Remote} end),
        ?assertEqual(PublicPoison, quod_proof_context:finalize()),
        ?assertEqual(PublicPoison, quod_proof_context:finalize()),
        receive {router_finalized, Router, Owner, ProofId} -> ok
        after 1000 -> error(finalize_not_called)
        end,
        receive {router_finalized, Router, Owner, ProofId} ->
                    error(poison_fence_repeated)
        after 20 -> ok
        end
    after
        Router ! stop,
        RequestLink ! stop
    end.

maps_dead_router_to_target(#{proof_id := ProofId}) ->
    Router = spawn(fun() -> ok end),
    RouterMRef = monitor(process, Router),
    receive {'DOWN', RouterMRef, process, Router, normal} -> ok
    after 1000 -> error(router_did_not_stop)
    end,
    RequestLink = spawn(fun wait/0),
    try
        {ok, _} = bind_remote_router(Router),
        Remote = remote_handle(Router, RequestLink, ProofId, 3),
        {ok, _ScopeId, Remote} = quod_proof_context:get_or_open_scope(
                                  {<<"remote">>, <<11:256>>},
                                  fun(_Id) -> {ok, Router, Remote} end),
        ?assertEqual(
           {error, {ontology_unreachable, <<"remote">>}},
           quod_proof_context:finalize())
    after
        RequestLink ! stop
    end.

closes_each_scope_once(_Ctx) ->
    Parent = self(),
    Pid1 = spawn(fun wait/0),
    Pid2 = spawn(fun wait/0),
    {ok, _ScopeId1, one} = quod_proof_context:get_or_open_scope(
                  {<<"b">>, <<1:256>>},
                  fun(_Id) -> {ok, Pid1, one} end),
    {ok, _ScopeId2, two} = quod_proof_context:get_or_open_scope(
                  {<<"c">>, <<2:256>>},
                  fun(_Id) -> {ok, Pid2, two} end),
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

fake_finalize_router(TestPid, Result) ->
    spawn(fun() -> fake_finalize_router_loop(TestPid, Result) end).

fake_finalize_router_loop(TestPid, Result) ->
    receive
        {'$gen_call', From, {finalize, Owner, ProofId}} ->
            TestPid ! {router_finalized, self(), Owner, ProofId},
            gen_server:reply(From, Result),
            fake_finalize_router_loop(TestPid, Result);
        stop -> ok
    end.

remote_handle(Router, RequestLink, ProofId, N) ->
    Binding = {scope_binding, <<1:256>>, <<2:256>>, ProofId, <<N:128>>,
               {<<"origin">>, <<0:256>>}, {<<"remote">>, <<11:256>>},
               read_write},
    {remote_scope, Router, <<3:128>>, Binding, RequestLink}.

bind_remote_router(Router) ->
    quod_proof_context:bind_router(Router, <<3:128>>, <<"remote">>).

process_monitors() ->
    {monitors, Monitors} = process_info(self(), monitors),
    Monitors.

register_actor(Pid, Ns, Anchor) ->
    {ok, ScopeId, scope} = quod_proof_context:get_or_open_scope(
                    {Ns, Anchor}, fun(_Id) -> {ok, Pid, scope} end),
    Actor = {ScopeId, opaque_id()},
    ok = quod_proof_context:register_invocation(
           Actor, quod_transaction_scope:empty_selection()),
    Actor.

opaque_id() -> crypto:strong_rand_bytes(16).
