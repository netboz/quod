-module(quod_ask_tests).
-include_lib("eunit/include/eunit.hrl").

-define(WAIT_RETRIES, 200).

decode_guards_test() ->
    AskId = <<0:128>>,
    AnswerCh = term_to_binary({quod_ask_answer, AskId}, [deterministic]),
    {ok, WireGoal} = quod_wire_term:encode({diet, dog, {'D'}}),
    Open = fun(Chain, Wire) ->
                   term_to_binary({quod_ask_open, AskId, Wire, Chain, AnswerCh},
                                  [deterministic])
           end,
    ?assertMatch({ok, AskId, _, [<<"pets">>], AnswerCh},
                 quod_ask:decode_open(Open([<<"pets">>], WireGoal))),
    ?assertEqual(error, quod_ask:decode_open(Open([], WireGoal))),
    ?assertEqual(error, quod_ask:decode_open(
                          Open(lists:duplicate(9, <<"n">>), WireGoal))),
    ?assertEqual(error, quod_ask:decode_open(Open([not_binary], WireGoal))),
    ?assertEqual(error, quod_ask:decode_open(Open([<<"pets">>], malformed))),
    Bomb = term_to_binary(
             {quod_ask_open, AskId, WireGoal, [<<"pets">>], AnswerCh},
             [{compressed, 9}]),
    ?assertMatch(<<131, 80, _/binary>>, Bomb),
    ?assertEqual(error, quod_ask:decode_open(Bomb)),
    ?assertEqual(error, quod_ask:decode_next(
                          term_to_binary({quod_ask_next, <<0:120>>}))),
    ?assertEqual(error, quod_ask:decode_cancel(
                          term_to_binary({quod_ask_cancel, <<0:136>>}))).

completion_reason_validation_test() ->
    AskId = <<0:128>>,
    {ok, ValidWire} = quod_wire_term:encode([{blocked, bob}]),
    ?assertEqual(
       {complete, [{blocked, bob}]},
       quod_ask:test_remote_answer(
         {quod_ask_answer, AskId, 1, {complete, ValidWire}}, AskId, 1)),
    Oversized = binary:copy(<<"x">>, 4097),
    {ok, OversizedWire} = quod_wire_term:encode([Oversized]),
    ?assertEqual(
       error,
       quod_ask:test_remote_answer(
         {quod_ask_answer, AskId, 1, {complete, OversizedWire}}, AskId, 1)),
    ?assertEqual(
       error,
       quod_ask:test_remote_answer(
         {quod_ask_answer, AskId, 1, {complete, malformed}}, AskId, 1)).

write_rejection_precedes_answer_limit_test() ->
    {ok, Erl} = erlog:new(erlog_db_dict, null),
    Scope0 = quod_proof_scope:open(
               {assertz, {staged, answer}}, element(3, Erl), #{}),
    try
        {solution, _Solution, Scope1} = quod_proof_scope:next(Scope0),
        ?assertEqual(
           {error, foreign_write_unsupported},
           quod_ask:test_solution_disposition(Scope1, at_limit))
    after
        quod_proof_scope:close(Scope0)
    end.

nested_source_binding_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Anchor = crypto:strong_rand_bytes(32),
    Parent = self(),
    Registered = spawn(fun() -> forward_messages(Parent) end),
    Stranger = spawn(fun() -> forward_messages(Parent) end),
    _Context = quod_proof_context:start(ProofId, false),
    try
        {ok, registered_scope} = quod_proof_context:get_or_open_scope(
                                   {<<"quod:nested-source-test">>, Anchor},
                                   fun() -> {ok, Registered, registered_scope} end),
        WrongProof = crypto:strong_rand_bytes(32),
        WrongRef = make_ref(),
        ok = quod_ask:test_serve_nested(
               {proof_nested_open, WrongProof, Registered, WrongRef,
                <<"quod:any">>, true, [<<"quod:caller">>]}),
        ?assertEqual(
           {proof_nested_reply, WrongProof, WrongRef, {error, not_allowed}},
           receive_forwarded(Registered)),
        StrangerRef = make_ref(),
        ok = quod_ask:test_serve_nested(
               {proof_nested_open, ProofId, Stranger, StrangerRef,
                <<"quod:any">>, true, [<<"quod:caller">>]}),
        ?assertEqual(
           {proof_nested_reply, ProofId, StrangerRef, {error, not_allowed}},
           receive_forwarded(Stranger))
    after
        quod_proof_context:stop(fun(_Scope) -> ok end,
                                fun(_Proxy) -> ok end),
        exit(Registered, kill),
        exit(Stranger, kill)
    end.

ask_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(Ctx) ->
         [?_test(t_single_answer(Ctx)),
          ?_test(t_backtracking_all_answers(Ctx)),
          ?_test(t_default_link_following(Ctx)),
          ?_test(t_multi_position_follow_dedup(Ctx)),
          ?_test(t_repeated_follow_queries_are_independent(Ctx)),
          ?_test(t_grounded_ask(Ctx)),
          ?_test(t_self_ask(Ctx)),
          ?_test(t_loud_routing_errors(Ctx)),
          ?_test(t_recursive_selection(Ctx)),
          ?_test(t_three_scope_chain(Ctx)),
          ?_test(t_failed_foreign_branch_retains_state(Ctx)),
          ?_test(t_reentrant_scope_reuse(Ctx)),
          ?_test(t_origin_scope_reentry_commits_write(Ctx)),
          ?_test(t_nested_failure_reasons(Ctx)),
          ?_test(t_read_only_tree_rejects_first_write(Ctx)),
          ?_test(t_scope_session_binding(Ctx)),
          ?_test(t_stateless_scope_error_keeps_published_revision(Ctx)),
          ?_test(t_scope_owner_death_reaps_session(Ctx)),
          ?_test(t_scope_worker_crash_is_broken_stream(Ctx)),
          ?_test(t_permission_gate(Ctx)),
          ?_test(t_failure_reasons_cross_local_ask(Ctx)),
          ?_test(t_completion_marker(Ctx)),
          ?_test(t_foreign_write_rejected(Ctx)),
          ?_test(t_target_engine_stays_responsive(Ctx)),
          ?_test(t_answer_worker_failure_isolated(Ctx)),
          ?_test(t_target_crash_kills_answer(Ctx)),
          ?_test(t_answer_worker_limit(Ctx)),
          ?_test(t_absolute_ask_lifetime(Ctx)),
          ?_test(t_frozen_stream_view(Ctx)),
          ?_test(t_remote_return_router_multiplexes(Ctx)),
          ?_test(t_workers_are_reaped(Ctx))]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    {Pub, Seed} = quod_identity:generate(),
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_key, quod_identity:key_term({Pub, Seed})),
    {ok, Router} = quod_ask_router:start_link(),
    Dir = filename:join("/tmp", "quod_ask_" ++
                       integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "placeholder")),
    PrivateFile = write_ontology(Dir, "private.pl",
        "can_read(secret(_), _Subject, _Ns).\n"
        "can_read(blocked(_), _Subject, _Ns).\n"
        "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
        "blocked(X) :- fail_with_reason(impossible_to_link(X)).\n"
        "secret(42).\n"
        "hidden(denied).\n"),
    SlowFile = write_ontology(Dir, "slow.pl",
        "can_read(_Goal, _Subject, _Ns).\n"
        "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
        "loop :- loop.\n"
        "ping(ok).\n"),
    ChainBFile = write_ontology(Dir, "chain_b.pl",
        "can_read(_Goal, _Subject, _Ns).\n"
        "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
        "via_c(X) :- chain_c::leaf(X).\n"
        "stage_and_fail :- assertz(shared_mark), fail.\n"
        "shared_mark_visible :- shared_mark.\n"
        "via_c_back(X) :- assertz(reentry_mark), chain_c::back_to_b(X).\n"
        "reentry_visible(ok) :- reentry_mark.\n"
        "via_origin_write :- pets::assertz(origin_callback_write).\n"
        "via_c_failure :- chain_c::blocked.\n"),
    ChainCFile = write_ontology(Dir, "chain_c.pl",
        "can_read(_Goal, _Subject, _Ns).\n"
        "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
        "leaf(ok).\n"
        "back_to_b(X) :- chain_b::reentry_visible(X).\n"
        "blocked :- fail_with_reason(c_blocked).\n"),
    Namespaces = [
        start_ns(<<"animals">>, <<"ontologies/animals.pl">>, Dir),
        start_ns(<<"pets">>, <<"ontologies/pets.pl">>, Dir),
        start_ns(<<"private">>, list_to_binary(PrivateFile), Dir),
        start_ns(<<"slow">>, list_to_binary(SlowFile), Dir),
        start_ns(<<"chain_b">>, list_to_binary(ChainBFile), Dir),
        start_ns(<<"chain_c">>, list_to_binary(ChainCFile), Dir)
    ],
    [A, P, Private, Slow, ChainB, ChainC] = Namespaces,
    _ = prove_ready(A, {isa, dog, mammal}),
    _ = prove_ready(P, {instance_of, pet, my_dog}),
    _ = prove_ready(Private, {secret, 42}),
    _ = prove_ready(Slow, {ping, ok}),
    #{dir => Dir, router => Router, namespaces => Namespaces, animals => A, pets => P,
      private => Private, slow => Slow, chain_b => ChainB, chain_c => ChainC}.

cleanup(#{dir := Dir, router := Router, namespaces := Namespaces}) ->
    lists:foreach(fun stop_ns/1, Namespaces),
    _ = catch gen_server:stop(Router),
    application:unset_env(quod, node_pubkey),
    application:unset_env(quod, identity_key),
    _ = file:del_dir_r(Dir),
    ok.

t_single_answer(#{pets := P}) ->
    ?assertMatch({ok, [#{'D' := fish}], _},
                 prove(P, {'::', animals, {diet, cat, {'D'}}})).

t_backtracking_all_answers(#{pets := P}) ->
    ?assertMatch({ok, [#{'L' := [kibble, meat]}], _},
                 prove(P, {findall, {'D'},
                           {'::', animals, {diet, dog, {'D'}}}, {'L'}})).

t_default_link_following(#{animals := A}) ->
    ?assertMatch({ok, [#{'D' := kibble}], _},
                 prove(A, {diet, {':', animals, dog}, {'D'}})),
    ?assertMatch({ok, [#{'L' := [kibble, meat]}], _},
                 prove(A, {findall, {'D'},
                           {diet, {':', animals, dog}, {'D'}}, {'L'}})).

t_multi_position_follow_dedup(#{pets := P}) ->
    Goal = {isa, {':', animals, dog}, {':', animals, mammal}},
    ?assertMatch({ok, [#{'L' := [ok]}], _},
                 prove(P, {findall, ok, Goal, {'L'}})).

t_repeated_follow_queries_are_independent(#{pets := P}) ->
    First = {findall, {'D1'}, {diet, {':', animals, dog}, {'D1'}}, {'L1'}},
    Second = {findall, {'D2'}, {diet, {':', animals, dog}, {'D2'}}, {'L2'}},
    ?assertMatch({ok, [#{'L1' := [kibble, meat],
                         'L2' := [kibble, meat]}], _},
                 prove(P, {',', First, Second})).

t_grounded_ask(#{pets := P}) ->
    ?assertMatch({ok, [#{}], _}, prove(P, {'::', animals, {diet, dog, meat}})),
    ?assertMatch({fail, [_ | _]},
                 prove(P, {'::', animals, {diet, dog, grass}})).

t_self_ask(#{animals := A}) ->
    ?assertMatch({ok, [#{}], _}, prove(A, {'::', animals, {isa, dog, mammal}})).

t_loud_routing_errors(#{pets := P}) ->
    ?assertEqual({error, {unknown_ontology, <<"nope">>}},
                 prove(P, {'::', nope, {diet, dog, {'D'}}})),
    ?assertMatch({error, {bad_name, _}},
                 prove(P, {'::', {bad, a, name}, {diet, dog, {'D'}}})).

t_recursive_selection(#{pets := P}) ->
    ?assertMatch({ok, [#{'N' := rex}], _},
                 prove(P, {'::', animals,
                           {'::', pets, {attribute, my_dog, name, {'N'}}}})).

t_three_scope_chain(#{pets := P}) ->
    ?assertMatch({ok, [#{'X' := ok}], _},
                 prove(P, {'::', chain_b, {via_c, {'X'}}})).

%% A failed invocation's writes remain in B's shared proof scope, exactly as
%% ordinary local Prolog backtracking preserves database writes.
t_failed_foreign_branch_retains_state(#{pets := P}) ->
    Goal = {';', {'::', chain_b, stage_and_fail},
                 {'::', chain_b, shared_mark_visible}},
    ?assertEqual({error, foreign_write_unsupported}, prove(P, Goal)).

%% C calls back into the already-suspended B scope. The B write must be visible
%% there; opening a second B overlay would make the proof fail instead.
t_reentrant_scope_reuse(#{pets := P}) ->
    ?assertEqual({error, foreign_write_unsupported},
                 prove(P, {'::', chain_b, {via_c_back, ok}})).

%% B selects the already-running origin scope A. The write belongs to A's
%% ordinary transaction diff; no second A overlay is opened.
t_origin_scope_reentry_commits_write(#{pets := P}) ->
    ?assertMatch({ok, [#{}], _},
                 prove(P, {'::', chain_b, via_origin_write})),
    ?assertMatch({ok, [#{}], _}, prove(P, origin_callback_write)).

t_nested_failure_reasons(#{pets := P}) ->
    {fail, Reasons} = prove(P, {'::', chain_b, via_c_failure}),
    ?assert(lists:member(c_blocked, Reasons)).

t_read_only_tree_rejects_first_write(#{animals := A, pets := P}) ->
    LocalMarker = {read_only_local_write, blocked},
    ?assertEqual(
       {error, read_only},
       quod_prolog:prove_ro(P, {assertz, LocalMarker}, P)),
    ?assertMatch({fail, [_ | _]}, prove(P, LocalMarker)),
    ForeignMarker = {read_only_foreign_write, blocked},
    ?assertEqual(
       {error, read_only},
       quod_prolog:prove_ro(P, {'::', animals, {assertz, ForeignMarker}}, P)),
    ?assertMatch({fail, [_ | _]}, prove(A, ForeignMarker)).

t_scope_session_binding(#{animals := A}) ->
    Engine = quod_reg:where({quod_prolog, A}),
    Anchor = quod_simplex:genesis_hash(A),
    ProofId = crypto:strong_rand_bytes(32),
    {ok, Handle} = gen_server:call(
                     Engine, {scope_open, ProofId, Anchor, false}),
    try
        {quod_scope_session, ScopePid, ProofId, SessionRef, A, Anchor} = Handle,
        InvocationId = make_ref(),
        Goal = {diet, cat, {'D'}},
        Chain = [<<"pets">>],
        ScopePid ! {scope_invoke_open, self(), <<0:256>>, SessionRef,
                    make_ref(), InvocationId, Goal, Chain},
        assert_no_scope_reply(ScopePid, ProofId, SessionRef),
        ScopePid ! {scope_invoke_open, self(), ProofId, make_ref(),
                    make_ref(), InvocationId, Goal, Chain},
        assert_no_scope_reply(ScopePid, ProofId, SessionRef),
        Stranger = spawn(fun() -> ok end),
        ScopePid ! {scope_invoke_open, Stranger, ProofId, SessionRef,
                    make_ref(), InvocationId, Goal, Chain},
        assert_no_scope_reply(ScopePid, ProofId, SessionRef),
        OpenRef = make_ref(),
        ScopePid ! {scope_invoke_open, self(), ProofId, SessionRef,
                    OpenRef, InvocationId, Goal, Chain},
        assert_scope_reply(Handle, OpenRef, {opened, InvocationId}),
        WrongSeqRef = make_ref(),
        ok = quod_scope_session:next(Handle, WrongSeqRef, InvocationId, 2),
        ?assertEqual({error, broken_stream, false},
                     receive_scope_reply(Handle, WrongSeqRef)),
        NextRef = make_ref(),
        ok = quod_scope_session:next(Handle, NextRef, InvocationId, 1),
        ?assertMatch({solution, 1, {diet, cat, fish}, false},
                     receive_scope_reply(Handle, NextRef)),
        ok = quod_scope_session:cancel(Handle, InvocationId),
        ?assertEqual(
           {ok, Handle},
           gen_server:call(Engine, {scope_open, ProofId, Anchor, false})),
        ?assertEqual(
           {error, {anchor_conflict, A}},
           gen_server:call(Engine, {scope_open, ProofId, <<0:256>>, false})),
        ?assertEqual(
           {error, scope_mode_conflict},
           gen_server:call(Engine, {scope_open, ProofId, Anchor, true})),
        ?assertEqual(
           {error, {anchor_conflict, A}},
           gen_server:call(
             Engine, {scope_open, crypto:strong_rand_bytes(32),
                      <<0:256>>, false}))
    after
        ok = quod_scope_session:close(Handle),
        ok = wait_workers(A, 0, ?WAIT_RETRIES)
    end.

%% The scope publishes its write before asking the origin to open the nested
%% target. A state-less nested error must not rewind that published revision.
t_stateless_scope_error_keeps_published_revision(
  #{pets := P, chain_b := ChainB}) ->
    Engine = quod_reg:where({quod_prolog, ChainB}),
    Anchor = quod_simplex:genesis_hash(ChainB),
    ProofId = crypto:strong_rand_bytes(32),
    {ok, Handle} = gen_server:call(
                     Engine, {scope_open, ProofId, Anchor, false}),
    try
        InvocationId = make_ref(),
        OpenRef = make_ref(),
        Goal = {',', {assertz, {published_before_error, retained}},
                     {'::', chain_c, {leaf, ok}}},
        ok = quod_scope_session:open(
               Handle, OpenRef, InvocationId, Goal, [P]),
        assert_scope_reply(Handle, OpenRef, {opened, InvocationId}),
        NextRef = make_ref(),
        ok = quod_scope_session:next(Handle, NextRef, InvocationId, 1),
        ScopePid = quod_scope_session:pid(Handle),
        receive
            {proof_nested_open, ProofId, ScopePid, NestedRef,
             <<"chain_c">>, {leaf, ok}, _Chain} ->
                ScopePid ! {proof_nested_reply, ProofId, NestedRef,
                            {error, forced_scope_error}}
        after 1000 ->
            ?assert(false)
        end,
        ?assertEqual(
           {error, forced_scope_error, true},
           receive_scope_reply(Handle, NextRef))
    after
        ok = quod_scope_session:close(Handle),
        ok = wait_workers(ChainB, 0, ?WAIT_RETRIES)
    end.

t_scope_owner_death_reaps_session(#{animals := A}) ->
    Parent = self(),
    Engine = quod_reg:where({quod_prolog, A}),
    Anchor = quod_simplex:genesis_hash(A),
    Owner = spawn(fun() ->
        Result = gen_server:call(
                   Engine, {scope_open, crypto:strong_rand_bytes(32),
                            Anchor, false}),
        Parent ! {owner_scope, self(), Result},
        receive stop -> ok end
    end),
    {ok, Handle} = receive
                       {owner_scope, Owner, Result} -> Result
                   after 1000 -> error(scope_open_timeout)
                   end,
    ScopePid = quod_scope_session:pid(Handle),
    ScopeMRef = monitor(process, ScopePid),
    exit(Owner, kill),
    receive
        {'DOWN', ScopeMRef, process, ScopePid, _Reason} -> ok
    after 1000 -> ?assert(false)
    end,
    ?assertEqual(ok, wait_workers(A, 0, ?WAIT_RETRIES)).

t_scope_worker_crash_is_broken_stream(#{pets := P, slow := Slow}) ->
    Engine = quod_reg:where({quod_prolog, Slow}),
    Anchor = quod_simplex:genesis_hash(Slow),
    ProofId = crypto:strong_rand_bytes(32),
    {ok, Handle} = gen_server:call(
                     Engine, {scope_open, ProofId, Anchor, false}),
    InvocationId = make_ref(),
    OpenRef = make_ref(),
    ok = quod_scope_session:open(
           Handle, OpenRef, InvocationId, loop, [P]),
    assert_scope_reply(Handle, OpenRef, {opened, InvocationId}),
    NextRef = make_ref(),
    ok = quod_scope_session:next(Handle, NextRef, InvocationId, 1),
    exit(quod_scope_session:pid(Handle), kill),
    ?assertEqual(
       {error, broken_stream},
       quod_ask:test_await_scope_reply(Handle, NextRef)),
    ?assertEqual(ok, wait_workers(Slow, 0, ?WAIT_RETRIES)),
    ?assertMatch({ok, [#{}], _}, prove(Slow, {ping, ok})).

assert_scope_reply(
  Handle,
  RequestRef, Expected) ->
    ?assertEqual(Expected, receive_scope_reply(Handle, RequestRef)).

assert_no_scope_reply(Pid, ProofId, SessionRef) ->
    receive
        {scope_reply, Pid, ProofId, SessionRef, _RequestRef, _Reply} ->
            ?assert(false)
    after 20 -> ok
    end.

receive_scope_reply(
  {quod_scope_session, Pid, ProofId, SessionRef, _Ns, _Anchor}, RequestRef) ->
    receive
        {scope_reply, Pid, ProofId, SessionRef, RequestRef, Reply} -> Reply
    after 1000 -> error(scope_reply_timeout)
    end.

forward_messages(Parent) ->
    receive
        Message ->
            Parent ! {forwarded, self(), Message},
            forward_messages(Parent)
    end.

receive_forwarded(Pid) ->
    receive
        {forwarded, Pid, Message} -> Message
    after 1000 ->
        error(nested_reply_timeout)
    end.

t_permission_gate(#{pets := P}) ->
    ?assertMatch({ok, [#{'X' := 42}], _},
                 prove(P, {'::', private, {secret, {'X'}}})),
    ?assertEqual({error, not_allowed},
                 prove(P, {'::', private, {hidden, {'X'}}})).

t_failure_reasons_cross_local_ask(#{pets := P}) ->
    Remote = {'::', private, {blocked, bob}},
    Recover = {';', Remote,
               {get_fail_reasons,
                [{'Outer'}, {blocked, bob}, {impossible_to_link, bob}]}},
    ?assertMatch(
       {ok, [#{'Outer' := Remote}], _},
       prove(P, Recover)).

%% Completion carries only the bounded diagnostic stack in addition to sequencing;
%% subscriptions still allocate and send no version/read-set state.
t_completion_marker(#{animals := A, pets := P}) ->
    Engine = quod_reg:where({quod_prolog, A}),
    {ok, Stream} = gen_server:call(Engine,
        {ask_open, {diet, cat, {'D'}}, [P], self()}),
    Stream ! {next, self()},
    receive {ask_solution, Stream, 1, {diet, cat, fish}} -> ok after 1000 -> ?assert(false) end,
    Stream ! {next, self()},
    receive
        {ask_complete, Stream, 2, Reasons} when is_list(Reasons) -> ok
    after 1000 -> ?assert(false)
    end.

t_foreign_write_rejected(#{animals := A, pets := P}) ->
    ?assertEqual({error, foreign_write_unsupported},
                 prove(P, {'::', animals, {assertz, {stolen, fact}}})),
    ?assertMatch({fail, [_ | _]}, prove(A, {stolen, fact})).

%% A target answer can be stuck deriving its first solution without blocking the
%% ontology engine from serving an unrelated local proof.
t_target_engine_stays_responsive(#{slow := Slow, pets := P}) ->
    Parent = self(),
    Asker = spawn(fun() ->
        Engine = quod_reg:where({quod_prolog, Slow}),
        {ok, Stream} = gen_server:call(Engine, {ask_open, loop, [P], self()}),
        Parent ! {ask_started, self()},
        Stream ! {next, self()},
        receive stop -> ok end
    end),
    receive {ask_started, Asker} -> ok after 1000 -> ?assert(false) end,
    timer:sleep(20),
    Started = erlang:monotonic_time(millisecond),
    ?assertMatch({ok, [#{}], _}, prove(Slow, {ping, ok})),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000),
    exit(Asker, kill),
    ?assertEqual(ok, wait_workers(Slow, 0, ?WAIT_RETRIES)).

t_answer_worker_failure_isolated(#{slow := Slow, pets := P}) ->
    Engine = quod_reg:where({quod_prolog, Slow}),
    {ok, Stream} = gen_server:call(Engine, {ask_open, loop, [P], self()}),
    exit(Stream, kill),
    ?assertEqual(ok, wait_workers(Slow, 0, ?WAIT_RETRIES)),
    ?assertEqual(Engine, quod_reg:where({quod_prolog, Slow})),
    ?assertMatch({ok, [#{}], _}, prove(Slow, {ping, ok})).

t_target_crash_kills_answer(#{slow := Slow, pets := P}) ->
    Engine = quod_reg:where({quod_prolog, Slow}),
    {ok, Stream} = gen_server:call(Engine, {ask_open, loop, [P], self()}),
    StreamRef = monitor(process, Stream),
    Stream ! {next, self()},
    exit(Engine, kill),
    receive
        {'DOWN', StreamRef, process, Stream, _} -> ok
    after 1000 -> ?assert(false)
    end,
    ?assertMatch({ok, [#{}], _}, prove_ready(Slow, {ping, ok})).

t_answer_worker_limit(#{animals := A, pets := P}) ->
    Engine = quod_reg:where({quod_prolog, A}),
    Streams = [begin
                   {ok, Stream} = gen_server:call(
                       Engine, {ask_open, {diet, cat, {'D'}}, [P], self()}),
                   Stream
               end || _ <- lists:seq(1, 64)],
    ?assertEqual({error, busy}, gen_server:call(
        Engine, {ask_open, {diet, cat, {'D'}}, [P], self()})),
    lists:foreach(fun(Stream) -> gen_server:cast(Engine, {ask_cancel, Stream}) end, Streams),
    ?assertEqual(ok, wait_workers(A, 0, ?WAIT_RETRIES)).

t_absolute_ask_lifetime(_Ctx) ->
    Ns = <<"ask-timeout:", (integer_to_binary(
                              erlang:unique_integer([positive])))/binary>>,
    {ok, Engine} = quod_prolog:start_link(
                     Ns, #{node_id => {"127.0.0.1", 5000},
                           ask_timeout_ms => 80,
                           ask_step_timeout_ms => 1000}),
    try
        ok = quod_prolog:mark_ready(Ns),
        {ok, Stream} = gen_server:call(
                         Engine, {ask_open, repeat, [<<"caller">>], self()}),
        MRef = monitor(process, Stream),
        ?assertEqual(ok, pull_until_down(Stream, MRef, 30)),
        ?assertEqual(ok, wait_workers(Ns, 0, ?WAIT_RETRIES))
    after
        case is_process_alive(Engine) of
            true -> gen_server:stop(Engine);
            false -> ok
        end
    end.

pull_until_down(_Stream, _MRef, 0) -> timeout;
pull_until_down(Stream, MRef, Retries) ->
    Stream ! {next, self()},
    receive
        {ask_solution, Stream, _Seq, repeat} ->
            timer:sleep(10),
            pull_until_down(Stream, MRef, Retries - 1);
        {'DOWN', MRef, process, Stream, _Reason} ->
            ok
    after 100 ->
        case is_process_alive(Stream) of
            true -> pull_until_down(Stream, MRef, Retries - 1);
            false -> ok
        end
    end.

%% The answer worker keeps the target state captured at open. A commit between
%% streamed answers must not appear halfway through the stream.
t_frozen_stream_view(#{animals := A, pets := P}) ->
    Engine = quod_reg:where({quod_prolog, A}),
    {ok, Stream} = gen_server:call(Engine,
        {ask_open, {diet, dog, {'D'}}, [P], self()}),
    Stream ! {next, self()},
    receive {ask_solution, Stream, 1, {diet, dog, kibble}} -> ok after 1000 -> ?assert(false) end,
    ?assertMatch({ok, [_], _}, prove(A, {assertz, {diet, dog, tofu}})),
    Stream ! {next, self()},
    receive {ask_solution, Stream, 2, {diet, dog, meat}} -> ok after 1000 -> ?assert(false) end,
    Stream ! {next, self()},
    receive
        {ask_complete, Stream, 3, Reasons} when is_list(Reasons) -> ok
    after 1000 -> ?assert(false)
    end.

%% Remote replies share one node-return channel.  Two independent ask ids on
%% the same authenticated link must reach only their registered proof workers.
t_remote_return_router_multiplexes(_Ctx) ->
    {TargetKey, _} = quod_identity:generate(),
    Ask1 = <<1:128>>,
    Ask2 = <<2:128>>,
    {ok, Channel} = quod_ask_router:register(Ask1, TargetKey),
    {ok, Channel} = quod_ask_router:register(Ask2, TargetKey),
    {ok, EmptyReasons} = quod_wire_term:encode([]),
    Complete = {complete, EmptyReasons},
    Bad = term_to_binary({quod_ask_answer, Ask1, 1, Complete}, [deterministic]),
    quod_reg:publish(
      {channel, Channel},
      {quod_message, {{<<0:256>>, {"127.0.0.1", 5000}}, self()}, Channel, Bad}),
    receive
        {quod_ask_answer, Ask1, _} -> ?assert(false)
    after 20 -> ok
    end,
    Reply1 = term_to_binary({quod_ask_answer, Ask1, 1, Complete}, [deterministic]),
    Reply2 = term_to_binary({quod_ask_answer, Ask2, 1, Complete}, [deterministic]),
    quod_reg:publish(
      {channel, Channel},
      {quod_message, {{TargetKey, {"127.0.0.1", 5000}}, self()}, Channel, Reply1}),
    quod_reg:publish(
      {channel, Channel},
      {quod_message, {{TargetKey, {"127.0.0.1", 5000}}, self()}, Channel, Reply2}),
    receive
        {quod_ask_answer, Ask1, {quod_ask_answer, Ask1, 1, Complete}} -> ok
    after 1000 -> ?assert(false)
    end,
    receive
        {quod_ask_answer, Ask2, {quod_ask_answer, Ask2, 1, Complete}} -> ok
    after 1000 -> ?assert(false)
    end,
    ok = quod_ask_router:unregister(Ask1),
    ok = quod_ask_router:unregister(Ask2).

t_workers_are_reaped(#{namespaces := Namespaces}) ->
    lists:foreach(
      fun(Ns) ->
          ?assertEqual(ok, wait_workers(Ns, 0, ?WAIT_RETRIES)),
          Stats = quod_prolog:stats(Ns),
          ?assertEqual(0, maps:get(proof_workers, Stats)),
          ?assertEqual(0, maps:get(ask_workers, Stats))
      end, Namespaces).

write_ontology(Dir, Name, Contents) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path, Contents),
    Path.

start_ns(Ns, File, Dir) ->
    {Ns, Cfg} = quod_app:build_ns_config(#{namespace => Ns, mode => create,
                    genesis_file => File, data_dir => list_to_binary(Dir), seeds => []}),
    {ok, Pid} = quod_ns:start_link(Ns, Cfg),
    unlink(Pid),
    Ns.

stop_ns(Ns) ->
    case quod_reg:where({quod_ns, Ns}) of
        undefined -> ok;
        Pid ->
            Ref = monitor(process, Pid),
            exit(Pid, shutdown),
            receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ok end
    end.

prove(Ns, Goal) -> quod_prolog:prove(Ns, Goal, Ns).

prove_ready(Ns, Goal) -> prove_ready(Ns, Goal, 300).
prove_ready(_Ns, _Goal, 0) -> {error, timeout};
prove_ready(Ns, Goal, N) ->
    case prove(Ns, Goal) of
        {error, rebuilding} -> timer:sleep(10), prove_ready(Ns, Goal, N - 1);
        {error, no_such_namespace} -> timer:sleep(10), prove_ready(Ns, Goal, N - 1);
        Result -> Result
    end.

wait_workers(_Ns, _Expected, 0) -> {error, timeout};
wait_workers(Ns, Expected, N) ->
    case maps:get(ask_workers, quod_prolog:stats(Ns), undefined) of
        Expected -> ok;
        _ -> timer:sleep(10), wait_workers(Ns, Expected, N - 1)
    end.
