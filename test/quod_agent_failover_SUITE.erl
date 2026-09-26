-module(quod_agent_failover_SUITE).
-moduledoc """
Four real QUIC validators retain quorum after host VM loss or suspension.
Three surviving node actors observe that host; the ontology requires two reports
and chooses between two eligible destinations. Replacement custody is generated
by the ordinary recovery reaction, never installed by the test.
The former host returns from retained custody, either rebooted or still running,
without failback.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("quod_ledger.hrl").
-export([all/0, init_per_testcase/2, end_per_testcase/2,
         validator_host_loss_recovers_state/1,
         abrupt_host_loss_recovers_state/1,
         suspended_host_retires_stale_process/1,
         uncertain_claim_recovers_after_quorum_loss/1,
         uncertain_claim_recovers_after_target_restart/1]).
-export([hold_claim_admission/3, begin_uncertain_claim/1,
         release_claim_and_await_expiry/3]).
-export([bind_node/2, submit_node/1, await_goal/3, await_agent/3,
         resumed_work/4, restart_runtime/2, diagnostics/0,
         operation_diagnostics/2,
         await_node_principal/2, assert_old_key_fenced/2]).

-define(NS, <<"agent:failover">>).
-define(ROOT, <<"quod:root">>).

all() -> [validator_host_loss_recovers_state, abrupt_host_loss_recovers_state,
          suspended_host_retires_stale_process,
          uncertain_claim_recovers_after_quorum_loss,
          uncertain_claim_recovers_after_target_restart].

init_per_testcase(TestCase, Config0) ->
    Config = [{host_loss, TestCase} | Config0],
    put(failover_peers, []),
    try
        Pairs = lists:sort([quod_identity:generate() || _ <- lists:seq(1, 4)]),
        Nodes0 = [start_node(I, Pair, Config)
                  || {I, Pair} <- lists:zip(lists:seq(1, 4), Pairs)],
        learn_peers(Nodes0),
        [_Old0, Administrator0 | _] = Nodes0,
        RootAnchor = start_root(Administrator0, Nodes0),
        Nodes = [start_node_ontology(N) || N <- Nodes0],
        [Old, Administrator | _] = Nodes,
        Observers = tl(Nodes),
        Eligible = lists:sublist(Observers, 2),
        AgentAnchor = start_agent_ontology(Nodes, Observers, Eligible, Administrator),
        install_grants(Observers, Old, AgentAnchor),
        replicate_node_histories(Nodes),
        install_contacts(Nodes, Nodes, RootAnchor, AgentAnchor, Administrator),
        AgentRef = {agent_instance_ref, ?NS, AgentAnchor, actor},
        {ok, Blob} = quod_wire_term:encode_canonical(AgentRef),
        {ok, OldKey} = call(Old, quod_agent_vault, generate, [Blob]),
        OldRef = maps:get(reference, Old),
        committed(call(Administrator, ?MODULE, submit_node,
            [{node_authorized_goal, ?NS, AgentAnchor,
              {goal, {agent_hosted, actor, OldRef, 1, OldKey}}}])),
        {_InitialBinding, InitialHeight} = call(Old, ?MODULE, await_goal,
            [?NS, {agent_hosted, actor, OldRef, 1, OldKey}, 30000]),
        {OldRuntime, OldChild, _} = call(Old, ?MODULE, await_agent, [AgentRef, 1, 10000]),
        lists:foreach(fun(N) ->
            ok = call(N, quod_ct, await_applied, [?NS, InitialHeight, 30000]),
            ok = call(N, quod_runtime, await_revision,
                      [?NS, agent_observation, InitialHeight, 10000]),
            ?assertMatch(#{mode := live, collapses := 0}, call(N, quod_runtime, stats, [?NS]))
        end, Observers),
        [{nodes, Nodes}, {observers, Observers}, {eligible, Eligible},
         {agent_ref, AgentRef}, {root_anchor, RootAnchor}, {old_key, OldKey},
         {old_runtime, OldRuntime}, {old_child, OldChild} | Config]
    catch Class:Reason:Stack ->
        stop_peers(get(failover_peers)),
        erlang:raise(Class, Reason, Stack)
    end.

end_per_testcase(_TestCase, Config) ->
    stop_peers([maps:get(peer, N) || N <- ?config(nodes, Config)]),
    ok.

%% Keep all transports and hosted children alive. Suspend two of four target
%% consensus owners only AFTER the ordinary signed source claim commits. Proof
%% admission therefore succeeded with quorum; the fault tests delivery custody.
uncertain_claim_recovers_after_quorum_loss(Config) ->
    uncertain_claim_recovers(Config, false).

uncertain_claim_recovers_after_target_restart(Config) ->
    uncertain_claim_recovers(Config, true).

uncertain_claim_recovers(Config, Restart) ->
    ct:timetrap({minutes, 3}),
    [A, B, C, D] = Nodes = ?config(nodes, Config),
    {agent_instance_ref, ?NS, Anchor, actor} = ?config(agent_ref, Config),
    Goal = {node_authorized_goal, ?NS, Anchor, {record_delivery, durable_delivery}},
    {Prolog, Token, Tx, ClaimRef, OperationRef, Bytes, Signature} =
        call(B, ?MODULE, begin_uncertain_claim, [Goal]),
    SourceNs = maps:get(node_namespace, B),
    ?assertMatch({ok, #{status := claimed}}, call(B, quod_prolog, outcome, [OperationRef])),
    Held = [{N, call(N, quod_reg, where, [{quod_simplex, ?NS}])} || N <- [A, D]],
    try
        lists:foreach(fun({N, Owner}) -> ok = call(N, sys, suspend, [Owner]) end, Held),
        TargetRef = {transaction, ?NS, Anchor, Tx},
        ok = call(B, ?MODULE, release_claim_and_await_expiry, [Prolog, Token, Tx]),
        ?assertMatch({ok, #{status := pending}}, call(B, quod_prolog, outcome, [TargetRef])),
        ?assertMatch({ok, #{operation_state := unresolved}},
                     call(B, quod_prolog, outcome, [OperationRef])),
        %% Fixture caller TTL is shorter than the observed custody deadline.
        ?assertEqual(0, maps:get(parked, call(B, quod_prolog, stats, [?NS]))),
        case Restart of
            true ->
                %% Drop every target's volatile proposals/relay mailboxes while
                %% retaining all four ledgers. Otherwise a late old proposal can
                %% complete even on the broken implementation. Source ontology
                %% owners and their original committed claim stay running.
                lists:foreach(fun(N) ->
                    ok = call(N, quod_ns_sup, stop_namespace, [?NS])
                end, [A, D, B, C]),
                lists:foreach(fun(N) ->
                    start_namespace(N, ?NS, #{mode => join, genesis_hash => Anchor,
                        seed_peers => [maps:get(endpoint, Other) || Other <- Nodes, Other =/= N]})
                end, Nodes);
            false ->
                lists:foreach(fun({N, Owner}) -> ok = call(N, sys, resume, [Owner]) end, Held)
        end,
        %% Only real consensus/application progress may wake the existing
        %% source coordinator. The test never resubmits the signed goal/claim.
        #{operation_state := terminal} =
            call(B, quod_ct, await_operation_complete, [SourceNs, OperationRef, 60000]),
        ?assertMatch({ok, _, {operation_outcome, #{operation_state := terminal},
                             #{status := completed}}},
            call(B, quod_client_goal_ingress, resolve_operation, [Bytes, Signature])),
        {ok, #{status := committed, height := Height}} =
            call(B, quod_prolog, outcome, [TargetRef]),
        lists:foreach(fun(N) ->
            Deadline = quod_time:mono_ms() + 30000,
            ok = call(N, quod_ct, await_applied, [?NS, Height, 30000]),
            {Bindings, ObservedHeight} = call(N, ?MODULE, await_goal,
                [?NS, {findall, {'X'}, {delivered, {'X'}}, [durable_delivery]},
                 max(0, Deadline - quod_time:mono_ms())]),
            ?assert(is_map(Bindings)),
            ?assert(ObservedHeight >= Height)
        end, Nodes),
        ?assertMatch({ok, #{status := committed}}, call(B, quod_prolog, outcome, [ClaimRef])),
        ct:pal("Original operation completed after custody expiry; restart=~p, target height=~p",
               [Restart, Height])
    catch Class:Reason:Stack ->
        ct:pal("Original claim recovery: ~p", [
            catch call(B, ?MODULE, operation_diagnostics, [SourceNs, OperationRef])]),
        lists:foreach(fun(N) ->
            ct:pal("Node ~p recovery state: ~p", [maps:get(node_namespace, N),
                catch call(N, ?MODULE, diagnostics, [])])
        end, Nodes),
        erlang:raise(Class, Reason, Stack)
    after
        lists:foreach(fun({N, Owner}) -> catch call(N, sys, resume, [Owner]) end, Held),
        catch call(B, erlang, send, [Prolog, {release_claim, Token}]),
        catch call(B, sys, remove, [Prolog, Token])
    end.

begin_uncertain_claim(Goal) ->
    Prolog = quod_reg:where({quod_prolog, ?NS}),
    Token = make_ref(), Parent = self(),
    ok = sys:install(Prolog, {Token, fun ?MODULE:hold_claim_admission/3, {Parent, Token}}),
    {Numbered, _, _} = erlog_int:term_instance(Goal, 0),
    {ok, Bytes, Signature} = quod_node_actor:signed_goal(execute, Numbered,
        crypto:strong_rand_bytes(32), quod_time:now_ms() + 30000),
    spawn(fun() -> Parent ! {claim_submission_result, Token,
                            quod_client_goal_ingress:submit(Bytes, Signature)} end),
    receive
        {claim_held, Token, Tx, ClaimRef, OperationRef} ->
            {Prolog, Token, Tx, ClaimRef, OperationRef, Bytes, Signature};
        {claim_submission_result, Token, Result} ->
            error({submission_ended_before_claim_gate, Result})
    after 15000 -> error(claim_not_admitted)
    end.

hold_claim_admission({Parent, Token},
  {in, {'$gen_call', _, {submit_role,
    #transaction{tx_id = Tx, role = {remote_application, ClaimRef, OperationRef, _}}, _, _}}}, _) ->
    Parent ! {claim_held, Token, Tx, ClaimRef, OperationRef},
    receive {release_claim, Token} -> done
    after 15000 -> error(claim_gate_not_released)
    end;
hold_claim_admission(State, _, _) -> State.

release_claim_and_await_expiry(Prolog, Token, Tx) ->
    Owner = quod_reg:where({quod_simplex, ?NS}),
    Pattern = {quod_simplex, complete_custody, 3},
    erlang:trace_pattern(Pattern,
        [{['_', {error, not_in_charge, unavailable}, '_'], [], [{return_trace}]}], [local]),
    erlang:trace(Owner, true, [call, {tracer, self()}]),
    try
        Prolog ! {release_claim, Token},
        receive
            {trace, Owner, call, {quod_simplex, complete_custody, [Id, _, State]}} ->
                [{Id, _, {submit, _, _, Canonical}, _, _, _}] =
                    [Row || Row <- quod_simplex:test_custody(State), element(1, Row) =:= Id],
                {ok, #{tx_id := Tx}} = quod_transaction:decode_submission_metadata(Canonical)
        after 45000 -> error(custody_did_not_expire_without_quorum)
        end,
        receive {trace, Owner, return_from, Pattern, _} -> ok
        after 1000 -> error(custody_expiry_did_not_complete) end,
        {_, Current} = sys:get_state(Owner),
        ?assertEqual([], quod_simplex:test_custody(Current)),
        ok
    after
        erlang:trace(Owner, false, [call]),
        erlang:trace_pattern(Pattern, false, [local])
    end.

abrupt_host_loss_recovers_state(Config) ->
    validator_host_loss_recovers_state(Config).

suspended_host_retires_stale_process(Config) ->
    validator_host_loss_recovers_state(Config).

validator_host_loss_recovers_state(Config) ->
    ct:timetrap({minutes, 3}),
    try exercise_host_loss(Config)
    catch Class:Reason:Stack ->
        lists:foreach(fun(N) ->
            Snapshot = catch call(N, ?MODULE, diagnostics, []),
            ct:pal("Survivor ~p diagnostics: ~p", [maps:get(node_namespace, N), Snapshot])
        end, tl(?config(nodes, Config))),
        erlang:raise(Class, Reason, Stack)
    end.

exercise_host_loss(Config) ->
    [Old | Survivors] = ?config(nodes, Config),
    {agent_instance_ref, ?NS, Anchor, actor} = ?config(agent_ref, Config),
    lists:foreach(fun(N) ->
        ?assertMatch(#{role := validator}, call(N, quod_simplex, status, [?NS]))
    end, [Old | Survivors]),
    lists:foreach(fun(N) ->
        %% These vaults have not prepared or received an agent private key.
        ?assertEqual({ok, []}, call(N, file, list_dir, [maps:get(vault_dir, N)]))
    end, ?config(eligible, Config)),
    [Administrator | _] = Survivors,
    ?assertMatch({ok, _, {normalized, {failed, _}}},
        call(Administrator, ?MODULE, submit_node,
          [{node_authorized_goal, ?NS, Anchor, {assertz, unauthorized_recovery}}])),
    Fault = stop_host(Old, Config),
    ct:pal("Host fault accepted at ~p", [quod_time:mono_ms()]),
    try exercise_recovery(Config, Fault)
    after
        %% Closing the controller's stdin resumes its exact peer on failure.
        case Fault of stopped -> ok; {suspended, P} -> catch port_close(P) end
    end.

exercise_recovery(Config, Fault) ->
    [Old | Survivors] = ?config(nodes, Config),
    AgentRef = {agent_instance_ref, ?NS, Anchor, actor} = ?config(agent_ref, Config),
    OldKey = ?config(old_key, Config),
    [Administrator | _] = Survivors,
    {#{'Host' := NewHost, 'Key' := NewKey}, RecoveryHeight} =
        call(Administrator, ?MODULE, await_goal,
             [?NS, {agent_hosted, actor, {'Host'}, 2, {'Key'}}, 90000]),
    ct:pal("Committed epoch 2 at height ~p, time ~p", [RecoveryHeight, quod_time:mono_ms()]),
    [Destination] = [N || N <- ?config(eligible, Config), maps:get(reference, N) =:= NewHost],
    ?assertNotEqual(OldKey, NewKey),
    {Runtime, Child, #{public_key := NewKey}} =
        call(Destination, ?MODULE, await_agent, [AgentRef, 2, 10000]),
    ?assertNotEqual(?config(old_runtime, Config), Runtime),
    ?assertNotEqual(?config(old_child, Config), Child),
    assert_replicated(Survivors, RecoveryHeight, NewHost, NewKey, OldKey, []),
    WorkHeight = call(Destination, ?MODULE, resumed_work,
                      [AgentRef, Runtime, Child, after_recovery]),
    assert_replicated(Survivors, WorkHeight, NewHost, NewKey, OldKey, [after_recovery]),
    {NextRuntime, NextChild, #{public_key := NewKey}} =
        call(Destination, ?MODULE, restart_runtime, [AgentRef, Runtime]),
    ?assertNotEqual(Runtime, NextRuntime),
    ?assertNotEqual(Child, NextChild),
    RestartHeight = call(Destination, ?MODULE, resumed_work,
                         [AgentRef, NextRuntime, NextChild, after_runtime_restart]),
    assert_replicated(Survivors, RestartHeight, NewHost, NewKey, OldKey,
                      [after_recovery, after_runtime_restart]),
    ct:pal("Replacement work committed before host return at ~p", [quod_time:mono_ms()]),
    Returned = case Fault of
        stopped -> boot_node(Old);
        {suspended, Port} ->
            ok = restore_host({suspended, Port}),
            Old
    end,
    try
        case Fault of
            stopped -> resume_host(Returned, Survivors, ?config(root_anchor, Config), Anchor);
            {suspended, _} -> ok
        end,
        assert_replicated([Returned], RestartHeight, NewHost, NewKey, OldKey,
                          [after_recovery, after_runtime_restart]),
        ok = call(Returned, quod_runtime, await_revision,
                  [?NS, agent_hosting, RestartHeight, 10000]),
        {_, ReturnedChildren} = call(Returned, quod_runtime, agents, [?NS]),
        ?assertEqual([], [B || #{binding := #{reference := R} = B} <- ReturnedChildren,
                              R =:= AgentRef]),
        case Fault of
            {suspended, _} ->
                %% The same VM and runtime must retire their surviving old child
                %% when committed state catches up; no test-triggered restart.
                {ReturnedRuntime, _} = call(Returned, quod_runtime, agents, [?NS]),
                ?assertEqual(?config(old_runtime, Config), ReturnedRuntime),
                ?assertNot(call(Returned, erlang, is_process_alive, [?config(old_child, Config)]));
            stopped -> ok
        end,
        ok = call(Returned, ?MODULE, assert_old_key_fenced, [AgentRef, OldKey]),
        FinalHeight = call(Destination, ?MODULE, resumed_work,
                          [AgentRef, NextRuntime, NextChild, after_old_host_return]),
        All = [Returned | Survivors],
        assert_replicated(All, FinalHeight, NewHost, NewKey, OldKey, work_values()),
        lists:foreach(fun(N) ->
            ok = call(N, quod_runtime, await_revision,
                      [?NS, agent_hosting, FinalHeight, 10000]),
            ?assertMatch(#{mode := live, collapses := 0, reconcile_failures := 0},
                         call(N, quod_runtime, stats, [?NS])),
            ?assertMatch(#{role := validator}, call(N, quod_simplex, status, [?NS])),
            {_, Children} = call(N, quod_runtime, agents, [?NS]),
            Hosted = [B || #{binding := #{reference := R} = B} <- Children, R =:= AgentRef],
            Expected = case maps:get(reference, N) =:= NewHost of true -> 1; false -> 0 end,
            ?assertEqual(Expected, length(Hosted))
        end, All)
    after stop_peers([maps:get(peer, Returned)]) end.

resume_host(Returned, Survivors = [Administrator | _], RootAnchor, AgentAnchor) ->
    Seeds = [maps:get(endpoint, N) || N <- Survivors],
    resume_namespace(Returned, ?ROOT, RootAnchor, [maps:get(endpoint, Administrator)]),
    learn_peers([Returned | Survivors]),
    %% The persisted pointer restores the own node actor; do not bind it again.
    ok = call(Returned, ?MODULE, await_node_principal,
              [maps:get(reference, Returned), 10000]),
    lists:foreach(fun(N) ->
        resume_namespace(Returned, maps:get(node_namespace, N), maps:get(node_anchor, N),
                         [maps:get(endpoint, N)])
    end, Survivors),
    resume_namespace(Returned, ?NS, AgentAnchor, Seeds),
    {ok, _} = call(Returned, quod_brahms, start_namespace,
                  [?NS, #{node_id => maps:get(endpoint, Returned), seed_peers => Seeds}]),
    install_contacts([Returned], [Returned | Survivors], RootAnchor, AgentAnchor, Administrator).

resume_namespace(N, Ns, Anchor, Seeds) ->
    %% Fixture namespaces have no committed hosting intent. Require their old
    %% ledgers explicitly; this must not pass by founding or downloading anew.
    {ok, Resume} = call(N, quod_ontology, prepare_local_resume,
                       [Ns, Anchor, maps:get(data_dir, N)]),
    start_namespace(N, Ns, Resume#{seed_peers => Seeds}),
    ?assertEqual(Anchor, call(N, quod_simplex, genesis_hash, [Ns])).

assert_replicated(Nodes, Height, Host, Key, OldKey, Work) ->
    Goal = conjunction([
        {findall, {host, {'H'}, {'E'}, {'K'}},
            {agent_host, actor, {'H'}, {'E'}, {'K'}}, [{host, Host, 2, Key}]},
        {findall, {'K'}, {agent_key, actor, {'K'}, active}, [Key]},
        {findall, {'K'}, {agent_key, actor, {'K'}, revoked}, [OldKey]},
        {agent_domain_state, actor, before_loss},
        {findall, {'Value'}, {recovered_work, {'Value'}}, Work},
        {'\\+', unauthorized_recovery},
        {'\\+', {agent_recovery_round, actor, {'_'}, {'_'}, {'_'}}},
        {'\\+', {agent_failure_report, actor, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}},
        {'\\+', {agent_candidate_key, actor, {'_'}, {'_'}, {'_'}, {'_'}}}]),
    lists:foreach(fun(N) ->
        Deadline = quod_time:mono_ms() + 30000,
        ok = call(N, quod_ct, await_applied, [?NS, Height, 30000]),
        %% Reaching the applied height does not finish the replay handshake.
        %% Observe the existing readiness edge within the same allowance.
        {Bindings, ObservedHeight} = call(N, ?MODULE, await_goal,
            [?NS, Goal, max(0, Deadline - quod_time:mono_ms())]),
        ?assert(is_map(Bindings)),
        ?assert(ObservedHeight >= Height)
    end, Nodes).

stop_host(Old, Config) ->
    stop_host(Old, ?config(host_loss, Config), Config).

stop_host(#{peer := Peer}, validator_host_loss_recovers_state, _Config) ->
    ok = peer:stop(Peer),
    stopped;
stop_host(#{peer := Peer}, abrupt_host_loss_recovers_state, _Config) ->
    Monitor = monitor(process, Peer),
    %% No application shutdown, output flush, port cleanup or pending I/O drain.
    ok = peer:cast(Peer, erlang, halt, [137, [{flush, false}]]),
    receive
        {'DOWN', Monitor, process, Peer, {exit_status, 137}} -> stopped;
        {'DOWN', Monitor, process, Peer, Reason} -> ct:fail({unexpected_host_exit, Reason})
    after 10000 -> ct:fail(host_did_not_exit)
    end;
stop_host(Old, suspended_host_retires_stale_process, Config) ->
    Python = os:find_executable("python3"),
    Script = filename:join(?config(data_dir, Config), "suspend_peer.py"),
    Pid = call(Old, os, getpid, []),
    Port = open_port({spawn_executable, Python},
                     [{args, [Script, Pid]}, binary, {line, 1024}, exit_status, stderr_to_stdout]),
    try
        ok = fault_reply(Port, <<"stop_accepted">>, quod_time:mono_ms() + 10000, []),
        {suspended, Port}
    catch Class:Reason:Stack ->
        catch port_close(Port),
        erlang:raise(Class, Reason, Stack)
    end.

restore_host({suspended, Port}) ->
    true = port_command(Port, <<"resume\n">>),
    try
        ok = fault_reply(Port, <<"resumed">>, quod_time:mono_ms() + 10000, []),
        receive {Port, {exit_status, 0}} -> ok;
                {Port, Exit} -> error({host_resumption_exit, Exit})
        after 10000 -> error(host_resumption_exit_timeout)
        end
    after catch port_close(Port) end.

fault_reply(Port, Expected, Deadline, Lines) ->
    receive
        {Port, {data, {eol, Expected}}} -> ok;
        {Port, {data, {_, Line}}} -> fault_reply(Port, Expected, Deadline, [Line | Lines]);
        {Port, Exit} -> error({fault_controller_failed, Expected, Exit, lists:reverse(Lines)})
    after max(0, Deadline - quod_time:mono_ms()) ->
        error({fault_controller_timeout, Expected, lists:reverse(Lines)})
    end.

start_node(Index, Pair = {Pub, _}, Config) ->
    {ok, Socket} = gen_udp:open(0),
    {ok, Port} = inet:port(Socket),
    ok = gen_udp:close(Socket),
    Dir = filename:join([?config(priv_dir, Config), atom_to_list(?config(host_loss, Config)),
                         "peer-" ++ integer_to_list(Index)]),
    Unlock = filename:join(Dir, "vault-unlock"),
    ok = quod_file:write_atomic(Unlock, crypto:strong_rand_bytes(32), 8#600),
    VaultDir = filename:join(Dir, "keys"),
    Name = list_to_atom("agent_failover_" ++ integer_to_list(Port)),
    Identity = #{pubkey => Pub, key => quod_identity:key_term(Pair)},
    N = #{peer_name => Name, public_key => Pub, identity => Identity,
          endpoint => {"127.0.0.1", Port}, data_dir => Dir, vault_dir => VaultDir,
          node_namespace => <<"failover-node-", (integer_to_binary(Index))/binary>>},
    Env = [{listen_port, Port}, {metrics_port, 0}, {node_addr, maps:get(endpoint, N)},
           {node_pubkey, Pub}, {identity_key, maps:get(key, Identity)},
           {identity_cert, quod_identity:mint_cert(Pair)},
           {identity_dir, filename:join(Dir, "identity")}, {content_data_dir, Dir},
           {simplex_delta_ms, 4000}, {effect_journal_data_dir, Dir},
           {foreign_log, #{cache_dir => filename:join(Dir, "foreign-history")}},
           {directory, #{ttl_ms => 600000, expire_tick_ms => 60000}},
           {agent_vault, #{directory => VaultDir, unlock_file => Unlock}}],
    boot_node(N#{boot_env => Env}).

boot_node(N0 = #{peer_name := Name, boot_env := Env, data_dir := Dir}) ->
    Ebin = filename:dirname(code:which(quod_simplex)),
    Paths = [Ebin | lists:delete(Ebin, code:get_path())],
    {ok, Peer, _} = peer:start(#{name => Name, connection => standard_io, peer_down => crash,
                                args => ["+S", "2:2", "-pa" | Paths]}),
    Peers = case get(failover_peers) of undefined -> []; Existing -> Existing end,
    put(failover_peers, [Peer | Peers]),
    N = N0#{peer => Peer},
    try
        true = call(N, os, putenv, ["XDG_CACHE_HOME", filename:join(Dir, "cache")]),
        ok = call(N, logger, set_primary_config, [level, warning]),
        ok = call(N, application, load, [quod]),
        lists:foreach(fun({K, V}) -> ok = call(N, application, set_env, [quod, K, V]) end, Env),
        {ok, _} = call(N, application, ensure_all_started, [quod]),
        {module, ?MODULE} = call(N, code, ensure_loaded, [?MODULE]),
        Ebin = filename:dirname(call(N, code, which, [quod_simplex])),
        N
    catch Class:Reason:Stack ->
        stop_peers([Peer]),
        erlang:raise(Class, Reason, Stack)
    end.

learn_peers(Nodes) ->
    lists:foreach(fun(N) ->
        lists:foreach(fun(Other) ->
            ok = call(N, quod_quic, learn,
                      [maps:get(public_key, Other), maps:get(endpoint, Other)])
        end, Nodes -- [N])
    end, Nodes).

start_root(Founder, Nodes) ->
    Source = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    start_namespace(Founder, ?ROOT,
        #{mode => create, genesis_file => Source,
          external_predicate_modules => [quod_directory_predicates, quod_ontology_predicates]}),
    Anchor = call(Founder, quod_simplex, genesis_hash, [?ROOT]),
    lists:foreach(fun(N) ->
        start_namespace(N, ?ROOT, join_config(Founder, Anchor))
    end, Nodes -- [Founder]),
    lists:foreach(fun(N) -> ok = call(N, quod_ct, await_applied, [?ROOT, 1, 30000]) end, Nodes),
    Anchor.

start_node_ontology(N = #{node_namespace := Ns, public_key := Pub}) ->
    {ok, Execution} = erlog_io:read_file(filename:join(code:priv_dir(quod),
                                                     "ontologies/node_execution.pl")),
    Principal = {agent_instance_ref, Ns, {'_'}, physical_node},
    SigningPrincipal = {agent_instance_ref, Ns, {'NodeAnchor'}, physical_node},
    SigningRead = {'::', ?NS,
        {',', {agent_hosted, actor, SigningPrincipal, {'Epoch'}, {'Key'}},
         {sign_agent_request, {'Request'}, {'Signature'}}}},
    Terms = Execution ++ [
        {instance_of, node, physical_node}, {agent_key, physical_node, Pub, active},
        {can_invoke, {node_authorized_goal, ?NS, {'_'}, {'_'}}, Principal, {'_'}, Ns},
        {can_invoke, {assertz, {can_execute_for, ?NS, {'_'}, {'_'}}}, Principal, {'_'}, Ns},
        {can_invoke, SigningRead, SigningPrincipal, {'_'}, Ns}],
    start_namespace(N, Ns, #{mode => create, genesis_diff => quod_prolog:terms_to_diff(Terms)}),
    ok = call(N, quod_ct, await_applied, [Ns, 1, 10000]),
    Anchor = call(N, quod_simplex, genesis_hash, [Ns]),
    {ok, PrincipalValue} = call(N, ?MODULE, bind_node, [Ns, Anchor]),
    Ref = {agent_instance_ref, Ns, Anchor, physical_node},
    {ok, PrincipalValue} = call(N, quod_node_actor, principal, []),
    N#{reference => Ref, node_anchor => Anchor}.

start_agent_ontology([Founder | Others], Observers, Eligible, Administrator) ->
    {ok, Instance} = erlog_io:read_file(filename:join(code:priv_dir(quod),
                                                    "ontologies/agent_instance.pl")),
    {ok, Recovery} = erlog_io:read_file(filename:join(code:priv_dir(quod),
                                                    "ontologies/agent_recovery_policy.pl")),
    Terms = Instance ++ Recovery ++ agent_policy(Founder, Observers, Eligible, Administrator),
    Committee = [{maps:get(public_key, N), Host, Port}
                 || N <- Others, {Host, Port} <- [maps:get(endpoint, N)]],
    start_namespace(Founder, ?NS,
        #{mode => create, committee => Committee,
          genesis_diff => quod_prolog:terms_to_diff(Terms),
          external_predicate_modules => [quod_agent_predicates]}),
    Anchor = call(Founder, quod_simplex, genesis_hash, [?NS]),
    lists:foreach(fun(N) -> start_namespace(N, ?NS, join_config(Founder, Anchor)) end, Others),
    lists:foreach(fun(N) ->
        ok = call(N, quod_ct, await_applied, [?NS, 1, 30000]),
        {ok, _} = call(N, quod_brahms, start_namespace,
          [?NS, #{node_id => maps:get(endpoint, N), seed_peers => [maps:get(endpoint, Founder)]}])
    end, [Founder | Others]),
    Anchor.

agent_policy(Old, Observers, Eligible, Administrator) ->
    OldRef = maps:get(reference, Old), AdminRef = maps:get(reference, Administrator),
    Goal = {'Goal'}, Principal = {'Principal'}, Value = {'Value'},
    Guarded = {',', {current_ontology_identity, ?NS, {'_'}}, {call, Goal}},
    Signing = {',', {agent_hosted, actor, Principal, {'Epoch'}, {'Key'}},
               {sign_agent_request, {'Request'}, {'Signature'}}},
    ObservationRights = [{agent_recovery_observer, actor, maps:get(reference, N)} || N <- Observers],
    Placement = lists:append([[{eligible_agent_host, actor, maps:get(reference, N)},
                              {agent_host_rank, actor, maps:get(reference, N), Rank}]
                             || {N, Rank} <- lists:zip(Eligible, [1, 2])]),
    SigningRights = [begin
        {ok, Text} = quod_client_goal_parser:format({record_recovered_work, V}),
        Request = {agent_goal_v1, {'_'}, {agent_instance_ref, ?NS, {'_'}, actor},
                   {'_'}, {'_'}, {'_'}, {'_'}, execute, 2, Text},
        {':-', {can_request_agent_signature, Principal, actor, Request},
         {eligible_agent_host, actor, Principal}}
    end || V <- work_values()],
    ObservationRights ++ Placement ++ SigningRights ++ [
        {agent_recovery_threshold, actor, 2}, {agent_domain_state, actor, before_loss},
        {can_assign_agent_host, AdminRef, actor, none, 0, OldRef, {'_'}},
        {':-', {can_invoke, Guarded, Principal, {'_'}, ?NS},
         {',', {agent_recovery_observer, actor, Principal}, {failover_entry, Goal}}},
        {failover_entry, {report_agent_observation, actor, OldRef, 1,
                          {'_'}, {'_'}, {'_'}, {'_'}}},
        {failover_entry, {report_agent_observation_with_custody, actor, OldRef, 1,
                          {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}},
        {failover_entry, {goal, {agent_hosted, actor, OldRef, 1, {'_'}}}},
        {failover_entry, {trigger_event, {resume_work, Value}}},
        {failover_entry, {record_delivery, durable_delivery}},
        {':-', {record_delivery, Value}, {assertz, {delivered, Value}}},
        {':-', {can_invoke, Signing, Principal, {'_'}, ?NS},
         {agent_hosted, actor, Principal, {'Epoch'}, {'Key'}}},
        {':-', {can_invoke, {record_recovered_work, Value},
                 {agent_instance_ref, ?NS, {'Anchor'}, actor}, {'_'}, ?NS},
         {current_ontology_identity, ?NS, {'Anchor'}}},
        {react_on, {agent, actor}, {resume_work, Value},
         {submit_agent_goal, actor, execute, {record_recovered_work, Value}, 15000}},
        {':-', {record_recovered_work, Value}, conjunction([
            {agent_domain_state, actor, before_loss},
            {'\\+', {recovered_work, Value}}, {assertz, {recovered_work, Value}}])}].

install_grants(Observers, Old, Anchor) ->
    OldRef = maps:get(reference, Old),
    [Administrator | _] = Observers,
    lists:foreach(fun(N) ->
        Reports = [{report_agent_observation, actor, OldRef, 1, {'_'}, {'_'}, {'_'}, {'_'}},
                   {report_agent_observation_with_custody, actor, OldRef, 1,
                    {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}],
        Initial = case N =:= Administrator of
            true -> [{goal, {agent_hosted, actor, OldRef, 1, {'_'}}}]; false -> []
        end,
        Work = [{record_delivery, durable_delivery} |
                [{trigger_event, {resume_work, V}} || V <- work_values()]],
        lists:foreach(fun(G) ->
            committed(call(N, ?MODULE, submit_node,
                           [{assertz, {can_execute_for, ?NS, Anchor, G}}]))
        end, Reports ++ Initial ++ Work)
    end, Observers).

replicate_node_histories(Nodes) ->
    lists:foreach(fun(Source) ->
        Ns = maps:get(node_namespace, Source), Anchor = maps:get(node_anchor, Source),
        Height = call(Source, quod_prolog, applied, [Ns]),
        lists:foreach(fun(N) ->
            start_namespace(N, Ns, join_config(Source, Anchor)),
            ok = call(N, quod_ct, await_applied, [Ns, Height, 30000])
        end, Nodes -- [Source])
    end, Nodes).

install_contacts(Recipients, Advertisers, RootAnchor, AgentAnchor, RootFounder) ->
    lists:foreach(fun(N) ->
        lists:foreach(fun(Advertiser) ->
            Ref = maps:get(reference, Advertiser),
            {ok, Blob} = quod_wire_term:encode_canonical(Ref),
            RootRole = case Advertiser =:= RootFounder of true -> validator; false -> observer end,
            Hosted = [{?NS, AgentAnchor, validator, node}, {?ROOT, RootAnchor, RootRole, system},
                      {maps:get(node_namespace, Advertiser), maps:get(node_anchor, Advertiser),
                       validator, node}],
            {ok, _} = call(N, quod_directory, install_generation,
                [#{author => {node_actor, Blob}, node_key => maps:get(public_key, Advertiser),
                   endpoint => maps:get(endpoint, Advertiser), epoch => 1, generation => 1,
                   page => 0, last => true, hosted => lists:sort(Hosted)}])
        end, Advertisers)
    end, Recipients).

start_namespace(N, Ns, Extra) ->
    Config = maps:merge(#{node_id => maps:get(public_key, N), identity => maps:get(identity, N),
                         data_dir => maps:get(data_dir, N)}, Extra),
    {ok, _} = call(N, quod_ns_sup, start_namespace, [Ns, Config]),
    ok.

join_config(Source, Anchor) ->
    #{mode => join, genesis_hash => Anchor, seed_peers => [maps:get(endpoint, Source)]}.

%% The following helpers run on a peer through its stdio control connection.
%% Every wait subscribes before its snapshot and advances only on owner events.
bind_node(Ns, Anchor) ->
    true = quod_reg:subscribe({node_actor, node}),
    try
        {ok, Principal} = quod_node_actor:bind(Ns, Anchor, <<"physical_node.">>, 2),
        await_principal(Principal, quod_time:mono_ms() + 10000),
        {ok, Principal}
    after quod_reg:unsubscribe({node_actor, node}) end.

await_node_principal(Ref, Timeout) ->
    {ok, Blob} = quod_wire_term:encode_canonical(Ref),
    true = quod_reg:subscribe({node_actor, node}),
    try await_principal({agent, Blob}, quod_time:mono_ms() + Timeout)
    after quod_reg:unsubscribe({node_actor, node}) end.

await_principal(Principal, Deadline) ->
    case quod_node_actor:principal() of
        {ok, Principal} -> ok;
        _ -> receive
            {node_actor_installed, _, _} -> await_principal(Principal, Deadline)
        after max(0, Deadline - quod_time:mono_ms()) -> error(node_principal_not_installed)
        end
    end.

submit_node(Goal) ->
    {Numbered, _, _} = erlog_int:term_instance(Goal, 0),
    {ok, Bytes, Signature} = quod_node_actor:signed_goal(execute, Numbered,
        crypto:strong_rand_bytes(32), quod_time:now_ms() + 30000),
    case quod_client_goal_ingress:submit(Bytes, Signature) of
        {ok, _, {normalized, {pending, {operation, Ns, _, _, _} = Ref}}} ->
            logger:warning("Pending operation evidence: ~p", [operation_diagnostics(Ns, Ref)]),
            %% Observe this exact request's durable completion. Its signed
            %% expiry is unchanged; neither this helper nor the runtime submits
            %% it again or creates a replacement operation.
            try quod_ct:await_operation_complete(Ns, Ref, 30000)
            catch Class:Reason:Stack ->
                logger:warning("Unresolved operation evidence: ~p", [operation_diagnostics(Ns, Ref)]),
                erlang:raise(Class, Reason, Stack)
            end,
            quod_client_goal_ingress:resolve_operation(Bytes, Signature);
        Result -> Result
    end.

diagnostics() ->
    [#{namespace => Ns, proof => quod_prolog:stats(Ns),
       consensus => quod_simplex:stats(Ns), runtime => quod_runtime:stats(Ns),
       status => maps:with([role, committed, approved, last_applied, recovery,
                            progress_phase, progress_quorum_ready, proposal_open],
                           quod_simplex:status(Ns)),
       progress => progress_diagnostics(Ns)}
     || Ns <- quod_prolog:namespaces()].

operation_diagnostics(Ns, Ref) ->
    {_, State} = sys:get_state(quod_reg:where({quod_simplex, Ns})),
    Recovery = maps:get(Ref, quod_simplex:test_operation_recoveries(State), #{}),
    Targets = maps:get(target_ref, Recovery, []),
    #{outcome => quod_prolog:local_outcome(Ns, Ref),
      recovery => maps:with([claim_state, status, slot, target_ref, results], Recovery),
      worker => case maps:get(pid, Recovery, undefined) of
          Pid when is_pid(Pid) -> process_info(Pid,
              [current_function, current_stacktrace, message_queue_len]);
          _ -> none
      end,
      targets => [{T, quod_prolog:local_outcome(element(2, T), T)} || T <- Targets]}.

progress_diagnostics(Ns) ->
    {_, State} = sys:get_state(quod_reg:where({quod_simplex, Ns})),
    #{head => quod_simplex:test_progress(State),
      position => quod_simplex:test_protocol_position(State),
      pools => quod_simplex:test_engine_pool_sizes(State)}.

await_goal(Ns, Goal, Timeout) ->
    true = quod_reg:subscribe({runtime, Ns}),
    Owner = quod_reg:where({quod_prolog, Ns}),
    Monitor = monitor(process, Owner),
    try await_goal_read(Ns, Owner, Monitor, Goal, quod_time:mono_ms() + Timeout)
    after demonitor(Monitor, [flush]), quod_reg:unsubscribe({runtime, Ns}) end.

await_goal_read(Ns, Owner, Monitor, Goal, Deadline) ->
    case quod_prolog:prove_ro(Ns, Goal) of
        {ok, [Bindings], Height} -> {Bindings, Height};
        {fail, _} -> await_goal_edge(Ns, Owner, Monitor, Goal, Deadline);
        {error, rebuilding} -> await_goal_edge(Ns, Owner, Monitor, Goal, Deadline);
        Other -> error({unexpected_goal_result, Ns, Goal, Other})
    end.

await_goal_edge(Ns, Owner, Monitor, Goal, Deadline) ->
    receive
        {projection_advanced, Owner, _} -> await_goal_read(Ns, Owner, Monitor, Goal, Deadline);
        {replay_ready, _, _} -> await_goal_read(Ns, Owner, Monitor, Goal, Deadline);
        {'DOWN', Monitor, process, Owner, Why} -> error({proof_owner_down, Why})
    after max(0, Deadline - quod_time:mono_ms()) ->
        error({goal_not_reached, Goal, quod_runtime:stats(Ns), quod_simplex:stats(Ns)})
    end.

await_agent(Ref = {agent_instance_ref, Ns, _, _}, Epoch, Timeout) ->
    true = quod_reg:subscribe({agent_hosting, Ns}),
    try
        {Owner, Children} = quod_runtime:agents(Ns),
        case [{Owner, Pid, B} || #{pid := Pid, binding := #{reference := R, epoch := E} = B}
                                   <- Children, R =:= Ref, E =:= Epoch] of
            [Installed] -> Installed;
            [] -> receive
                {agent_installed, Owner, Child, #{reference := Ref, epoch := Epoch} = B, _} ->
                    {Owner, Child, B}
            after Timeout -> error({agent_not_installed, Ref, Epoch, quod_runtime:stats(Ns)}) end
        end
    after quod_reg:unsubscribe({agent_hosting, Ns}) end.

resumed_work(Ref = {agent_instance_ref, Ns, Anchor, _}, Runtime, Child, Value) ->
    true = quod_reg:subscribe({agent, Ref}),
    try
        committed(submit_node({node_authorized_goal, Ns, Anchor,
                               {trigger_event, {resume_work, Value}}})),
        receive
            {agent_request_finished, Runtime, Child, #{reference := Ref}, _, Result} ->
                committed(Result)
        after 20000 -> error({resumed_work_not_completed, Value, quod_runtime:stats(Ns)}) end,
        {#{}, Height} = await_goal(Ns, {recovered_work, Value}, 10000),
        Height
    after quod_reg:unsubscribe({agent, Ref}) end.

restart_runtime(Ref = {agent_instance_ref, Ns, _, _}, Runtime) ->
    Sup = quod_reg:where({quod_ns, Ns}),
    ok = supervisor:terminate_child(Sup, quod_runtime),
    false = is_process_alive(Runtime),
    {ok, _} = supervisor:restart_child(Sup, quod_runtime),
    await_agent(Ref, 2, 10000).

assert_old_key_fenced(Ref = {agent_instance_ref, Ns, Anchor, actor}, OldKey) ->
    {ok, Network} = quod_ontology:network_identity(),
    Expires = quod_time:now_ms() + 30000,
    Request = #{network_identity => Network, agent_namespace => Ns,
      agent_genesis_anchor => Anchor, agent_instance_text => <<"actor.">>,
      signing_public_key => OldKey, operation_id => crypto:strong_rand_bytes(32),
      not_after_ms => Expires, mode => execute, parser_version => 2,
      goal_text => <<"record_recovered_work(stale_old_host).">>},
    %% Direct custody signing is the adversarial fixture: the retained key is
    %% usable, but ordinary ingress must reject its revoked authority.
    {ok, Bytes, Signature} = quod_agent_vault:sign(Request, quod_time:mono_ms() + 5000),
    {ok, Blob} = quod_wire_term:encode_canonical(Ref),
    ?assertMatch({ok, #{agent_ref_blob := Blob}}, quod_client_goal:verify(Bytes, Signature)),
    ?assert(quod_time:now_ms() < Expires),
    ?assertMatch({ok, _, {normalized, {failed, _}}},
                 quod_client_goal_ingress:submit(Bytes, Signature)),
    ?assert(quod_time:now_ms() < Expires),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {recovered_work, stale_old_host})),
    ok.

work_values() -> [after_recovery, after_runtime_restart, after_old_host_return].

committed({ok, _, {operation_outcome, _, #{status := completed, targets := Rows}}}) ->
    ?assert(Rows =/= []),
    lists:foreach(fun(Row) -> ?assertMatch({_, {committed, _}}, Row) end, Rows),
    ok;
committed(Result) ->
    ?assertMatch({ok, _, {normalized, {committed, [_], _}}}, Result),
    ok.

conjunction([G]) -> G;
conjunction([G | Rest]) -> {',', G, conjunction(Rest)}.

call(#{peer := Peer}, Module, Function, Args) ->
    peer:call(Peer, Module, Function, Args, 120000).

stop_peers(Peers) -> lists:foreach(fun(Peer) -> catch peer:stop(Peer) end, Peers).
