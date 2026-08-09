-module(quod_proof_savepoint_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

restore_rolls_back_writes_but_keeps_reads_test() ->
    Session = quod_proof_session:start(
                committed([{source, value}]), #{read_set => true}),
    try
        Generation0 = quod_proof_session:overlay_generation(Session),
        ok = quod_proof_session:checkpoint_many(Session, [before_write]),
        Writer = opaque_id(),
        ok = quod_proof_session:open(
               Session, Writer,
               {',', {source, value}, {assertz, {staged, value}}},
               context(), empty_selection()),
        ?assertMatch({solution, _}, quod_proof_session:next(Session, Writer)),
        ?assert(quod_proof_session:dirty(Session)),
        ?assert(quod_proof_session:overlay_generation(Session) > Generation0),

        ok = quod_proof_session:restore_many(Session, [before_write]),
        ?assertNot(quod_proof_session:dirty(Session)),
        ?assert(maps:is_key(
                  {source, 1}, quod_proof_session:read_set(Session))),
        ok = quod_proof_session:release_many(Session, [before_write]),
        ok = quod_proof_session:release_many(Session, [before_write]),
        ?assertEqual(
           {error, unknown_savepoint},
           quod_proof_session:restore_many(Session, [before_write]))
    after
        quod_proof_session:stop(Session)
    end.

checkpoint_is_first_writer_wins_test() ->
    Session = quod_proof_session:start(committed([]), #{}),
    try
        ok = quod_proof_session:checkpoint_many(Session, [branch]),
        prove_write(Session, {first, retained}),
        ok = quod_proof_session:checkpoint_many(Session, [branch]),
        prove_write(Session, {second, retained}),
        ok = quod_proof_session:restore_many(Session, [branch]),
        ?assertEqual([], quod_proof_session:local_changes(Session))
    after
        quod_proof_session:stop(Session)
    end.

savepoint_limit_is_checked_before_mutation_test() ->
    Session = quod_proof_session:start(committed([]), #{}),
    try
        lists:foreach(
          fun(Id) ->
              ok = quod_proof_session:checkpoint_many(Session, [Id])
          end,
          lists:seq(1, ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF)),
        Generation = quod_proof_session:overlay_generation(Session),
        ?assertEqual(
           {error,
            {savepoint_limit_exceeded,
             ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF}},
           quod_proof_session:checkpoint_many(Session, [overflow])),
        ?assertEqual(
           Generation, quod_proof_session:overlay_generation(Session)),
        ok = quod_proof_session:release_many(Session, [1]),
        ok = quod_proof_session:checkpoint_many(Session, [replacement])
    after
        quod_proof_session:stop(Session)
    end.

exact_selection_materializes_only_live_batches_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    _ = start_context(ProofId),
    SessionA = quod_proof_session:start(committed([]), #{}),
    SessionB = quod_proof_session:start(committed([]), #{}),
    SessionC = quod_proof_session:start(committed([]), #{}),
    PidB = spawn(fun wait/0),
    PidC = spawn(fun wait/0),
    try
        ScopeA = register_local_scope(<<"a">>, 1, self(), SessionA),
        ScopeB = register_local_scope(<<"b">>, 2, PidB, SessionB),
        ScopeC = register_local_scope(<<"c">>, 3, PidC, SessionC),
        ActorA = actor(ScopeA),
        ActorB = actor(ScopeB),
        ActorC = actor(ScopeC),
        ok = quod_proof_context:register_invocation(
               ActorA, empty_selection()),
        Frame = opaque_id(),
        {ok, Lineage,
         [{Frame, TxId, Lineage, _Baseline}]} =
            quod_proof_context:tx_request(
              ActorA, {activate, none, [Frame]}),
        ok = quod_proof_context:register_invocation(
               ActorB, selection(Lineage, [])),
        ok = quod_proof_context:register_invocation(
               ActorC, selection(Lineage, [])),
        {ok, StaleProxy} = quod_proof_context:new_proxy(
                             ActorB, <<"b">>, retained_for_cleanup),
        {ok, StaleBatch} = quod_proof_context:tx_request(
                             ActorA, {allocate, Lineage}),
        {ok, LiveBatch} = quod_proof_context:tx_request(
                            ActorA, {allocate, Lineage}),

        %% Selecting only LiveBatch must not eagerly checkpoint StaleBatch.
        ok = quod_proof_context:materialize(
               selection(Lineage, [LiveBatch]), ActorC),
        prove_write(SessionC, {after_live, retained}),
        ok = quod_proof_context:materialize(
               selection(Lineage, [StaleBatch]), ActorC),
        prove_write(SessionC, {after_stale, removed}),
        ok = quod_proof_context:tx_request(
               ActorA, {restore, Lineage, [StaleBatch]}),
        Changes = quod_proof_session:local_changes(SessionC),
        ?assert(has_assert({after_live, retained}, Changes)),
        ?assertNot(has_assert({after_stale, removed}, Changes)),

        %% Successful once/1 cuts away target selector continuations without an
        %% Erlog destructor. Finishing the transaction invalidates those stale
        %% registrations instead of refusing the otherwise valid commit.
        {ok, none} = quod_proof_context:tx_request(
                       ActorA, {finish, Lineage, TxId}),
        ?assertNot(quod_proof_context:registered_invocation(ActorB, Lineage)),
        ?assertNot(quod_proof_context:registered_invocation(ActorC, Lineage)),
        ?assertEqual(
           {error, not_allowed},
           quod_proof_context:proxy(StaleProxy, ActorB)),
        quod_proof_context:unregister_invocation(ActorA)
    after
        quod_proof_context:stop(fun quod_scope_session:close/1,
                                fun(_Proxy) -> ok end),
        quod_proof_session:stop(SessionA),
        quod_proof_session:stop(SessionB),
        quod_proof_session:stop(SessionC),
        PidB ! stop,
        PidC ! stop
    end.

invalid_selection_is_atomic_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    _ = start_context(ProofId),
    SessionA = quod_proof_session:start(committed([]), #{}),
    SessionB = quod_proof_session:start(committed([]), #{}),
    PidB = spawn(fun wait/0),
    try
        ScopeA = register_local_scope(<<"a">>, 1, self(), SessionA),
        ScopeB = register_local_scope(<<"b">>, 2, PidB, SessionB),
        ActorA = actor(ScopeA),
        ActorB = actor(ScopeB),
        ok = quod_proof_context:register_invocation(
               ActorA, empty_selection()),
        Frame = opaque_id(),
        {ok, Lineage, [{Frame, TxId, Lineage, _Baseline}]} =
            quod_proof_context:tx_request(
              ActorA, {activate, none, [Frame]}),
        ok = quod_proof_context:register_invocation(
               ActorB, selection(Lineage, [])),
        {ok, LiveBatch} = quod_proof_context:tx_request(
                            ActorA, {allocate, Lineage}),
        Unknown = unique_id([LiveBatch]),
        ?assertEqual(
           {error, unknown_savepoint},
           quod_proof_context:materialize(
             selection(Lineage, [LiveBatch, Unknown]), ActorB)),

        %% If the invalid mixed selection had partially checkpointed LiveBatch,
        %% restoring it would erase this write. The later valid materialization
        %% must instead capture the write as its baseline.
        prove_write(SessionB, {before_valid_selection, retained}),
        ok = quod_proof_context:materialize(
               selection(Lineage, [LiveBatch]), ActorB),
        prove_write(SessionB, {after_valid_selection, removed}),
        ok = quod_proof_context:tx_request(
               ActorA, {restore, Lineage, [LiveBatch]}),
        Changes = quod_proof_session:local_changes(SessionB),
        ?assert(has_assert({before_valid_selection, retained}, Changes)),
        ?assertNot(has_assert({after_valid_selection, removed}, Changes)),

        quod_proof_context:unregister_invocation(ActorB),
        {ok, none} = quod_proof_context:tx_request(
                       ActorA, {finish, Lineage, TxId}),
        quod_proof_context:unregister_invocation(ActorA)
    after
        quod_proof_context:stop(fun quod_scope_session:close/1,
                                fun(_Proxy) -> ok end),
        quod_proof_session:stop(SessionA),
        quod_proof_session:stop(SessionB),
        PidB ! stop,
        ok
    end.

controller_transaction_and_lineage_caps_share_public_error_test() ->
    _ = start_context(crypto:strong_rand_bytes(32)),
    Session = quod_proof_session:start(committed([]), #{}),
    try
        ScopeId = register_local_scope(<<"a">>, 1, self(), Session),
        Actor = actor(ScopeId),
        ok = quod_proof_context:register_invocation(
               Actor, empty_selection()),
        Frames = unique_ids(?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF),
        {ok, Lineage, _} = quod_proof_context:tx_request(
                             Actor, {activate, none, Frames}),
        ?assertEqual(
           {error,
            {savepoint_limit_exceeded,
             ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF}},
           quod_proof_context:tx_request(
             Actor, {activate, Lineage, [opaque_id()]}))
    after
        quod_proof_context:stop(fun(_Scope) -> ok end,
                                fun(_Proxy) -> ok end),
        quod_proof_session:stop(Session)
    end.

controller_batch_cap_uses_same_public_error_test() ->
    _ = start_context(crypto:strong_rand_bytes(32)),
    Session = quod_proof_session:start(committed([]), #{}),
    try
        ScopeId = register_local_scope(<<"a">>, 1, self(), Session),
        Actor = actor(ScopeId),
        ok = quod_proof_context:register_invocation(
               Actor, empty_selection()),
        Frame = opaque_id(),
        {ok, Lineage, _} = quod_proof_context:tx_request(
                             Actor, {activate, none, [Frame]}),
        lists:foreach(
          fun(_) ->
              ?assertMatch(
                 {ok, <<_:128>>},
                 quod_proof_context:tx_request(
                   Actor, {allocate, Lineage}))
          end,
          lists:seq(2, ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF)),
        ?assertEqual(
           {error,
            {savepoint_limit_exceeded,
             ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF}},
           quod_proof_context:tx_request(Actor, {allocate, Lineage}))
    after
        quod_proof_context:stop(fun(_Scope) -> ok end,
                                fun(_Proxy) -> ok end),
        quod_proof_session:stop(Session)
    end.

malformed_controller_lists_fail_before_mutation_test() ->
    _ = start_context(crypto:strong_rand_bytes(32)),
    Session = quod_proof_session:start(committed([]), #{}),
    try
        ScopeId = register_local_scope(<<"a">>, 1, self(), Session),
        Actor = actor(ScopeId),
        ok = quod_proof_context:register_invocation(
               Actor, empty_selection()),
        Frame = opaque_id(),
        ?assertNot(
           quod_transaction_scope:valid_selection(
             {tx_selection, none, [opaque_id() | improper]})),
        ?assertEqual(
           {error, bad_request},
           quod_proof_context:tx_request(
             Actor, {activate, none, [Frame | improper]})),

        %% The malformed request allocated nothing; the same frame remains a
        %% valid first activation and yields one clean lineage.
        {ok, Lineage, [{Frame, TxId, Lineage, Baseline}]} =
            quod_proof_context:tx_request(
              Actor, {activate, none, [Frame]}),
        ?assertEqual(
           {error, bad_request},
           quod_proof_context:tx_request(
             Actor, {restore, Lineage, [Baseline | improper]})),
        ?assertEqual(
           {error, bad_request},
           quod_proof_context:materialize(
             {tx_selection, Lineage, [Baseline | improper]}, Actor)),
        {ok, none} = quod_proof_context:tx_request(
                       Actor, {finish, Lineage, TxId})
    after
        quod_proof_context:stop(fun(_Scope) -> ok end,
                                fun(_Proxy) -> ok end),
        quod_proof_session:stop(Session)
    end.

prove_write(Session, Fact) ->
    prove_goal(Session, {assertz, Fact}).

prove_goal(Session, Goal) ->
    Invocation = opaque_id(),
    ok = quod_proof_session:open(
           Session, Invocation, Goal, context(), empty_selection()),
    ?assertMatch({solution, _}, quod_proof_session:next(Session, Invocation)).

empty_selection() -> quod_transaction_scope:empty_selection().

selection(Lineage, BatchIds) ->
    {tx_selection, Lineage, lists:usort(BatchIds)}.

actor(ScopeId) -> {ScopeId, opaque_id()}.

opaque_id() -> crypto:strong_rand_bytes(16).

unique_id(Existing) ->
    Id = opaque_id(),
    case lists:member(Id, Existing) of
        true -> unique_id(Existing);
        false -> Id
    end.

unique_ids(Count) -> unique_ids(Count, #{}).

unique_ids(0, Ids) -> maps:keys(Ids);
unique_ids(Count, Ids) ->
    Id = opaque_id(),
    case maps:is_key(Id, Ids) of
        true -> unique_ids(Count, Ids);
        false -> unique_ids(Count - 1, Ids#{Id => true})
    end.

has_assert(Fact, Changes) ->
    lists:any(fun({assert, {Candidate, _}}) -> Candidate =:= Fact;
                 (_) -> false
              end, Changes).

register_local_scope(Ns, AnchorByte, Pid, Session) ->
    Anchor = <<AnchorByte:256>>,
    {ok, ScopeId,
     {local_scope, ScopeId, Ns, Anchor, 1, Session}} =
        quod_proof_context:get_or_open_scope(
          {Ns, Anchor},
          fun(NewScopeId) ->
              {ok, Pid,
               {local_scope, NewScopeId, Ns, Anchor, 1, Session}}
          end),
    ScopeId.

start_context(ProofId) ->
    quod_proof_context:start(
      ProofId, false, {<<"quod:savepoint-origin">>, <<0:256>>},
      quod_time:mono_ms() + 60000, anonymous).

wait() ->
    receive stop -> ok end.

context() ->
    quod_predicates:proof_context(
      <<"quod:savepoint-test">>, 1, undefined).

committed(Facts) -> quod_ct:committed_kb(Facts).
