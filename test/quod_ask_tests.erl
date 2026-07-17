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
          ?_test(t_circular_ask(Ctx)),
          ?_test(t_permission_gate(Ctx)),
          ?_test(t_completion_marker(Ctx)),
          ?_test(t_foreign_write_rejected(Ctx)),
          ?_test(t_target_engine_stays_responsive(Ctx)),
          ?_test(t_answer_worker_failure_isolated(Ctx)),
          ?_test(t_target_crash_kills_answer(Ctx)),
          ?_test(t_answer_worker_limit(Ctx)),
          ?_test(t_absolute_ask_lifetime(Ctx)),
          ?_test(t_frozen_stream_view(Ctx)),
          ?_test(t_workers_are_reaped(Ctx))]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    {Pub, Seed} = quod_identity:generate(),
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_key, quod_identity:key_term({Pub, Seed})),
    Dir = filename:join("/tmp", "quod_ask_" ++
                       integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "placeholder")),
    PrivateFile = write_ontology(Dir, "private.pl",
        "can_read(secret(_), _Subject, _Ns).\n"
        "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
        "secret(42).\n"
        "hidden(denied).\n"),
    SlowFile = write_ontology(Dir, "slow.pl",
        "can_read(_Goal, _Subject, _Ns).\n"
        "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
        "loop :- loop.\n"
        "ping(ok).\n"),
    Namespaces = [
        start_ns(<<"animals">>, <<"ontologies/animals.pl">>, Dir),
        start_ns(<<"pets">>, <<"ontologies/pets.pl">>, Dir),
        start_ns(<<"private">>, list_to_binary(PrivateFile), Dir),
        start_ns(<<"slow">>, list_to_binary(SlowFile), Dir)
    ],
    [A, P, Private, Slow] = Namespaces,
    _ = prove_ready(A, {isa, dog, mammal}),
    _ = prove_ready(P, {instance_of, pet, my_dog}),
    _ = prove_ready(Private, {secret, 42}),
    _ = prove_ready(Slow, {ping, ok}),
    #{dir => Dir, namespaces => Namespaces, animals => A, pets => P,
      private => Private, slow => Slow}.

cleanup(#{dir := Dir, namespaces := Namespaces}) ->
    lists:foreach(fun stop_ns/1, Namespaces),
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
    ?assertEqual(fail, prove(P, {'::', animals, {diet, dog, grass}})).

t_self_ask(#{animals := A}) ->
    ?assertMatch({ok, [#{}], _}, prove(A, {'::', animals, {isa, dog, mammal}})).

t_loud_routing_errors(#{pets := P}) ->
    ?assertEqual({error, {unknown_ontology, <<"nope">>}},
                 prove(P, {'::', nope, {diet, dog, {'D'}}})),
    ?assertMatch({error, {bad_name, _}},
                 prove(P, {'::', {bad, a, name}, {diet, dog, {'D'}}})).

t_circular_ask(#{pets := P}) ->
    ?assertEqual({error, {circular_ask, <<"pets">>}},
                 prove(P, {'::', animals,
                           {'::', pets, {attribute, my_dog, name, {'N'}}}})).

t_permission_gate(#{pets := P}) ->
    ?assertMatch({ok, [#{'X' := 42}], _},
                 prove(P, {'::', private, {secret, {'X'}}})),
    ?assertEqual({error, not_allowed},
                 prove(P, {'::', private, {hidden, {'X'}}})).

%% Completion is deliberately minimal: subscriptions are not implemented yet, so
%% version/read-set material must not allocate or cross the wire as dead state.
t_completion_marker(#{animals := A, pets := P}) ->
    Engine = quod_reg:where({quod_prolog, A}),
    {ok, Stream} = gen_server:call(Engine,
        {ask_open, {diet, cat, {'D'}}, [P], self()}),
    Stream ! {next, self()},
    receive {ask_solution, Stream, 1, {diet, cat, fish}} -> ok after 1000 -> ?assert(false) end,
    Stream ! {next, self()},
    receive
        {ask_complete, Stream, 2} -> ok
    after 1000 -> ?assert(false)
    end.

t_foreign_write_rejected(#{animals := A, pets := P}) ->
    ?assertEqual({error, foreign_write_unsupported},
                 prove(P, {'::', animals, {assertz, {stolen, fact}}})),
    ?assertEqual(fail, prove(A, {stolen, fact})).

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
    receive {ask_complete, Stream, 3} -> ok after 1000 -> ?assert(false) end.

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
