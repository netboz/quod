-module(quod_proof_session_savepoint_tests).

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
               allowed, context(), empty_selection()),
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

savepoint_population_preserves_generation_test() ->
    Session = quod_proof_session:start(committed([]), #{}),
    try
        lists:foreach(
          fun(Id) ->
              ok = quod_proof_session:checkpoint_many(Session, [Id])
          end,
          lists:seq(1, 1025)),
        Generation = quod_proof_session:overlay_generation(Session),
        ?assertEqual(ok, quod_proof_session:checkpoint_many(Session, [additional])),
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
        %% Make two genuinely distinct distributed checkpoints. Purely local
        %% alternatives can share an as-yet unmaterialized foreign checkpoint.
        ok = quod_proof_context:materialize(
               selection(Lineage, [StaleBatch]), ActorB),
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

local_checkpoints_reuse_controller_authority_until_foreign_work_test() ->
    Handle = start_context(crypto:strong_rand_bytes(32)),
    SessionA = quod_proof_session:start(committed([]), #{}),
    SessionB = quod_proof_session:start(committed([]), #{}),
    PidB = spawn(fun wait/0),
    try
        ScopeA = register_local_scope(<<"a">>, 1, self(), SessionA),
        ScopeB = register_local_scope(<<"b">>, 2, PidB, SessionB),
        ActorA = actor(ScopeA), ActorB = actor(ScopeB),
        ok = quod_proof_context:register_invocation(ActorA, empty_selection()),
        Frame = opaque_id(),
        {ok, Lineage, _} = quod_proof_context:tx_request(ActorA, {activate, none, [Frame]}),
        ok = quod_proof_context:register_invocation(ActorB, selection(Lineage, [])),
        {ok, _} = quod_transaction_scope:with_invocation(
          ActorA, selection(Lineage, []), {origin, Handle}, fun() ->
            [{batch, First}] = Token = quod_transaction_scope:checkpoint_token(),
            MFA = {quod_proof_context, tx_request, 2},
            1 = erlang:trace_pattern(MFA, true, [call_count]),
            try
                lists:foreach(fun(_) ->
                    ?assertEqual(Token, quod_transaction_scope:checkpoint_token()),
                    ?assertEqual(ok, quod_transaction_scope:restore_token(Token))
                end, lists:seq(1, 3 * 1025)),
                ?assertEqual({call_count, 0}, erlang:trace_info(MFA, call_count))
            after erlang:trace_pattern(MFA, false, [call_count]) end,

            %% A published selection may materialize the former local token.
            _ = quod_transaction_scope:current_selection(committed([])),
            ok = quod_proof_context:materialize(selection(Lineage, [First]), ActorB),
            [{batch, Second}] = quod_transaction_scope:checkpoint_token(),
            ?assertNotEqual(First, Second),
            prove_write(SessionB, {after_checkpoint, removed}),
            ok = quod_transaction_scope:restore_token(Token),
            ?assertNot(has_assert({after_checkpoint, removed},
                                 quod_proof_session:local_changes(SessionB))),

            %% Reentrant work can materialize a suspended invocation's token.
            [{batch, BeforeReentry}] = quod_transaction_scope:checkpoint_token(),
            {ok, _} = quod_transaction_scope:with_invocation(
              ActorB, selection(Lineage, [BeforeReentry]), {origin, Handle}, fun() ->
                ok = quod_proof_context:materialize(
                       selection(Lineage, [BeforeReentry]), ActorB)
              end),
            [{batch, AfterReentry}] = quod_transaction_scope:checkpoint_token(),
            ?assertNotEqual(BeforeReentry, AfterReentry),
            ok
          end)
    after
        quod_proof_context:stop(fun(_Scope) -> ok end, fun(_Proxy) -> ok end),
        quod_proof_session:stop(SessionA), quod_proof_session:stop(SessionB),
        PidB ! stop
    end.

unmaterialized_batches_reuse_only_exact_actor_and_lineage_test() ->
    _ = start_context(crypto:strong_rand_bytes(32)),
    SessionA = quod_proof_session:start(committed([]), #{}),
    SessionB = quod_proof_session:start(committed([]), #{}),
    PidB = spawn(fun wait/0),
    try
        ScopeA = register_local_scope(<<"a">>, 1, self(), SessionA),
        ScopeB = register_local_scope(<<"b">>, 2, PidB, SessionB),
        ActorA = actor(ScopeA),
        ActorB = actor(ScopeB),
        ok = quod_proof_context:register_invocation(ActorA, empty_selection()),
        Frame = opaque_id(),
        {ok, Lineage, [{Frame, Tx, Lineage, _}]} =
            quod_proof_context:tx_request(ActorA, {activate, none, [Frame]}),
        ok = quod_proof_context:register_invocation(ActorB, selection(Lineage, [])),
        {ok, First} = quod_proof_context:tx_request(ActorA, {allocate, Lineage}),
        lists:foreach(fun(_) ->
            ?assertEqual({ok, First},
                quod_proof_context:tx_request(ActorA, {allocate, Lineage}))
        end, lists:seq(1, 3 * 1025)),
        ?assertEqual({error, not_allowed},
            quod_proof_context:tx_request(actor(ScopeA), {allocate, Lineage})),
        %% A cut can remove every live holder while the unused batch remains.
        %% Foreign work with an empty selection must not create its snapshot.
        ok = quod_proof_context:materialize(selection(Lineage, []), ActorB),
        prove_write(SessionB, {before_reuse, retained}),
        ?assertEqual({ok, First},
            quod_proof_context:tx_request(ActorA, {allocate, Lineage})),
        ok = quod_proof_context:materialize(selection(Lineage, [First]), ActorB),
        prove_write(SessionB, {after_reuse, removed}),
        ok = quod_proof_context:tx_request(ActorA, {restore, Lineage, [First]}),
        ?assert(has_assert({before_reuse, retained}, quod_proof_session:local_changes(SessionB))),
        ?assertNot(has_assert({after_reuse, removed}, quod_proof_session:local_changes(SessionB))),
        prove_write(SessionB, {first, retained}),
        {ok, Second} = quod_proof_context:tx_request(ActorA, {allocate, Lineage}),
        ?assertNotEqual(First, Second),
        ok = quod_proof_context:materialize(selection(Lineage, [Second]), ActorB),
        prove_write(SessionB, {second, removed}),
        ok = quod_proof_context:tx_request(ActorA, {restore, Lineage, [Second]}),
        ?assert(has_assert({first, retained}, quod_proof_session:local_changes(SessionB))),
        ?assertNot(has_assert({second, removed}, quod_proof_session:local_changes(SessionB))),
        {ok, Third} = quod_proof_context:tx_request(ActorA, {allocate, Lineage}),
        ?assertNotEqual(Second, Third),
        %% A reentrant invocation of the same ontology is a different actor.
        Reentrant = actor(ScopeA),
        ok = quod_proof_context:register_invocation(Reentrant, selection(Lineage, [])),
        {ok, ReentrantBatch} = quod_proof_context:tx_request(Reentrant, {allocate, Lineage}),
        ?assertNotEqual(Third, ReentrantBatch),
        quod_proof_context:unregister_invocation(Reentrant),
        ChildFrame = opaque_id(),
        {ok, ChildLineage, [{ChildFrame, ChildTx, ChildLineage, _}]} =
            quod_proof_context:tx_request(ActorA, {activate, Lineage, [ChildFrame]}),
        {ok, ChildBatch} = quod_proof_context:tx_request(ActorA, {allocate, ChildLineage}),
        {ok, Lineage} = quod_proof_context:tx_request(ActorA, {finish, ChildLineage, ChildTx}),
        {ok, ParentBatch} = quod_proof_context:tx_request(ActorA, {allocate, Lineage}),
        ?assertNotEqual(ChildBatch, ParentBatch),
        {ok, none} = quod_proof_context:tx_request(ActorA, {finish, Lineage, Tx}),
        ?assertEqual({error, not_allowed},
            quod_proof_context:tx_request(ActorA, {allocate, Lineage}))
    after
        quod_proof_context:stop(fun quod_scope_session:close/1, fun(_) -> ok end),
        quod_proof_session:stop(SessionA), quod_proof_session:stop(SessionB),
        PidB ! stop
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

controller_activates_many_owned_transaction_frames_test() ->
    _ = start_context(crypto:strong_rand_bytes(32)),
    Session = quod_proof_session:start(committed([]), #{}),
    try
        ScopeId = register_local_scope(<<"a">>, 1, self(), Session),
        Actor = actor(ScopeId),
        ok = quod_proof_context:register_invocation(
               Actor, empty_selection()),
        Frames = unique_ids(1025),
        {ok, Lineage, _} = quod_proof_context:tx_request(
                             Actor, {activate, none, Frames}),
        ?assertMatch({ok, _, _}, quod_proof_context:tx_request(
             Actor, {activate, Lineage, [opaque_id()]}))
    after
        quod_proof_context:stop(fun(_Scope) -> ok end,
                                fun(_Proxy) -> ok end),
        quod_proof_session:stop(Session)
    end.

controller_materializes_many_owned_batches_test() ->
    _ = start_context(crypto:strong_rand_bytes(32)),
    Session = quod_proof_session:start(committed([]), #{}),
    Foreign = quod_proof_session:start(committed([]), #{}),
    Pid = spawn(fun wait/0),
    try
        ScopeId = register_local_scope(<<"a">>, 1, self(), Session),
        Actor = actor(ScopeId),
        ok = quod_proof_context:register_invocation(
               Actor, empty_selection()),
        Frame = opaque_id(),
        {ok, Lineage, _} = quod_proof_context:tx_request(
                             Actor, {activate, none, [Frame]}),
        Target = actor(register_local_scope(<<"b">>, 2, Pid, Foreign)),
        ok = quod_proof_context:register_invocation(Target, selection(Lineage, [])),
        lists:foreach(
          fun(_) ->
              {ok, Batch} = quod_proof_context:tx_request(Actor, {allocate, Lineage}),
              ok = quod_proof_context:materialize(selection(Lineage, [Batch]), Target)
          end,
          lists:seq(2, 1025)),
        ?assertMatch({ok, _}, quod_proof_context:tx_request(Actor, {allocate, Lineage}))
    after
        quod_proof_context:stop(fun(_Scope) -> ok end,
                                fun(_Proxy) -> ok end),
        quod_proof_session:stop(Session), quod_proof_session:stop(Foreign),
        Pid ! stop
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
             {tx_selection, none, [opaque_id() | improper], ordinary})),
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
             {tx_selection, Lineage, [Baseline | improper], ordinary}, Actor)),
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
           Session, Invocation, Goal, allowed, context(), empty_selection()),
    ?assertMatch({solution, _}, quod_proof_session:next(Session, Invocation)).

empty_selection() -> quod_transaction_scope:empty_selection().

selection(Lineage, BatchIds) ->
    {tx_selection, Lineage, lists:usort(BatchIds), ordinary}.

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
               {local_scope, NewScopeId, Ns, Anchor, 1, Session}, 1}
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
