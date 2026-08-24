-module(quod_client_goal_target_tests).
-moduledoc false.

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(NETWORK, <<16#51:256>>).
-define(ANCHOR, <<16#52:256>>).
-define(FORWARDER, <<16#53:256>>).

forwarded_target_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(Ctx) ->
         [?_test(forwarded_request_uses_the_existing_target_executor(Ctx)),
          ?_test(engine_capacity_is_preserved_as_a_preexecution_refusal(Ctx)),
          ?_test(target_reverifies_signature_deadline_and_exact_anchor(Ctx))]
     end}.

forwarded_request_uses_the_existing_target_executor(
  #{namespace := Ns, key_pair := KeyPair, link := Link}) ->
    Fixture = signed_fixture(Ns, KeyPair, quod_time:now_ms() + 30000),
    {ok, {Evidence, Goal, Principal,
          {forwarder, ?FORWARDER, Link, SigningKey}}} =
        quod_client_goal_target:prepare_forwarded(
          maps:get(request_bytes, Fixture), maps:get(signature, Fixture),
          ?FORWARDER, Link, none),
    ?assertMatch({agent, _}, Principal),
    ?assertMatch(
       {ok, Evidence, {normalized, {answers, 1, [_]}}},
       quod_client_goal_target:execute(
         Evidence, Goal, Principal,
         {forwarder, ?FORWARDER, Link, SigningKey}, none)).

engine_capacity_is_preserved_as_a_preexecution_refusal(
  #{namespace := Ns, key_pair := KeyPair, link := Link}) ->
    Deadline = quod_time:now_ms() + 30000,
    Loop = signed_fixture(Ns, KeyPair, Deadline, <<"loop.">>),
    {ok, {LoopEvidence, LoopGoal, LoopPrincipal, LoopOwner}} =
        quod_client_goal_target:prepare_forwarded(
          maps:get(request_bytes, Loop), maps:get(signature, Loop),
          ?FORWARDER, Link, none),
    Caller = spawn(
               fun() ->
                   quod_client_goal_target:execute(
                     LoopEvidence, LoopGoal, LoopPrincipal, LoopOwner, none)
               end),
    try
        ok = wait_proof_workers(Ns, 1, 200),
        Execute = signed_fixture(
                    Ns, KeyPair, Deadline, execute, <<"lookup(X).">>),
        Parent = self(),
        ResponseLink = spawn(fun() -> response_link(Parent) end),
        {ok, Router} = quod_client_goal_router:test_start_link(
                         fun(_Peer, _Endpoint, _Channel) -> make_ref() end),
        try
            RequestId = <<16#58:128>>,
            Request = {submit, RequestId,
                       maps:get(request_bytes, Execute),
                       maps:get(signature, Execute), none, []},
            {ok, Frame} = quod_client_goal_endpoint:encode_request(Request),
            Router ! {quod_message, {?FORWARDER, ResponseLink},
                      quod_client_goal_endpoint:channel(), Frame},
            receive
                {target_response, ResponseLink, ResponseFrame} ->
                    ?assertEqual(
                       {ok, {refused, RequestId, busy}},
                       quod_client_goal_endpoint:decode_response(ResponseFrame))
            after 2000 ->
                error(target_busy_refusal_missing)
            end
        after
            gen_server:stop(Router),
            ResponseLink ! stop
        end
    after
        exit(Caller, kill),
        ok = wait_proof_workers(Ns, 0, 200)
    end.

target_reverifies_signature_deadline_and_exact_anchor(
  #{namespace := Ns, key_pair := KeyPair, link := Link}) ->
    Good = signed_fixture(Ns, KeyPair, quod_time:now_ms() + 30000),
    ?assertEqual(
       {error, invalid_signature},
       quod_client_goal_target:prepare_forwarded(
         maps:get(request_bytes, Good), <<0:512>>, ?FORWARDER, Link, none)),
    Expired = signed_fixture(Ns, KeyPair, quod_time:now_ms() - 1),
    ?assertEqual(
       {error, expired},
       quod_client_goal_target:prepare_forwarded(
         maps:get(request_bytes, Expired), maps:get(signature, Expired),
         ?FORWARDER, Link, none)),
    Wrong = quod_ct:signed_goal_fixture(
              #{network => ?NETWORK, target => {Ns, <<16#54:256>>},
                mode => read, key_pair => KeyPair,
                deadline => quod_time:now_ms() + 30000,
                goal_text => <<"lookup(X).">>}),
    ?assertEqual(
       {error, wrong_target},
       quod_client_goal_target:prepare_forwarded(
         maps:get(request_bytes, Wrong), maps:get(signature, Wrong),
         ?FORWARDER, Link, none)),
    WrongNetwork = quod_ct:signed_goal_fixture(
                     #{network => <<16#57:256>>,
                       target => {Ns, ?ANCHOR}, mode => read,
                       key_pair => KeyPair,
                       deadline => quod_time:now_ms() + 30000,
                       goal_text => <<"lookup(X).">>}),
    ?assertEqual(
       {error, wrong_network},
       quod_client_goal_target:prepare_forwarded(
         maps:get(request_bytes, WrongNetwork),
         maps:get(signature, WrongNetwork), ?FORWARDER, Link, none)).

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    stop_named(quod_client_auth),
    PreviousDesired = application:get_env(quod, namespace_desired),
    application:set_env(
      quod, namespace_desired,
      #{content => #{quod_ontology:root_ns() =>
                         #{genesis_hash => ?NETWORK}}, brahms => #{}}),
    Ns = <<"signed-target:",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Table = binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
    Table = ets:new(Table, [named_table, public, set]),
    true = ets:insert(Table, {anchor, ?ANCHOR}),
    {ok, Engine} = quod_prolog:start_link(
                     Ns, #{node_id => {"127.0.0.1", 5000},
                           max_proof_workers => 1,
                           outcome_backend => memory}),
    KeyPair = quod_identity:generate(),
    {SigningKey, _} = KeyPair,
    Instance = {human_user, test_agent},
    AgentRef = {agent_instance_ref, Ns, ?ANCHOR, Instance},
    Policy = {can_invoke, {'Goal'}, AgentRef, {'Chain'}, Ns},
    GenesisAuthor = <<16#55:256>>,
    Diff = quod_ct:diff_for({lookup, bob}) ++
        quod_ct:diff_for({agent_key, Instance, SigningKey, active}) ++
        quod_ct:diff_for(Policy) ++
        quod_ct:diff_for({':-', loop, loop}),
    Genesis = quod_simplex:test_genesis_tx(
                #{mode => create, node_id => GenesisAuthor,
                  committee => [], genesis_diff => Diff},
                Ns, GenesisAuthor, <<16#56:256>>),
    ok = quod_prolog:apply_entry(
           Ns, #entry{index = 1, data = {batch, [Genesis]}}, live),
    ok = quod_prolog:mark_ready(Ns),
    {ok, Auth} = quod_client_auth:start_link(
                   #{network_id => ?NETWORK, node_key => ?FORWARDER}),
    Link = spawn(fun link_loop/0),
    #{namespace => Ns, key_pair => KeyPair, engine => Engine, auth => Auth,
      link => Link, table => Table, previous_desired => PreviousDesired}.

cleanup(#{engine := Engine, auth := Auth, link := Link, table := Table,
          previous_desired := PreviousDesired}) ->
    stop_process(Auth),
    stop_process(Engine),
    Link ! stop,
    ets:delete(Table),
    restore_env(namespace_desired, PreviousDesired).

signed_fixture(Ns, KeyPair, Deadline) ->
    signed_fixture(Ns, KeyPair, Deadline, <<"lookup(X).">>).

signed_fixture(Ns, KeyPair, Deadline, GoalText) ->
    signed_fixture(Ns, KeyPair, Deadline, read, GoalText).

signed_fixture(Ns, KeyPair, Deadline, Mode, GoalText) ->
    quod_ct:signed_goal_fixture(
      #{network => ?NETWORK, target => {Ns, ?ANCHOR}, mode => Mode,
        key_pair => KeyPair, deadline => Deadline,
        goal_text => GoalText}).

response_link(Parent) ->
    receive
        {send_ordered, Frame} ->
            Parent ! {target_response, self(), Frame},
            response_link(Parent);
        stop -> ok
    end.

wait_proof_workers(_Ns, _Expected, 0) -> timeout;
wait_proof_workers(Ns, Expected, Remaining) ->
    case maps:get(proof_workers, quod_prolog:stats(Ns), undefined) of
        Expected -> ok;
        _ ->
            receive after 1 -> ok end,
            wait_proof_workers(Ns, Expected, Remaining - 1)
    end.

link_loop() -> receive stop -> ok end.

stop_named(Name) ->
    case whereis(Name) of undefined -> ok; Pid -> stop_process(Pid) end.

stop_process(Pid) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            unlink(Pid),
            MRef = monitor(process, Pid),
            exit(Pid, shutdown),
            receive {'DOWN', MRef, process, Pid, _} -> ok
            after 5000 -> error(process_stop_timeout)
            end
    end.

restore_env(Key, undefined) -> application:unset_env(quod, Key);
restore_env(Key, {ok, Value}) -> application:set_env(quod, Key, Value).
