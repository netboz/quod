-module(quod_ask_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([remote_scope_solutions/1, remote_scope_symbol_safety/1,
         remote_scope_chain_policy/1, remote_scope_failure_reasons/1,
         remote_scope_nested_failure_reasons/1,
         remote_scope_deep_failure_reasons/1,
         remote_scope_structural_reason_truncation/1,
         remote_scope_cancel/1, remote_scope_transport_reuse/1,
         remote_signed_gateway_read_execute_cursor/1,
         remote_signed_two_gateway_race/1,
         remote_signed_gateway_group/1,
         remote_signed_concurrent_gateway_groups/1,
         remote_signed_queued_occ_abort/1,
         remote_signed_gateway_group_with_root_effect/1,
         remote_signed_group_uses_exact_agent_request/1,
         remote_group_recovers_after_origin_crash/1]).
-export([run_scope_proofs/3]).

-define(TARGET_PORT, 15970).
-define(ASKER_PORT, 15971).
-define(THIRD_PORT, 15972).
-define(NS, <<"animals">>).
-define(ASKER_NS, <<"pets">>).
-define(PRIVATE_NS, <<"private">>).
-define(THIRD_NS, <<"third">>).
-define(ROOT_NS, <<"quod:root">>).
-define(SCOPE_WAVE_SIZE, 8).

all() -> [remote_scope_solutions, remote_scope_symbol_safety,
          remote_scope_chain_policy, remote_scope_failure_reasons,
          remote_scope_nested_failure_reasons,
          remote_scope_deep_failure_reasons,
          remote_scope_structural_reason_truncation,
          remote_scope_cancel, remote_scope_transport_reuse,
          remote_signed_gateway_read_execute_cursor,
          remote_signed_two_gateway_race,
          remote_signed_gateway_group,
          remote_signed_concurrent_gateway_groups,
          remote_signed_queued_occ_abort,
          remote_signed_gateway_group_with_root_effect,
          remote_signed_group_uses_exact_agent_request,
          remote_group_recovers_after_origin_crash].

init_per_suite(Config) ->
    {TargetPub, _} = TargetKey = quod_identity:generate(),
    {WrongPub, _} = wrong_key_before(TargetPub),
    {AskerPub, _} = AskerKey = quod_identity:generate(),
    {ThirdPub, _} = ThirdKey = quod_identity:generate(),
    {AgentPub, _} = AgentKey = quod_identity:generate(),
    TargetAddr = {"127.0.0.1", ?TARGET_PORT},
    AskerAddr = {"127.0.0.1", ?ASKER_PORT},
    ThirdAddr = {"127.0.0.1", ?THIRD_PORT},
    Animals = filename:join(code:priv_dir(quod), "ontologies/animals.pl"),
    Pets = filename:join(code:priv_dir(quod), "ontologies/pets.pl"),
    {ok, AnimalsBin} = file:read_file(Animals),
    {ok, PetsBin} = file:read_file(Pets),
    TargetGenesis = filename:join(?config(priv_dir, Config), "remote_animals.pl"),
    ok = file:write_file(
           TargetGenesis,
           ["can_invoke(_Goal, agent_instance_ref(<<\"pets\">>, _, "
            "human_user(test_agent)), _Chain, _Ns).\n",
            AnimalsBin,
            "\necho(X).\n"
            "blocked(X) :- fail_with_reason(impossible_to_link(X)).\n",
            "via_third_failure :- third::third_blocked.\n",
            "dtx_write_chain(X) :- assertz(dtx_animals_mark(X)), "
            "third::dtx_write(X).\n",
            "conflict_version(0).\n"
            "dtx_conflicting_write(X) :- conflict_version(_), "
            "retract(conflict_version(0)), assertz(conflict_version(X)), "
            "assertz(dtx_conflict_mark(X)), third::dtx_write(X).\n",
            deep_failure_rules(),
            "loop :- loop.\n"]),
    TargetAllow = #{?ASKER_NS => [AskerPub],
                    ?THIRD_NS => [ThirdPub]},
    Target = start_node(target, ?TARGET_PORT, TargetKey, ?NS,
                        TargetGenesis, [], TargetAllow, Config),
    ThirdGenesis = filename:join(?config(priv_dir, Config), "remote_third.pl"),
    ok = file:write_file(
           ThirdGenesis,
           "can_invoke(_Goal, _Principal, _Chain, _Ns).\n"
           "third_blocked :- fail_with_reason(third_declined).\n"
           "dtx_write(X) :- assertz(dtx_third_mark(X)).\n"),
    ThirdAllow = #{?ASKER_NS => [AskerPub],
                   ?NS => [TargetPub]},
    Third = start_node(third, ?THIRD_PORT, ThirdKey, ?THIRD_NS,
                       ThirdGenesis, [], ThirdAllow, Config),
    PrivateGenesis = filename:join(?config(priv_dir, Config), "remote_private.pl"),
    %% Policy belongs in GENESIS. `can_invoke/4` gates every scope entry —
    %% including a top-level prove on this node — so an ontology born without a
    %% clause could never be given one: it would deny the very proof that would
    %% assert its policy. An empty chain is this host's own entry, which is
    %% allowed so the ontology is usable at all; the restrictive clauses for
    %% remote callers are asserted through it below.
    ok = file:write_file(
           PrivateGenesis,
           ["can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n",
            "can_invoke(_Goal, _Principal, [], _Ns).\n",
            "secret(42).\n"
            "hidden(99).\n"]),
    start_namespace(Target, TargetPub, ?PRIVATE_NS, PrivateGenesis, [], Config),
    start_root_namespace(Target, TargetPub, Config),
    start_brahms(Target, ?NS, TargetAddr, []),
    DirectoryAllow = #{?NS => [WrongPub, TargetPub],
                       ?THIRD_NS => [ThirdPub],
                       ?ROOT_NS => [TargetPub]},
    AskerGenesis = filename:join(?config(priv_dir, Config), "remote_pets.pl"),
    AgentKeySource = prolog_binary_literal(AgentPub),
    ok = file:write_file(
           AskerGenesis,
           ["agent_key(human_user(test_agent), ", AgentKeySource,
            ", active).\n",
            %% Only a goal which also writes A is locally authorized here.
            %% Exact remote selectors deliberately have no matching A policy;
            %% the target ontology alone must authorize its predicate.
            "can_invoke((assertz(signed_pets_mark(_)), _), "
            "agent_instance_ref(<<\"pets\">>, _, human_user(test_agent)), "
            "_Chain, _Ns).\n",
            PetsBin,
            "\nrecover_third_failure :- animals::via_third_failure ; "
            "get_fail_reasons([_, _, _, _, third_declined]).\n"]),
    Asker = start_node(asker, ?ASKER_PORT, AskerKey, ?ASKER_NS,
                       AskerGenesis,
                       [TargetAddr], DirectoryAllow, Config),
    TargetAnchor = peer:call(
                     Target, quod_simplex, genesis_hash, [?NS]),
    ThirdAnchor = peer:call(
                    Third, quod_simplex, genesis_hash, [?THIRD_NS]),
    AskerAnchor = peer:call(
                     Asker, quod_simplex, genesis_hash, [?ASKER_NS]),
    RootAnchor = peer:call(
                   Target, quod_simplex, genesis_hash, [?ROOT_NS]),
    AgentRef = {agent_instance_ref, ?ASKER_NS, AskerAnchor,
                {human_user, test_agent}},
    %% A lower-sorting route points at a valid server with the WRONG certificate:
    %% the pinned dial must reject it and advance to the real route.
    {ok, _} = peer:call(
                Asker, quod_directory, install_record,
                [WrongPub, TargetAddr,
                 [{?NS, TargetAnchor, validator}], 1, 1]),
    {ok, _} = peer:call(
                Asker, quod_directory, install_record,
                [TargetPub, TargetAddr,
                 [{?NS, TargetAnchor, validator},
                  {?ROOT_NS, RootAnchor, validator}], 1, 1]),
    %% DTX phase references are verified independently at every participant.
    %% A therefore needs exact routes to B and C, while B/C each need the
    %% origin route for Begin/Decision evidence.  B deliberately still has no
    %% C route: nested scope selection remains owned and relayed by A.
    {ok, _} = peer:call(
                Asker, quod_directory, install_record,
                [ThirdPub, ThirdAddr,
                 [{?THIRD_NS, ThirdAnchor, validator}], 1, 1]),
    {ok, _} = peer:call(
                Third, quod_directory, install_record,
                [TargetPub, TargetAddr,
                 [{?NS, TargetAnchor, validator}], 1, 1]),
    {ok, _} = peer:call(
                Target, quod_directory, install_record,
                [AskerPub, AskerAddr,
                 [{?ASKER_NS, AskerAnchor, validator}], 1, 1]),
    {ok, _} = peer:call(
                Third, quod_directory, install_record,
                [AskerPub, AskerAddr,
                 [{?ASKER_NS, AskerAnchor, validator}], 1, 1]),
    %% The private ontology is reachable only through an explicit local seed.
    ok = peer:call(
           Asker, quod_directory, add_direct_seed,
           [?PRIVATE_NS, TargetAddr]),
    %% The origin, not the currently executing B scope, selects C for A→B→C.
    %% B therefore has no C route; this exercises the authenticated controller
    %% relay and target-only atom materialization path.
    ok = peer:call(
           Asker, quod_directory, add_direct_seed,
           [?THIRD_NS, ThirdAddr]),
    start_brahms(Asker, ?ASKER_NS, AskerAddr, [TargetAddr]),
    start_brahms(Third, ?THIRD_NS, ThirdAddr, []),
    NetworkId = RootAnchor,
    lists:foreach(
      fun(Peer) -> set_network_identity(Peer, NetworkId) end,
      [Target, Asker, Third]),
    %% Root's ordinary Prolog policy, not the transport fixture, grants this
    %% exact durable agent permission to create an ontology.  The signed
    %% remote-effect case below must still pass Root's normal can_invoke and
    %% can_create_ontology rules.
    ?assertMatch(
       {ok, [_], _},
       peer:call(
         Target, quod_prolog, prove,
         [?ROOT_NS, {assertz, {ontology_creator_agent, AgentRef}}],
         60000)),
    AuthPid = peer:call(Asker, erlang, whereis, [quod_client_auth]),
    true = is_pid(AuthPid),
    ClientPeer = {127, 0, 0, 1},
    Session = open_client_session(
                Asker, NetworkId, AskerPub, AgentKey, ClientPeer),
    wait_ready(Target, ?NS, {diet, dog, kibble}),
    wait_ready(Target, ?PRIVATE_NS, {secret, 42}),
    wait_ready(Third, ?THIRD_NS,
               {can_invoke, probe, anonymous, [], ?THIRD_NS}),
    wait_ready(Asker, ?ASKER_NS, {instance_of, pet, my_dog}),
    %% `can_invoke/4` receives the authenticated principal and the whole
    %% origin-built chain at once, so a restrictive policy names both itself.
    %% `secret/1` admits the real node key; `hidden/1` deliberately names a
    %% different one, so the negative case still proves that an ontology name
    %% in the chain cannot launder its transport.
    ACLs = [
        {assertz, {can_invoke, {secret, {'X'}}, {node, AskerPub},
                   {'_'}, ?PRIVATE_NS}},
        {assertz, {can_invoke, {hidden, {'X'}}, {node, <<0:256>>},
                   {'_'}, ?PRIVATE_NS}}
    ],
    lists:foreach(
      fun(ACL) ->
          ?assertMatch({ok, [_], _},
                       peer:call(Target, quod_prolog, prove,
                                 [?PRIVATE_NS, ACL], 60000))
      end, ACLs),
    [{target, Target}, {asker, Asker}, {third, Third},
     {target_pub, TargetPub}, {asker_pub, AskerPub},
     {wrong_pub, WrongPub},
     {target_addr, TargetAddr}, {third_pub, ThirdPub},
     {third_addr, ThirdAddr}, {network_id, NetworkId},
     {asker_anchor, AskerAnchor},
     {agent_ref, AgentRef},
     {agent_key, AgentKey}, {agent_pub, AgentPub},
     {client_peer, ClientPeer}, {client_session, Session},
     {client_auth, AuthPid} | Config].

end_per_suite(Config) ->
    _ = [catch peer:stop(P) || P <- [?config(target, Config),
                                      ?config(asker, Config),
                                      ?config(third, Config)]],
    ok.

remote_scope_solutions(Config) ->
    Asker = ?config(asker, Config),
    Goal = {'::', ?NS, {diet, dog, {'D'}}},
    ?assertMatch({ok, [#{'D' := {'$quod_symbol', <<"kibble">>}}], _},
                 peer:call(Asker, quod_prolog, prove, [?ASKER_NS, Goal], 60000)),
    All = {findall, {'D'}, Goal, {'L'}},
    ?assertMatch({ok, [#{'L' := [{'$quod_symbol', <<"kibble">>},
                                  {'$quod_symbol', <<"meat">>}]}], _},
                 peer:call(Asker, quod_prolog, prove, [?ASKER_NS, All], 60000)).

remote_scope_symbol_safety(Config) ->
    Target = ?config(target, Config),
    Asker = ?config(asker, Config),
    Echo = {'::', ?NS, {echo, asker_only_symbol}},
    ?assertMatch({ok, [#{}], _},
                 peer:call(Asker, quod_prolog, prove,
                           [?ASKER_NS, Echo], 60000)),
    ?assertEqual({ok, {'$quod_symbol', <<"asker_only_symbol">>}},
                 peer:call(Target, quod_wire_term, decode,
                           [{0, <<"asker_only_symbol">>}])),
    Unknown = {'::', ?NS, {asker_only_predicate, x}},
    ?assertMatch({fail, [_ | _]},
                 peer:call(Asker, quod_prolog, prove,
                           [?ASKER_NS, Unknown], 60000)).

remote_scope_chain_policy(Config) ->
    Asker = ?config(asker, Config),
    Allowed = {'::', ?PRIVATE_NS, {secret, {'X'}}},
    ?assertMatch(
       {ok, [#{'X' := 42}], _},
       peer:call(Asker, quod_prolog, prove,
                 [?ASKER_NS, Allowed], 60000)),
    %% A refusal crosses QUIC as ordinary logical failure carrying its bounded
    %% reason, so the caller can inspect it and branch — same contract as the
    %% co-hosted path.
    Denied = {'::', ?PRIVATE_NS, {hidden, {'X'}}},
    {fail, DeniedReasons} =
        peer:call(Asker, quod_prolog, prove,
                  [?ASKER_NS, Denied], 60000),
    ?assert(lists:member({not_allowed, ?PRIVATE_NS}, DeniedReasons)),
    ?assertMatch(
       {ok, [#{'X' := 42}], _},
       peer:call(Asker, quod_prolog, prove,
                 [?ASKER_NS, {';', Denied, Allowed}], 60000)),
    {known, [Route]} = peer:call(
                         Asker, quod_directory, resolve, [?PRIVATE_NS]),
    ?assertEqual(direct, maps:get(scope, Route)),
    ?assertEqual(confirmed, maps:get(status, Route)),
    ?assertEqual([], peer:call(
                       Asker, quod_directory, directory_hosts,
                       [?PRIVATE_NS])).

remote_scope_failure_reasons(Config) ->
    Asker = ?config(asker, Config),
    Remote = {'::', ?NS, {blocked, bob}},
    Recover = {';', Remote,
               {get_fail_reasons,
                [{'Outer'}, {blocked, bob}, {impossible_to_link, bob}]}},
    ?assertMatch(
       {ok, [#{'Outer' := Remote}], _},
       peer:call(Asker, quod_prolog, prove,
                 [?ASKER_NS, Recover], 60000)).

%% The C predicate name is compiled only on B/C. A relays it without allocating
%% an atom; C materializes it after authenticating the scoped command. A's
%% declared recovery rule then matches C's reason after it returns through B.
remote_scope_nested_failure_reasons(Config) ->
    Asker = ?config(asker, Config),
    ?assertMatch(
       {ok, [#{}], _},
       peer:call(Asker, quod_prolog, prove,
                 [?ASKER_NS, recover_third_failure], 60000)),
    ?assertEqual(
       {ok, {'$quod_symbol', <<"third_blocked">>}},
       peer:call(Asker, quod_wire_term, decode,
                 [{0, <<"third_blocked">>}])).

remote_scope_deep_failure_reasons(Config) ->
    Asker = ?config(asker, Config),
    Remote = {'::', ?NS, {deep_failure, 70}},
    {fail, Reasons} = peer:call(
                        Asker, quod_prolog, prove,
                        [?ASKER_NS, Remote], 60000),
    ?assert(length(Reasons) > 64),
    ?assertEqual(Remote, hd(Reasons)),
    ?assertEqual({'$quod_symbol', <<"deep_bottom">>}, lists:last(Reasons)).

remote_scope_structural_reason_truncation(Config) ->
    Asker = ?config(asker, Config),
    Remote = {'::', ?NS, deep_reason},
    {fail, Reasons} = peer:call(
                        Asker, quod_prolog, prove,
                        [?ASKER_NS, Remote], 60000),
    ?assertEqual(Remote, hd(Reasons)),
    ?assert(lists:member(deep_reason, Reasons)),
    ?assert(lists:member(fail_reasons_truncated, Reasons)).

remote_scope_cancel(Config) ->
    Target = ?config(target, Config),
    Asker = ?config(asker, Config),
    Loop = {'::', ?NS, loop},
    Caller = peer:call(Asker, erlang, spawn,
                       [quod_prolog, prove, [?ASKER_NS, Loop]]),
    wait_scope_workers(Target, 1, 200),
    true = peer:call(Asker, erlang, exit, [Caller, kill]),
    wait_scope_workers(Target, 0, 200).

%% Scope commands share the bounded node-level router without sharing proof
%% state. Two full waves prove that completed scopes release every target worker
%% and leave the transport reusable for independent proofs.
remote_scope_transport_reuse(Config) ->
    Target = ?config(target, Config),
    Asker = ?config(asker, Config),
    Goal = {'::', ?NS, {diet, dog, kibble}},
    run_scope_wave(Asker, Goal, first),
    wait_scope_workers(Target, 0, 200),
    run_scope_wave(Asker, Goal, second),
    wait_scope_workers(Target, 0, 200).

%% The browser is logged into A as an agent stored in A. Exact selectors reach
%% B through the ordinary scope path. A has no ACL clause for these goals, so
%% success proves that A authenticates identity while B alone authorizes B's
%% predicate.
remote_signed_gateway_read_execute_cursor(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    NetworkId = ?config(network_id, Config),
    AgentKey = ?config(agent_key, Config),
    AgentPub = ?config(agent_pub, Config),
    Session = ?config(client_session, Config),
    Peer = ?config(client_peer, Config),
    AgentAnchor = ?config(asker_anchor, Config),

    {ReadBytes, ReadSignature} = signed_goal_request(
                                   NetworkId, AgentPub, AgentKey,
                                   ?ASKER_NS, AgentAnchor,
                                   maps:get(expires_ms, Session), read,
                                   <<"\"animals\"::diet(dog, D).">>),
    {ok, ReadEvidence,
     {normalized, {answers, _ReadHeight, ReadBlobs}}} =
        peer:call(
          Asker, quod_client_goal_ingress, submit,
          [read, maps:get(session_id, Session), ReadBytes, ReadSignature, Peer],
          60000),
    ?assertEqual(ReadBytes, maps:get(request_bytes, ReadEvidence)),
    ?assertEqual(ReadSignature, maps:get(signature, ReadEvidence)),
    ?assertEqual(
       [[{<<"D">>, kibble}]],
       [begin {ok, Binding} = quod_durable_term:decode_result(Blob), Binding end
        || Blob <- ReadBlobs]),
    %% This first request also proves pre-send failover past the lower-sorting
    %% wrong-certificate route. Retire it so the remaining cases stay fast.
    retire_wrong_route(Asker, ?config(wrong_pub, Config),
                       ?config(target_addr, Config), 200),

    Tag = erlang:unique_integer([positive]),
    ExecuteText = iolist_to_binary(
                    io_lib:format("assertz(gateway_mark(~B)).", [Tag])),
    {ExecuteBytes, ExecuteSignature} = signed_goal_request(
                                         NetworkId, AgentPub, AgentKey,
                                         ?ASKER_NS, AgentAnchor,
                                         maps:get(expires_ms, Session),
                                         execute,
                                         <<"\"animals\"::", ExecuteText/binary>>),
    ?assertMatch(
       {ok, _,
        {normalized,
         {committed, [_], {group_outcome, {group, ?ASKER_NS,
                                            AgentAnchor, _, _, _},
                                           _, [_, _]}}}},
       peer:call(
         Asker, quod_client_goal_ingress, submit,
         [execute, maps:get(session_id, Session), ExecuteBytes,
          ExecuteSignature, Peer], 60000)),
    assert_fact_once(Target, ?NS, gateway_mark, Tag),

    CursorText =
        <<"\"animals\"::(diet(dog, D), assertz(gateway_choice(D))).">>,
    {CursorBytes, CursorSignature} = signed_goal_request(
                                       NetworkId, AgentPub, AgentKey,
                                       ?ASKER_NS, AgentAnchor,
                                       maps:get(expires_ms, Session),
                                       cursor, CursorText),
    {ok, CursorEvidence,
     {normalized, {solution, CursorId, _, FirstBlob}}} =
        peer:call(
          Asker, quod_client_goal_ingress, submit,
          [cursor, maps:get(session_id, Session), CursorBytes,
           CursorSignature, Peer], 60000),
    ?assertEqual({ok, [{<<"D">>, kibble}]},
                 quod_durable_term:decode_result(FirstBlob)),
    {ok, CursorEvidence,
     {normalized, {solution, CursorId, _, SecondBlob}}} =
        peer:call(
          Asker, quod_client_goal_ingress, cursor_command,
          [maps:get(session_id, Session), CursorId, next, Peer], 60000),
    ?assertEqual({ok, [{<<"D">>, meat}]},
                 quod_durable_term:decode_result(SecondBlob)),
    ?assertMatch(
       {ok, CursorEvidence,
        {normalized,
         {committed, [_], {group_outcome, {group, ?ASKER_NS,
                                            AgentAnchor, _, _, _},
                                           _, [_, _]}}}},
       peer:call(
         Asker, quod_client_goal_ingress, cursor_command,
         [maps:get(session_id, Session), CursorId, accept, Peer], 60000)),
    assert_fact_once(Target, ?NS, gateway_choice, meat),

    {StopBytes, StopSignature} = signed_goal_request(
                                   NetworkId, AgentPub, AgentKey,
                                   ?ASKER_NS, AgentAnchor,
                                   maps:get(expires_ms, Session), cursor,
                                   <<"\"animals\"::diet(dog, D).">>),
    {ok, _, {normalized, {solution, StopCursor, _, _}}} =
        peer:call(
          Asker, quod_client_goal_ingress, submit,
          [cursor, maps:get(session_id, Session), StopBytes,
           StopSignature, Peer], 60000),
    ?assertMatch(
       {ok, _, {normalized, stopped}},
       peer:call(
         Asker, quod_client_goal_ingress, cursor_command,
         [maps:get(session_id, Session), StopCursor, stop, Peer], 60000)).

%% Two independent gateways race the same signed execute. One may receive a
%% typed pre-custody availability refusal while the other proof is sealing;
%% the stable operation claim must still give both gateways one durable result
%% and one material write.
remote_signed_two_gateway_race(Config) ->
    Asker = ?config(asker, Config),
    Third = ?config(third, Config),
    Target = ?config(target, Config),
    NetworkId = ?config(network_id, Config),
    AgentPub = ?config(agent_pub, Config),
    AgentKey = ?config(agent_key, Config),
    ClientPeer = ?config(client_peer, Config),
    %% This case is independently runnable.  The suite starts with one
    %% synthetic wrong-certificate route to exercise failover elsewhere, but
    %% this concurrency assertion must not inherit its removal from a prior
    %% test case.
    retire_wrong_route(Asker, ?config(wrong_pub, Config),
                       ?config(target_addr, Config), 200),
    AskerSession = open_client_session(
                     Asker, NetworkId, ?config(asker_pub, Config),
                     AgentKey, ClientPeer),
    ThirdSession = open_client_session(
                     Third, NetworkId, ?config(third_pub, Config),
                     AgentKey, ClientPeer),
    AgentAnchor = ?config(asker_anchor, Config),
    Tag = erlang:unique_integer([positive]),
    GoalText = iolist_to_binary(
                 io_lib:format(
                   "\"animals\"::assertz(gateway_race_mark(~B)).", [Tag])),
    Expires = min(maps:get(expires_ms, AskerSession),
                  maps:get(expires_ms, ThirdSession)),
    {RequestBytes, Signature} = signed_goal_request(
                                  NetworkId, AgentPub, AgentKey,
                                  ?ASKER_NS, AgentAnchor,
                                  Expires, execute, GoalText),
    Parent = self(),
    RaceRef = make_ref(),
    _ = spawn(
          fun() ->
              Parent !
                {RaceRef, asker,
                 peer:call(
                   Asker, quod_client_goal_ingress, submit,
                   [execute, maps:get(session_id, AskerSession),
                    RequestBytes, Signature, ClientPeer], 60000)}
          end),
    _ = spawn(
          fun() ->
              Parent !
                {RaceRef, third,
                 peer:call(
                   Third, quod_client_goal_ingress, submit,
                   [execute, maps:get(session_id, ThirdSession),
                    RequestBytes, Signature, ClientPeer], 60000)}
          end),
    Results = collect_gateway_race(RaceRef, 2, []),
    Classified = [classify_race_submit(Result)
                  || {_Gateway, Result} <- Results],
    Evidences = [Ev || {accepted, Ev} <- Classified],
    %% A simultaneous second proof may be refused before durable custody while
    %% the first proof is still sealing. That refusal is safe because both
    %% gateways retain the exact same signed request and operation reference;
    %% after the first claim commits, either gateway must resolve it.
    ?assert(Evidences =/= []),
    [Evidence | _] = Evidences,
    OperationRef = maps:get(operation_ref, Evidence),
    lists:foreach(
      fun(Ev) ->
          ?assertEqual(OperationRef, maps:get(operation_ref, Ev)),
          ?assertEqual(RequestBytes, maps:get(request_bytes, Ev)),
          ?assertEqual(Signature, maps:get(signature, Ev))
      end, Evidences),
    {_Claim, _Outcome} = wait_operation_claim(Asker, OperationRef, 600),
    ?assertMatch(
       {ok, _, {operation_outcome,
                #{status := claimed, outcome_ref := _},
                #{status := committed}}},
       wait_remote_operation(
         Asker, maps:get(session_id, AskerSession), RequestBytes,
         Signature, ClientPeer, 8)),
    ?assertMatch(
       {ok, _, {operation_outcome,
                #{status := claimed, outcome_ref := _},
                #{status := committed}}},
       wait_remote_operation(
         Third, maps:get(session_id, ThirdSession), RequestBytes,
         Signature, ClientPeer, 8)),
    assert_fact_once(Target, ?NS, gateway_race_mark, Tag).

%% A signed agent stored in A reaches B and then C through the same nested
%% scope and group machinery. No specialized client or agent executor exists.
remote_signed_gateway_group(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    Third = ?config(third, Config),
    NetworkId = ?config(network_id, Config),
    AgentKey = ?config(agent_key, Config),
    AgentPub = ?config(agent_pub, Config),
    Session = ?config(client_session, Config),
    Peer = ?config(client_peer, Config),

    AgentAnchor = ?config(asker_anchor, Config),
    ThirdPub = ?config(third_pub, Config),
    ThirdAddr = ?config(third_addr, Config),
    ThirdAnchor = peer:call(Third, quod_simplex, genesis_hash, [?THIRD_NS]),
    {ok, _} = peer:call(
                Target, quod_directory, install_record,
                [ThirdPub, ThirdAddr,
                 [{?THIRD_NS, ThirdAnchor, validator}], 1, 1]),
    %% Third already received Target's exact current record in suite setup.
    %% Reinstalling sequence 1 here would correctly be rejected as stale.
    Tag = erlang:unique_integer([positive]),
    GroupText = iolist_to_binary(
                  io_lib:format(
                    "\"animals\"::dtx_write_chain(~B).", [Tag])),
    {GroupBytes, GroupSignature} = signed_goal_request(
                                     NetworkId, AgentPub, AgentKey,
                                     ?ASKER_NS, AgentAnchor,
                                     maps:get(expires_ms, Session), execute,
                                     GroupText),
    {ok, GroupEvidence,
     {normalized,
      {committed, [_],
       {group_outcome,
        {group, ?ASKER_NS, AgentAnchor, _, _, _} = GroupRef,
        _, Slots}}}} =
        peer:call(
          Asker, quod_client_goal_ingress, submit,
          [execute, maps:get(session_id, Session), GroupBytes,
           GroupSignature, Peer], 60000),
    ?assertEqual(3, length(Slots)),
    assert_fact_once(Target, ?NS, dtx_animals_mark, Tag),
    assert_fact_once(Third, ?THIRD_NS, dtx_third_mark, Tag),
    ?assertMatch(
       {ok, #{status := claimed, outcome_ref := GroupRef}},
       peer:call(
         Asker, quod_prolog, outcome,
         [maps:get(operation_ref, GroupEvidence)])),
    ok.

%% Eight independently signed A -> B -> C writes enter together.  The old
%% single handoff slot rejected this shape as busy; the one Simplex admission
%% owner must now serialize every sealed proof into the unchanged DTX path.
remote_signed_concurrent_gateway_groups(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    Third = ?config(third, Config),
    NetworkId = ?config(network_id, Config),
    AgentKey = ?config(agent_key, Config),
    AgentPub = ?config(agent_pub, Config),
    Session = ?config(client_session, Config),
    ClientPeer = ?config(client_peer, Config),
    AgentAnchor = ?config(asker_anchor, Config),
    retire_wrong_route(Asker, ?config(wrong_pub, Config),
                       ?config(target_addr, Config), 200),

    Requests =
        [begin
             Tag = erlang:unique_integer([positive]),
             GoalText = iolist_to_binary(
                          io_lib:format(
                            "\"animals\"::dtx_write_chain(~B).", [Tag])),
             {RequestBytes, Signature} = signed_goal_request(
                                           NetworkId, AgentPub, AgentKey,
                                           ?ASKER_NS, AgentAnchor,
                                           maps:get(expires_ms, Session),
                                           execute, GoalText),
             {Index, Tag, RequestBytes, Signature}
         end || Index <- lists:seq(1, 8)],
    Parent = self(),
    ConcurrentRef = make_ref(),
    Writers =
        [spawn(
           fun() ->
               receive {ConcurrentRef, go} -> ok end,
               Result = peer:call(
                          Asker, quod_client_goal_ingress, submit,
                          [execute, maps:get(session_id, Session),
                           RequestBytes, Signature, ClientPeer], 60000),
               Parent ! {ConcurrentRef, Index, Result}
           end)
         || {Index, _Tag, RequestBytes, Signature} <- Requests],
    lists:foreach(fun(Pid) -> Pid ! {ConcurrentRef, go} end, Writers),
    Results = collect_gateway_race(ConcurrentRef, length(Requests), []),
    EvidenceByIndex =
        maps:from_list(
          [{Index, concurrent_submit_evidence(Index, Result)}
           || {Index, Result} <- Results]),
    OperationRefs =
        [maps:get(operation_ref, maps:get(Index, EvidenceByIndex))
         || {Index, _Tag, _RequestBytes, _Signature} <- Requests],
    ?assertEqual(length(Requests), length(lists:usort(OperationRefs))),
    lists:foreach(
      fun({Index, Tag, _RequestBytes, _Signature}) ->
          OperationRef = maps:get(
                           operation_ref, maps:get(Index, EvidenceByIndex)),
          {#{status := claimed, outcome_ref := GroupRef},
           #{status := committed, participant_slots := Slots}} =
              wait_operation_claim(Asker, OperationRef, 600),
          ?assertMatch(
             {group, ?ASKER_NS, AgentAnchor, _, _, _}, GroupRef),
          ?assertEqual(3, length(Slots)),
          assert_fact_once(Target, ?NS, dtx_animals_mark, Tag),
          assert_fact_once(Third, ?THIRD_NS, dtx_third_mark, Tag)
      end, Requests),
    Stats = peer:call(Asker, quod_simplex, stats, [?ASKER_NS]),
    ?assertEqual(0, maps:get(dtx_admission_waiting, Stats)),
    ?assertEqual(0, maps:get(dtx_admission_dormant, Stats)),
    ok.

%% Both proofs read conflict_version/1 while it is zero, then wait at the
%% pre-Begin FIFO seam. One group changes that fact; the other must retain its
%% claimed operation id and terminate with the ordinary stale-read abort.
remote_signed_queued_occ_abort(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    Third = ?config(third, Config),
    NetworkId = ?config(network_id, Config),
    AgentKey = ?config(agent_key, Config),
    AgentPub = ?config(agent_pub, Config),
    ClientPeer = ?config(client_peer, Config),
    AgentAnchor = ?config(asker_anchor, Config),
    retire_wrong_route(Asker, ?config(wrong_pub, Config),
                       ?config(target_addr, Config), 200),
    Session = open_client_session(
                Asker, NetworkId, ?config(asker_pub, Config),
                AgentKey, ClientPeer),
    Requests =
        [begin
             Tag = erlang:unique_integer([positive]),
             GoalText = iolist_to_binary(
                          io_lib:format(
                            "\"animals\"::dtx_conflicting_write(~B).",
                            [Tag])),
             {RequestBytes, Signature} = signed_goal_request(
                                           NetworkId, AgentPub, AgentKey,
                                           ?ASKER_NS, AgentAnchor,
                                           maps:get(expires_ms, Session),
                                           execute, GoalText),
             {Index, Tag, RequestBytes, Signature}
         end || Index <- [1, 2]],
    Parent = self(),
    RaceRef = make_ref(),
    Writers =
        [spawn(
           fun() ->
               receive {RaceRef, go} -> ok end,
               Result = peer:call(
                          Asker, quod_client_goal_ingress, submit,
                          [execute, maps:get(session_id, Session),
                           RequestBytes, Signature, ClientPeer], 60000),
               Parent ! {RaceRef, Index, Result}
           end)
         || {Index, _Tag, RequestBytes, Signature} <- Requests],
    lists:foreach(fun(Pid) -> Pid ! {RaceRef, go} end, Writers),
    Evidences = maps:from_list(
                  [{Index, concurrent_conflict_evidence(Index, Result)}
                   || {Index, Result} <-
                          collect_gateway_race(RaceRef, 2, [])]),
    Outcomes =
        [{Index, Tag, RequestBytes, Signature,
          wait_operation_terminal(
            Asker, maps:get(operation_ref, maps:get(Index, Evidences)), 600)}
         || {Index, Tag, RequestBytes, Signature} <- Requests],
    [{CommittedIndex, CommittedTag, _CommittedBytes, _CommittedSignature,
      {_, #{status := committed}}}] =
        [Row || Row = {_, _, _, _, {_, #{status := committed}}} <- Outcomes],
    [{AbortedIndex, AbortedTag, AbortedBytes, AbortedSignature,
      {#{status := claimed}, #{status := aborted}}}] =
        [Row || Row = {_, _, _, _,
                       {#{status := claimed}, #{status := aborted}}} <- Outcomes],
    ?assertNotEqual(CommittedIndex, AbortedIndex),
    assert_fact_once(Target, ?NS, dtx_conflict_mark, CommittedTag),
    assert_fact_absent(Target, ?NS, dtx_conflict_mark, AbortedTag),
    assert_fact_once(Third, ?THIRD_NS, dtx_third_mark, CommittedTag),
    ?assertMatch(
       {ok, _, {operation_outcome,
                #{status := claimed}, #{status := aborted}}},
       wait_remote_operation(
         Asker, maps:get(session_id, Session), AbortedBytes,
         AbortedSignature, ClientPeer, 8)),
    ok.

%% One signed proof writes its agent ontology and stages Root's existing
%% create-ontology effect.  Root is hosted on another peer, so this exercises
%% the real V5 scope custody command, not only the co-hosted session path.
remote_signed_gateway_group_with_root_effect(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    NetworkId = ?config(network_id, Config),
    AgentKey = ?config(agent_key, Config),
    AgentPub = ?config(agent_pub, Config),
    Session = ?config(client_session, Config),
    Peer = ?config(client_peer, Config),
    AgentAnchor = ?config(asker_anchor, Config),
    Tag = erlang:unique_integer([positive]),
    CreatedNs = iolist_to_binary(
                  ["ct:remote-effect-", integer_to_binary(Tag)]),
    GoalText = iolist_to_binary(
                 io_lib:format(
                   "assertz(signed_pets_mark(~B)), "
                   "\"quod:root\"::create_ontology(\"~s\", "
                   "[source(\"can_invoke(_, _, _, _).\\n"
                   "remote_effect_created(ok).\\n\")]).",
                   [Tag, CreatedNs])),
    {RequestBytes, Signature} = signed_goal_request(
                                  NetworkId, AgentPub, AgentKey,
                                  ?ASKER_NS, AgentAnchor,
                                  maps:get(expires_ms, Session), execute,
                                  GoalText),
    {ok, _Evidence,
     {normalized,
      {committed, [_],
       {group_outcome,
        {group, ?ASKER_NS, AgentAnchor, _, _, _} = GroupRef,
        _, Slots}}}} =
        peer:call(
          Asker, quod_client_goal_ingress, submit,
          [execute, maps:get(session_id, Session), RequestBytes,
           Signature, Peer], 60000),
    ?assertEqual(2, length(Slots)),
    assert_fact_once(Asker, ?ASKER_NS, signed_pets_mark, Tag),
    wait_ready(Target, CreatedNs, {remote_effect_created, ok}),
    wait_remote_effect_state(Target, CreatedNs, GroupRef, applied, 300),
    ok.

%% One browser-equivalent request crosses two remote scope hops and commits
%% through the ordinary group protocol.  Earlier cases have already proved
%% failover past the suite's synthetic wrong-certificate route; retire that
%% route now so every DTX evidence phase does not pay its full dial timeout.
remote_signed_group_uses_exact_agent_request(Config) ->
    Asker = ?config(asker, Config),
    retire_wrong_route(Asker, ?config(wrong_pub, Config),
                       ?config(target_addr, Config), 200),
    NetworkId = ?config(network_id, Config),
    AgentKey = ?config(agent_key, Config),
    AgentPub = ?config(agent_pub, Config),
    Session = ?config(client_session, Config),
    Peer = ?config(client_peer, Config),
    Anchor = ?config(asker_anchor, Config),
    Tag = erlang:unique_integer([positive]),
    GoalText = iolist_to_binary(
                 io_lib:format(
                   "assertz(signed_pets_mark(~B)), "
                   "\"animals\"::dtx_write_chain(~B).",
                   [Tag, Tag])),
    {RequestBytes, Signature} = signed_goal_request(
                                  NetworkId, AgentPub, AgentKey,
                                  ?ASKER_NS, Anchor,
                                  maps:get(expires_ms, Session), GoalText),
    {ok, Evidence, {normalized, SubmitResult}} = peer:call(
                                                   Asker,
                                                   quod_client_goal_ingress,
                                                   submit,
                                                   [execute,
                                                    maps:get(session_id,
                                                             Session),
                                                    RequestBytes, Signature,
                                                    Peer],
                                                   60000),
    {GroupRef, Outcome} =
        case SubmitResult of
            {committed, [_],
             {group_outcome,
              {group, ?ASKER_NS, Anchor, _, _, _} = Ref,
              Height, ParticipantSlots}} ->
                {Ref, #{status => committed, ref => Ref, height => Height,
                        participant_slots => ParticipantSlots}};
            {pending, {group, ?ASKER_NS, Anchor, _, _, _} = Ref} ->
                %% A transport timeout is uncertainty, never permission to
                %% resubmit. Resolve the exact first group instead.
                {Ref, wait_group_outcome(Asker, Ref, 600)}
        end,
    Slots = maps:get(participant_slots, Outcome),
    ?assertEqual(3, length(Slots)),
    assert_fact_once(Asker, ?ASKER_NS, signed_pets_mark, Tag),
    assert_fact_once(?config(target, Config), ?NS, dtx_animals_mark, Tag),
    assert_fact_once(?config(third, Config), ?THIRD_NS, dtx_third_mark, Tag),
    OperationRef = maps:get(operation_ref, Evidence),
    ?assertMatch(
       {ok, #{status := claimed, outcome_ref := GroupRef}},
       peer:call(Asker, quod_prolog, outcome, [OperationRef])).

%% The origin is stopped at the coordinator's certified Decision boundary,
%% before it can plan a Finalize.  Recovery must resume from the durable phase
%% chain, not re-prove or replay any plan, and the exact caller checkpoint must
%% remain sufficient to find the one terminal outcome after restart.
remote_group_recovers_after_origin_crash(Config) ->
    Target = ?config(target, Config),
    Asker = ?config(asker, Config),
    Third = ?config(third, Config),
    Tag = erlang:unique_integer([positive]),
    Goal = {',', {assertz, {dtx_pets_mark, Tag}},
                 {'::', ?NS, {dtx_write_chain, Tag}}},
    ok = peer:call(
           Asker, application, set_env,
           [quod, dtx_test_phase_barrier, {hold, decided}]),
    ?assertEqual(
       {ok, {hold, decided}},
       peer:call(Asker, application, get_env,
                 [quod, dtx_test_phase_barrier])),
    true = peer:call(Asker, erlang, function_exported,
                     [quod_dtx_coordinator, test_status, 1]),
    Parent = self(),
    ProofRef = make_ref(),
    _ProofCaller = spawn(
                     fun() ->
                         Result = peer:call(
                                    Asker, quod_prolog, prove,
                                    [?ASKER_NS, Goal], 60000),
                         Parent ! {ProofRef, Result}
                     end),
    try
        GroupId = wait_decision_barrier(ProofRef, Config),
        %% The coordinator is held before it can plan Finalize.  Neither
        %% remote participant may have a certified Finalize at this point.
        assert_finalize_absent(Target, ?NS, GroupId),
        assert_finalize_absent(Third, ?THIRD_NS, GroupId),
        {ok, {?ASKER_NS, Anchor, Coordinator, Admission}} =
            peer:call(Asker, quod_simplex, dtx_binding, [?ASKER_NS]),
        GroupRef = {group, ?ASKER_NS, Anchor,
                    Coordinator, Admission, GroupId},
        OldSimplex = peer:call(
                       Asker, quod_reg, where,
                       [{quod_simplex, ?ASKER_NS}]),
        true = is_pid(OldSimplex),
        %% The bounded test valve must still be holding the coordinator at
        %% Decision.  Otherwise a slow test could silently crash after a
        %% self-released gate and prove only a weaker recovery path.
        ?assertMatch(
           {ok, {held, GroupId, decided, _}},
           peer:call(Asker, application, get_env,
                     [quod, dtx_test_phase_barrier])),
        %% Disable the one-shot barrier before restart: the replacement
        %% coordinator must be free to rediscover Decision and continue.
        ok = peer:call(
               Asker, application, unset_env,
               [quod, dtx_test_phase_barrier]),
        true = peer:call(Asker, erlang, exit, [OldSimplex, kill]),
        ?assertEqual(
           {error, {outcome_unknown, GroupRef}},
           receive
               {ProofRef, ProofResult} -> ProofResult
           after 10000 ->
               ct:fail(proof_caller_did_not_observe_origin_crash)
           end),
        wait_restarted(Asker, ?ASKER_NS, OldSimplex, 400),
        Outcome = wait_group_outcome(Asker, GroupRef, 600),
        ?assertMatch(
           #{status := committed, ref := GroupRef,
             participant_slots := [_, _, _]}, Outcome),
        assert_fact_once(Asker, ?ASKER_NS, dtx_pets_mark, Tag),
        assert_fact_once(Target, ?NS, dtx_animals_mark, Tag),
        assert_fact_once(Third, ?THIRD_NS, dtx_third_mark, Tag),
        lists:foreach(
          fun({Peer, Ns}) -> assert_dtx_released(Peer, Ns) end,
          [{Asker, ?ASKER_NS}, {Target, ?NS}, {Third, ?THIRD_NS}])
    after
        _ = peer:call(
              Asker, application, unset_env,
              [quod, dtx_test_phase_barrier])
    end.

retire_wrong_route(_Peer, _WrongPub, _Endpoint, 0) ->
    ct:fail(could_not_retire_synthetic_wrong_route);
retire_wrong_route(Peer, WrongPub, Endpoint, Retries) ->
    case set_synthetic_route(
           Peer, WrongPub, Endpoint, [], 1, 2, Retries) of
        ok -> ok;
        %% Another case in the same suite may already have installed this
        %% exact newer retirement record.  The desired route is absent in
        %% either case, so retirement is idempotently complete.
        stale_record -> ok;
        Other ->
            ct:fail({wrong_route_retirement_failed, Other})
    end.

set_synthetic_route(_Peer, _Key, _Endpoint, _Hosted,
                    _Epoch, _Sequence, 0) ->
    ct:fail(could_not_update_synthetic_route);
set_synthetic_route(Peer, Key, Endpoint, Hosted,
                    Epoch, Sequence, Retries) ->
    case peer:call(
           Peer, quod_directory, install_record,
           [Key, Endpoint, Hosted, Epoch, Sequence]) of
        {ok, _} -> ok;
        {error, rate_limited} ->
            timer:sleep(50),
            set_synthetic_route(
              Peer, Key, Endpoint, Hosted, Epoch, Sequence, Retries - 1);
        {error, Reason} -> Reason
    end.

wait_decision_barrier(ProofRef, Config) ->
    wait_decision_barrier(ProofRef, Config, 300).

wait_decision_barrier(_ProofRef, Config, 0) ->
    ct:fail({dtx_decision_barrier_timeout, dtx_diagnostics(Config)});
wait_decision_barrier(ProofRef, Config, Retries) ->
    Asker = ?config(asker, Config),
    case peer:call(
           Asker, application, get_env,
           [quod, dtx_test_phase_barrier]) of
        {ok, {held, <<_:256>> = GroupId, decided, _BarrierRef}} ->
            %% This confirms that a live coordinator advanced to Decision;
            %% the gate itself is before its next planner drive.
            ?assertMatch(
               #{dtx_coordinator := #{group_id := GroupId}},
               peer:call(Asker, quod_simplex, status, [?ASKER_NS])),
            GroupId;
        _ ->
            receive
                {ProofRef, ProofResult} ->
                    ct:fail({group_proof_ended_before_decision, ProofResult})
            after 0 ->
                timer:sleep(50),
                wait_decision_barrier(ProofRef, Config, Retries - 1)
            end
    end.

assert_finalize_absent(Peer, Ns, GroupId) ->
    Request = {phase, crypto:strong_rand_bytes(16), GroupId, finalize},
    ?assertMatch(
       {ok, {phase, _, _, not_found}},
       peer:call(Peer, quod_simplex, dtx_endpoint_local,
                 [Ns, Request, 1000])).

wait_remote_effect_state(_Peer, Ns, GroupRef, Expected, 0) ->
    ct:fail({effect_state_timeout, Ns, GroupRef, Expected});
wait_remote_effect_state(Peer, Ns, GroupRef, Expected, Retries) ->
    Rows = peer:call(Peer, quod_effect_journal, rows, []),
    case [State || #{target := {RowNs, _}, ref := RowRef,
                     state := State} <- Rows,
                   RowNs =:= Ns,
                   element(1, RowRef) =:= group_effect,
                   element(3, RowRef) =:= GroupRef] of
        [Expected] -> ok;
        _ ->
            timer:sleep(20),
            wait_remote_effect_state(
              Peer, Ns, GroupRef, Expected, Retries - 1)
    end.

dtx_diagnostics(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    Third = ?config(third, Config),
    Statuses =
        [{Ns, peer:call(Peer, quod_simplex, status, [Ns])}
         || {Peer, Ns} <- [{Asker, ?ASKER_NS}, {Target, ?NS},
                           {Third, ?THIRD_NS}]],
    GroupId =
        case proplists:get_value(?ASKER_NS, Statuses, #{}) of
            #{dtx_coordinator := #{group_id := Id}} -> Id;
            _ -> undefined
        end,
    AskerInternal = dtx_internal_diagnostics(Asker, ?ASKER_NS),
    Phases =
        case GroupId of
            <<_:256>> ->
                [{Ns,
                  [{Kind,
                    peer:call(
                      Peer, quod_simplex, dtx_endpoint_local,
                      [Ns, {phase, crypto:strong_rand_bytes(16),
                            GroupId, Kind}, 1000])}
                   || Kind <- ['begin', prepare, decision,
                               finalize, complete]]}
                 || {Peer, Ns} <- [{Asker, ?ASKER_NS}, {Target, ?NS},
                                   {Third, ?THIRD_NS}]];
            _ ->
                []
        end,
    BPrepare = phase_result(?NS, Phases, prepare),
    CPrepare = phase_result(?THIRD_NS, Phases, prepare),
    RawBVerify = raw_prepare_verify(
                   Asker, ?config(target_pub, Config),
                   ?config(target_addr, Config), BPrepare),
    RawCVerify = raw_prepare_verify(
                   Asker, ?config(third_pub, Config),
                   ?config(third_addr, Config), CPrepare),
    #{statuses => Statuses, phases => Phases,
      asker_internal => AskerInternal,
      raw_b_prepare_verify => RawBVerify,
      raw_c_prepare_verify => RawCVerify,
      foreign_log_stats =>
          [{Ns, peer:call(Peer, quod_foreign_log, stats, [])}
           || {Peer, Ns} <- [{Asker, ?ASKER_NS}, {Target, ?NS},
                             {Third, ?THIRD_NS}]],
      asker_routes =>
          [{Ns, peer:call(Asker, quod_directory, resolve, [Ns])}
           || Ns <- [?NS, ?THIRD_NS]],
      third_origin_routes =>
          peer:call(Third, quod_directory, validator_routes,
                    [?ASKER_NS,
                     peer:call(Asker, quod_simplex, genesis_hash,
                               [?ASKER_NS])])}.

raw_prepare_verify(
  Peer, Validator, Endpoint,
  {ok, {phase, _RequestId, _Generation, {committed, Ref}}}) ->
    peer:call(Peer, quod_foreign_log, verify,
              [Validator, Endpoint, Ref, prepare, 5000]);
raw_prepare_verify(_Peer, _Validator, _Endpoint, _PhaseResult) ->
    not_committed.

phase_result(Ns, Phases, Kind) ->
    case lists:keyfind(Ns, 1, Phases) of
        {Ns, Results} ->
            case lists:keyfind(Kind, 1, Results) of
                {Kind, Result} -> Result;
                false -> not_queried
            end;
        false -> not_queried
    end.

dtx_internal_diagnostics(Peer, Ns) ->
    Simplex = peer:call(Peer, quod_reg, where, [{quod_simplex, Ns}]),
    case peer:call(Peer, sys, get_state, [Simplex]) of
        {running, State} ->
            Coordinator = peer:call(
                            Peer, quod_simplex,
                            test_dtx_coordinator_state, [State]),
            Counts = peer:call(Peer, quod_simplex,
                               test_dtx_endpoint_counts, [State]),
            #{coordinator => Coordinator,
              coordinator_process => coordinator_process(Peer, Coordinator),
              endpoint_counts => Counts};
        Other ->
            #{state => Other}
    end.

coordinator_process(Peer, #{pid := Pid}) when is_pid(Pid) ->
    #{state => peer:call(Peer, quod_dtx_coordinator, test_status, [Pid]),
      process =>
          peer:call(Peer, erlang, process_info,
                    [Pid, [status, current_function, current_stacktrace,
                           message_queue_len, messages]])};
coordinator_process(_Peer, _Coordinator) ->
    unavailable.

wait_restarted(_Peer, _Ns, _OldSimplex, 0) ->
    ct:fail(origin_namespace_did_not_restart);
wait_restarted(Peer, Ns, OldSimplex, Retries) ->
    Simplex = peer:call(Peer, quod_reg, where, [{quod_simplex, Ns}]),
    Prolog = peer:call(Peer, quod_reg, where, [{quod_prolog, Ns}]),
    case is_pid(Simplex) andalso Simplex =/= OldSimplex andalso
         is_pid(Prolog) of
        true -> ok;
        false -> timer:sleep(25),
                 wait_restarted(Peer, Ns, OldSimplex, Retries - 1)
    end.

wait_group_outcome(_Peer, GroupRef, 0) ->
    ct:fail({group_outcome_never_became_terminal, GroupRef});
wait_group_outcome(Peer, {group, Ns, _, _, _, _} = GroupRef, Retries) ->
    case peer:call(Peer, quod_prolog, outcome, [GroupRef]) of
        {ok, #{status := committed} = Outcome} -> Outcome;
        {ok, #{status := pending}} ->
            timer:sleep(50),
            wait_group_outcome(Peer, GroupRef, Retries - 1);
        {error, {outcome_unknown, GroupRef}} ->
            timer:sleep(50),
            wait_group_outcome(Peer, GroupRef, Retries - 1);
        {error, {ontology_rebuilding, Ns}} ->
            timer:sleep(50),
            wait_group_outcome(Peer, GroupRef, Retries - 1);
        Other ->
            ct:fail({unexpected_group_outcome, Other})
    end.

assert_fact_once(Peer, Ns, Predicate, Tag) ->
    Goal = {findall, ok, {Predicate, Tag}, {'Hits'}},
    ?assertMatch(
       {ok, [#{'Hits' := [ok]}], _},
       peer:call(Peer, quod_prolog, prove, [Ns, Goal], 10000)).

assert_fact_absent(Peer, Ns, Predicate, Tag) ->
    Goal = {findall, ok, {Predicate, Tag}, {'Hits'}},
    ?assertMatch(
       {ok, [#{'Hits' := []}], _},
       peer:call(Peer, quod_prolog, prove, [Ns, Goal], 10000)).

collect_gateway_race(_Ref, 0, Results) -> lists:reverse(Results);
collect_gateway_race(Ref, Remaining, Results) ->
    receive
        {Ref, Gateway, Result} ->
            collect_gateway_race(
              Ref, Remaining - 1, [{Gateway, Result} | Results])
    after 65000 ->
        ct:fail({gateway_race_timeout, Remaining})
    end.

classify_race_submit(
  {ok, Evidence, {normalized, {committed, _Bindings, _Outcome}}}) ->
    {accepted, Evidence};
classify_race_submit(
  {ok, Evidence, {normalized, {pending, _PendingRef}}}) ->
    %% A multi-ontology proof may already be durably represented by its group
    %% reference.  The signed operation remains the stable public lookup key
    %% in either case, and is resolved below without resubmitting.
    {accepted, Evidence};
classify_race_submit({error, signed_target_unavailable}) ->
    pre_custody_unavailable;
classify_race_submit({error, busy}) ->
    pre_custody_unavailable;
classify_race_submit(Other) ->
    ct:fail({gateway_race_submit_failed, Other}).

concurrent_submit_evidence(
  _Index,
  {ok, Evidence, {normalized, {committed, _Bindings, _Outcome}}}) ->
    Evidence;
concurrent_submit_evidence(
  _Index,
  {ok, Evidence, {normalized, {pending, _PendingRef}}}) ->
    Evidence;
concurrent_submit_evidence(Index, Other) ->
    ct:fail({concurrent_signed_dtx_submit_failed, Index, Other}).

%% The losing group can be reported either while still pending or directly as
%% its definitive Prepare refusal. In both cases the signed evidence carries
%% the same operation reference whose final durable outcome is asserted below.
concurrent_conflict_evidence(
  _Index,
  {ok, Evidence, {normalized, {committed, _Bindings, _Outcome}}}) ->
    Evidence;
concurrent_conflict_evidence(
  _Index,
  {ok, Evidence, {normalized, {pending, _PendingRef}}}) ->
    Evidence;
concurrent_conflict_evidence(
  _Index,
  {ok, Evidence, {normalized, {failed, _Reasons}}}) ->
    Evidence;
concurrent_conflict_evidence(Index, Other) ->
    ct:fail({concurrent_signed_conflict_submit_failed, Index, Other}).

wait_operation_claim(_Target, OperationRef, 0) ->
    ct:fail({operation_outcome_timeout, OperationRef});
wait_operation_claim(Target, OperationRef, Remaining) ->
    case peer:call(Target, quod_prolog, outcome, [OperationRef]) of
        {ok, #{status := claimed, outcome_ref := OutcomeRef} = Claim} ->
            case peer:call(Target, quod_prolog, outcome, [OutcomeRef]) of
                {ok, #{status := committed} = Outcome} -> {Claim, Outcome};
                {ok, #{status := pending}} ->
                    timer:sleep(50),
                    wait_operation_claim(Target, OperationRef, Remaining - 1);
                {error, _} ->
                    timer:sleep(50),
                    wait_operation_claim(Target, OperationRef, Remaining - 1);
                Other ->
                    ct:fail({unexpected_operation_outcome, Other})
            end;
        {error, _} ->
            timer:sleep(50),
            wait_operation_claim(Target, OperationRef, Remaining - 1);
        Other ->
            ct:fail({unexpected_operation_claim, Other})
    end.

wait_operation_terminal(_Target, OperationRef, 0) ->
    ct:fail({operation_outcome_timeout, OperationRef});
wait_operation_terminal(Target, OperationRef, Remaining) ->
    case peer:call(Target, quod_prolog, outcome, [OperationRef]) of
        {ok, #{status := claimed, outcome_ref := OutcomeRef} = Claim} ->
            case peer:call(Target, quod_prolog, outcome, [OutcomeRef]) of
                {ok, #{status := Status} = Outcome}
                  when Status =:= committed; Status =:= aborted ->
                    {Claim, Outcome};
                _ ->
                    timer:sleep(50),
                    wait_operation_terminal(Target, OperationRef, Remaining - 1)
            end;
        _ ->
            timer:sleep(50),
            wait_operation_terminal(Target, OperationRef, Remaining - 1)
    end.

wait_remote_operation(_Gateway, _SessionId, _RequestBytes, _Signature,
                      _ClientPeer, 0) ->
    ct:fail(remote_operation_outcome_timeout);
wait_remote_operation(Gateway, SessionId, RequestBytes, Signature,
                      ClientPeer, Remaining) ->
    Result = peer:call(
               Gateway, quod_client_goal_ingress, resolve_operation,
               [SessionId, RequestBytes, Signature, ClientPeer], 10000),
    case Result of
        {ok, _, {operation_outcome, _, _}} -> Result;
        {ok, _, {operation_pending, _}} when Remaining =:= 1 ->
            ct:fail({remote_operation_outcome_timeout, Result});
        {ok, _, {operation_pending, _}} ->
            timer:sleep(250),
            wait_remote_operation(
              Gateway, SessionId, RequestBytes, Signature,
              ClientPeer, Remaining - 1);
        {error, client_goal_rate_limited} when Remaining =:= 1 ->
            ct:fail({remote_operation_outcome_timeout, Result});
        {error, client_goal_rate_limited} ->
            timer:sleep(250),
            wait_remote_operation(
              Gateway, SessionId, RequestBytes, Signature,
              ClientPeer, Remaining - 1);
        Other ->
            ct:fail({remote_operation_outcome_invalid, Other})
    end.

assert_dtx_released(Peer, Ns) ->
    Status = peer:call(Peer, quod_simplex, status, [Ns]),
    Projection = maps:get(history_projection, Status),
    Dtx = maps:get(dtx, Projection),
    ?assertEqual(none, maps:get(active, Dtx)),
    ?assertEqual(open, maps:get(consensus_lock, Dtx)),
    ?assertEqual(open, maps:get(proof_fence, Dtx)).

run_scope_wave(Asker, Goal, Wave) ->
    %% `run_scope_proofs/3` owns a 10-second completion window. The peer call
    %% must outlive it; its default five seconds can otherwise time out before
    %% the helper can report the actual wave result.
    Results = peer:call(
                Asker, ?MODULE, run_scope_proofs,
                [?ASKER_NS, Goal, ?SCOPE_WAVE_SIZE], 15000),
    case Results of
        List when is_list(List), length(List) =:= ?SCOPE_WAVE_SIZE ->
            lists:foreach(
              fun({ok, [_], _}) -> ok;
                 (Result) -> ct:fail({scope_proof_failed, Wave, Result})
              end, List);
        timeout -> ct:fail({scope_proof_timeout, Wave});
        Other -> ct:fail({scope_proof_wave_failed, Wave, Other})
    end.

run_scope_proofs(Ns, Goal, Count) ->
    Parent = self(),
    _ = [spawn(fun() -> Parent ! {proof_done, quod_prolog:prove(Ns, Goal)} end)
         || _ <- lists:seq(1, Count)],
    collect_scope_proofs(Count, []).

collect_scope_proofs(0, Results) -> lists:reverse(Results);
collect_scope_proofs(Count, Results) ->
    receive
        {proof_done, Result} -> collect_scope_proofs(Count - 1, [Result | Results])
    after 10000 ->
        timeout
    end.

set_network_identity(Peer, NetworkId) ->
    Desired = peer:call(
                Peer, application, get_env,
                [quod, namespace_desired, #{}]),
    Content = maps:get(content, Desired, #{}),
    ok = peer:call(
           Peer, application, set_env,
           [quod, namespace_desired,
            Desired#{content => Content#{
              quod_ontology:root_ns() => #{genesis_hash => NetworkId}}}]).

open_client_session(Peer, NetworkId, NodeKey,
                    KeyPair = {PublicKey, _Seed}, ClientPeer) ->
    ClientNonce = crypto:strong_rand_bytes(32),
    {ok, Challenge} = peer:call(
                        Peer, quod_client_auth, issue_challenge,
                        [PublicKey, ClientNonce, ClientPeer]),
    ChallengeId = maps:get(challenge_id, Challenge),
    {ok, ChallengeBytes} = quod_client_auth:challenge_bytes(
                             NetworkId, NodeKey, ChallengeId, PublicKey,
                             ClientNonce, maps:get(server_nonce, Challenge),
                             maps:get(expires_ms, Challenge)),
    Signature = quod_identity:sign(
                  ChallengeBytes, quod_identity:key_term(KeyPair)),
    {ok, Session} = peer:call(
                      Peer, quod_client_auth, complete_challenge,
                      [ChallengeId, Signature]),
    Session.

signed_goal_request(NetworkId, PublicKey, KeyPair, AgentNamespace, AgentAnchor,
                    SessionExpires, GoalText) ->
    signed_goal_request(NetworkId, PublicKey, KeyPair,
                        AgentNamespace, AgentAnchor,
                        SessionExpires, execute, GoalText).

signed_goal_request(NetworkId, PublicKey, KeyPair,
                    AgentNamespace, AgentAnchor,
                    SessionExpires, Mode, GoalText) ->
    Request = #{network_identity => NetworkId,
                signing_public_key => PublicKey,
                operation_id => crypto:strong_rand_bytes(32),
                agent_namespace => AgentNamespace,
                agent_genesis_anchor => AgentAnchor,
                agent_instance_text => <<"human_user(test_agent).">>,
                mode => Mode, parser_version => 1,
                not_after_ms => min(
                                  SessionExpires,
                                  quod_time:now_ms() + 30000),
                goal_text => GoalText},
    {ok, Bytes} = quod_client_goal:encode(Request),
    {Bytes,
     quod_identity:sign(Bytes, quod_identity:key_term(KeyPair))}.

prolog_binary_literal(Bytes) ->
    iolist_to_binary(
      ["<<\"",
       [["\\x", io_lib:format("~2.16.0B", [Byte]), "\\"]
        || <<Byte>> <= Bytes],
       "\">>"]).

start_node(Name, Port, {Pub, Seed}, Ns, Genesis, Seeds,
           DirectoryAllowlist, Config) ->
    %% Peer nodes must load the beam being tested.  `code:get_path/0` also
    %% contains dependency and older build paths, so put this suite's exact
    %% Quod ebin first instead of relying on their incidental ordering.
    QuodEbin = filename:dirname(code:which(quod_simplex)),
    PeerPaths = [QuodEbin | lists:delete(QuodEbin, code:get_path())],
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io,
                            args => ["-pa" | PeerPaths]}),
    lists:foreach(
      fun(Module) ->
          {module, Module} = peer:call(
                               Peer, code, ensure_loaded, [Module]),
          QuodEbin = filename:dirname(
                       peer:call(Peer, code, which, [Module]))
      end, [quod_simplex, quod_scope_session, quod_ask]),
    true = peer:call(
             Peer, erlang, function_exported,
             [quod_simplex, start_link, 2]),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    Key = quod_identity:key_term({Pub, Seed}),
    Set = fun(K, V) -> ok = peer:call(Peer, application, set_env, [quod, K, V]) end,
    Set(listen_port, Port),
    Set(node_addr, {"127.0.0.1", Port}),
    Set(node_pubkey, Pub),
    Set(identity_key, Key),
    Set(identity_cert, quod_identity:mint_cert({Pub, Seed})),
    Set(effect_journal_data_dir,
        filename:join(
          ?config(priv_dir, Config),
          atom_to_list(Name) ++ "_effect_journal")),
    Set(foreign_log,
        #{cache_dir => filename:join(
                         ?config(priv_dir, Config),
                         atom_to_list(Name) ++ "_foreign_log")}),
    %% These peers do not run the production directory-advertisement loop for
    %% every synthetic namespace. Keep their explicit certified route fixtures
    %% alive for the whole suite so long-running protocol cases test the route,
    %% not fixture expiry.
    Set(directory, #{allowlist => DirectoryAllowlist,
                     ttl_ms => 600000, expire_tick_ms => 60000}),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    start_namespace(Peer, Pub, Ns, Genesis, Seeds, Config),
    Peer.

start_namespace(Peer, Pub, Ns, Genesis, Seeds, Config) ->
    DataDir = filename:join(
                ?config(priv_dir, Config),
                unicode:characters_to_list(
                  [atom_to_list(peer:call(Peer, erlang, node, [])),
                   "_", Ns])),
    Cfg = #{node_id => Pub, mode => create, role => member,
            data_dir => DataDir, seed_peers => Seeds,
            genesis_file => Genesis},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [Ns, Cfg]),
    ok.

start_root_namespace(Peer, Pub, Config) ->
    DataDir = filename:join(
                ?config(priv_dir, Config),
                unicode:characters_to_list(
                  [atom_to_list(peer:call(Peer, erlang, node, [])),
                   "_", ?ROOT_NS])),
    Content = #{namespace => ?ROOT_NS, mode => create,
                genesis_file => <<"ontologies/quod_root.pl">>,
                data_dir => list_to_binary(DataDir), seeds => []},
    {?ROOT_NS, Cfg0} = peer:call(
                         Peer, quod_app, build_ns_config, [Content]),
    {ok, _} = peer:call(
                Peer, quod_ns_sup, start_namespace,
                [?ROOT_NS, Cfg0#{node_id => Pub}]),
    ok.

start_brahms(Peer, Ns, SelfAddr, Seeds) ->
    {ok, _} = peer:call(Peer, quod_brahms, start_namespace,
                        [Ns, #{node_id => SelfAddr, seed_peers => Seeds}]),
    ok.

wait_ready(Peer, Ns, Goal) ->
    case peer:call(Peer, quod_prolog, prove, [Ns, Goal], 5000) of
        {error, rebuilding} -> timer:sleep(20), wait_ready(Peer, Ns, Goal);
        {ok, _, _} -> ok;
        Other -> ct:fail({not_ready, Ns, Other})
    end.

wait_scope_workers(_Peer, _Expected, 0) -> ct:fail(scope_worker_timeout);
wait_scope_workers(Peer, Expected, Retries) ->
    Stats = peer:call(Peer, quod_prolog, stats, [?NS]),
    case maps:get(scope_workers, Stats, undefined) of
        Expected -> ok;
        _ -> timer:sleep(10), wait_scope_workers(Peer, Expected, Retries - 1)
    end.

wrong_key_before(TargetPub) ->
    {Pub, _} = Key = quod_identity:generate(),
    case Pub < TargetPub of
        true -> Key;
        false -> wrong_key_before(TargetPub)
    end.

deep_failure_rules() ->
    DeepReason = lists:foldl(fun(_, Term) -> [Term] end,
                             deep_bottom, lists:seq(1, 70)),
    [[io_lib:format("deep_failure(~B) :- deep_failure(~B).~n", [N, N - 1])
      || N <- lists:seq(70, 1, -1)],
     "deep_failure(0) :- fail_with_reason(deep_bottom).\n",
     io_lib:format("deep_reason :- fail_with_reason(~p).~n", [DeepReason])].
