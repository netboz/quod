-module(quod_ask_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("quod_ledger.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([remote_plain_read_excludes_live_observer/1,
         remote_plain_read_rejects_lying_validator/1,
         remote_scope_solutions/1, remote_scope_trace_parentage/1,
         remote_scope_symbol_safety/1,
         remote_signed_fresh_nested_symbol/1,
         remote_scope_chain_policy/1, remote_scope_failure_reasons/1,
         remote_scope_nested_failure_reasons/1,
         remote_scope_deep_failure_reasons/1,
         remote_scope_structural_reason_truncation/1,
         remote_scope_cancel/1, remote_scope_transport_reuse/1,
         remote_signed_gateway_read_execute_cursor/1,
         remote_signed_read_certified_write/1,
         local_write_with_foreign_read/1,
         read_certificate_stale_rejected/1,
         remote_signed_origin_read_certificate_stale_rejected/1,
         remote_signed_two_gateway_race/1,
         remote_signed_gateway_group/1,
         remote_independent_routes/1,
         remote_independent_branch_provenance/1,
         remote_independent_nesting_and_auth/1,
         remote_independent_cursor_selects_only_accepted_answer/1,
         remote_signed_concurrent_gateway_groups/1,
         remote_signed_queued_occ_abort/1,
         remote_signed_gateway_group_with_root_effect/1,
         remote_signed_group_uses_exact_agent_request/1,
         remote_group_recovers_after_origin_crash/1,
         remote_four_scope_chain_recovers_empty_routes/1]).
-export([run_scope_proofs/3]).
-export([remote_signed_transaction_savepoints/1]).
-export([cut_findall_local_and_cohosted/1,
         cut_findall_remote_boundaries/1,
         cut_findall_signed_multiscope_savepoints/1]).

-define(TARGET_PORT, 15970).
-define(ASKER_PORT, 15971).
-define(THIRD_PORT, 15972).
-define(NS, <<"animals">>).
-define(ASKER_NS, <<"pets">>).
-define(PRIVATE_NS, <<"private">>).
-define(THIRD_NS, <<"third">>).
-define(FOURTH_NS, <<"fourth">>).
-define(ROOT_NS, <<"quod:root">>).
-define(SCOPE_WAVE_SIZE, 8).

all() -> [remote_signed_transaction_savepoints,
          cut_findall_local_and_cohosted,
          cut_findall_remote_boundaries,
          cut_findall_signed_multiscope_savepoints,
          remote_plain_read_excludes_live_observer,
          remote_plain_read_rejects_lying_validator,
          remote_scope_solutions, remote_scope_trace_parentage,
          remote_scope_symbol_safety,
          remote_signed_fresh_nested_symbol,
          remote_scope_chain_policy, remote_scope_failure_reasons,
          remote_scope_nested_failure_reasons,
          remote_scope_deep_failure_reasons,
          remote_scope_structural_reason_truncation,
          remote_scope_cancel, remote_scope_transport_reuse,
          remote_signed_gateway_read_execute_cursor,
          remote_signed_read_certified_write,
          local_write_with_foreign_read,
          read_certificate_stale_rejected,
          remote_signed_origin_read_certificate_stale_rejected,
          remote_signed_two_gateway_race,
          remote_signed_gateway_group,
          remote_independent_routes,
          remote_independent_branch_provenance,
          remote_independent_nesting_and_auth,
          remote_independent_cursor_selects_only_accepted_answer,
          remote_signed_concurrent_gateway_groups,
          remote_signed_queued_occ_abort,
          remote_signed_gateway_group_with_root_effect,
          remote_signed_group_uses_exact_agent_request,
          remote_group_recovers_after_origin_crash,
          remote_four_scope_chain_recovers_empty_routes].

remote_signed_transaction_savepoints(Config) ->
    %% Fresh callable names cannot be made accidentally executable by a
    %% previously loaded test beam or another proof's atom allocation.
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    Removed = <<"tx_wire_removed_", Suffix/binary>>,
    Kept = <<"tx_wire_kept_", Suffix/binary>>,
    Failed = iolist_to_binary(["animals::(transaction((assertz(", Removed,
      "(1)), third::assertz(", Removed, "(1)), fail)); true)."]),
    ?assertMatch({ok, _, {normalized, {answers, _, [_]}}},
                 submit_signed_execute(Config, Failed)),
    Fallback = iolist_to_binary(["animals::transaction(((assertz(", Removed,
      "(2)), third::assertz(", Removed, "(2)), fail); (assertz(", Kept,
      "(3)), third::assertz(", Kept, "(3)))))."]),
    ?assertMatch({ok, _, {normalized, {committed, [_], {group_outcome, _, _, _}}}},
                 submit_signed_execute(Config, Fallback)),
    lists:foreach(fun({Peer, Ns}) ->
        RemoveAtom = peer:call(Peer, erlang, binary_to_existing_atom, [Removed, utf8]),
        KeepAtom = peer:call(Peer, erlang, binary_to_existing_atom, [Kept, utf8]),
        ?assertMatch({fail, _}, peer:call(Peer, quod_prolog, prove, [Ns, {RemoveAtom, {'X'}}])),
        ?assertMatch({ok, [_], _}, peer:call(Peer, quod_prolog, prove, [Ns, {KeepAtom, 3}]))
    end, [{?config(target, Config), ?NS}, {?config(third, Config), ?THIRD_NS}]).

cut_findall_local_and_cohosted(Config) ->
    Peer = ?config(target, Config),
    X = {'X'}, Choices = {';', {'=', X, 1}, {'=', X, 2}},
    lists:foreach(fun(Inner) ->
        Goal = {findall, X, {';', {',', Inner, '!'}, {'=', X, 3}}, {'L'}},
        ?assertMatch({ok, [#{'L' := [1]}], _},
                     peer:call(Peer, quod_prolog, prove, [?NS, Goal], 60000))
    end, [Choices, {'::', ?FOURTH_NS, Choices}]).

cut_findall_remote_boundaries(Config) ->
    Peer = ?config(asker, Config),
    X = {'X'}, Choices = {';', {'=', X, 1}, {'=', X, 2}},
    Remote = {'::', ?NS, Choices},
    Cases = [
      {{';', Remote, {'=', X, 3}}, [1, 2, 3]},
      {{';', {'::', ?NS, {',', Choices, '!'}}, {'=', X, 3}}, [1, 3]},
      {{';', {',', Remote, '!'}, {'=', X, 3}}, [1]},
      {{';', {',', {'::', ?NS, {'\\+', {',', '!', fail}}}, {'=', X, 1}},
               {'=', X, 3}}, [1, 3]},
      {{'::', ?NS, {';', {'->', {',', '!', fail}, {'=', X, 1}},
                              {'=', X, 2}}}, [2]}],
    lists:foreach(fun({Inner, Expected}) ->
        Goal = {findall, X, Inner, {'L'}},
        ?assertMatch({ok, [#{'L' := Expected}], _},
                     peer:call(Peer, quod_prolog, prove, [?ASKER_NS, Goal], 60000))
    end, Cases).

cut_findall_signed_multiscope_savepoints(Config) ->
    %% Genuine signed requests and target commits, not an intent or overlay
    %% shortcut. Ordinary collection retains staged writes; transaction
    %% checkpoints remove failed-candidate writes on both remote scopes.
    ?assertMatch({ok, _, {normalized, {committed, [_], {group_outcome, _, _, _}}}},
      submit_signed_execute(Config,
        <<"animals::findall(X, ((X=1;X=2), assertz(cut_keep(X)), third::assertz(cut_keep(X)), !), [1]).">>)),
    Rollback = submit_signed_execute(Config,
        <<"animals::((transaction((findall(X, ((X=1;X=2), assertz(cut_remove(X)), third::assertz(cut_remove(X)), !), [1]), fail))); X=rolled_back).">>),
    ?assertMatch({ok, _, {normalized, {answers, _, [_]}}}, Rollback),
    {ok, _, {normalized, {answers, _, [RollbackBinding]}}} = Rollback,
    ?assertEqual({ok, [{<<"X">>, rolled_back}]}, quod_durable_term:decode_result(RollbackBinding)),
    lists:foreach(fun({Peer, Ns}) ->
        ?assertMatch({ok, [_], _}, peer:call(Peer, quod_prolog, prove, [Ns, {cut_keep, 1}])),
        ?assertMatch({fail, _}, peer:call(Peer, quod_prolog, prove, [Ns, {cut_keep, 2}])),
        ?assertMatch({fail, _}, peer:call(Peer, quod_prolog, prove, [Ns, {cut_remove, {'X'}}]))
    end, [{?config(target, Config), ?NS}, {?config(third, Config), ?THIRD_NS}]).

init_per_suite(Config) ->
    {TargetPub, _} = TargetKey = quod_identity:generate(),
    {AskerPub, _} = AskerKey = quod_identity:generate(),
    {ThirdPub, _} = ThirdKey = key_before(TargetPub),
    {AgentPub, _} = AgentKey = quod_identity:generate(),
    TargetAddr = {"127.0.0.1", ?TARGET_PORT},
    AskerAddr = {"127.0.0.1", ?ASKER_PORT},
    ThirdAddr = {"127.0.0.1", ?THIRD_PORT},
    Animals = filename:join(code:priv_dir(quod), "ontologies/animals.pl"),
    Pets = filename:join(code:priv_dir(quod), "ontologies/pets.pl"),
    {ok, AnimalsBin} = file:read_file(Animals),
    {ok, PetsBin} = file:read_file(Pets),
    FilterSymbolName =
        <<"quod_r4_target_only_",
          (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    TargetGenesis = filename:join(?config(priv_dir, Config), "remote_animals.pl"),
    ok = file:write_file(
           TargetGenesis,
           ["can_invoke(_Goal, agent_instance_ref(<<\"pets\">>, _, "
            "human_user(test_agent)), _Chain, _Ns).\n",
            AnimalsBin,
            "\necho(X).\n",
            FilterSymbolName, "(opaque).\n",
            "blocked(X) :- fail_with_reason(impossible_to_link(X)).\n",
            "via_third_failure :- third::third_blocked.\n",
            "via_fourth(X) :- third::via_fourth(X).\n",
            "dtx_write_chain(X) :- assertz(dtx_animals_mark(X)), "
            "third::dtx_write(X).\n",
            dtx_disjoint_target_rules(),
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
           ["can_invoke(_Goal, _Principal, _Chain, _Ns).\n"
            "third_blocked :- fail_with_reason(third_declined).\n"
            "via_fourth(X) :- fourth::leaf(X).\n"
            "dtx_write(X) :- assertz(dtx_third_mark(X)).\n",
            dtx_disjoint_third_rules()]),
    ThirdAllow = #{?ASKER_NS => [AskerPub],
                   ?NS => [TargetPub]},
    Third = start_node(third, ?THIRD_PORT, ThirdKey, ?THIRD_NS,
                       ThirdGenesis, [], ThirdAllow, Config),
    FourthGenesis = filename:join(
                      ?config(priv_dir, Config), "remote_fourth.pl"),
    ok = file:write_file(
           FourthGenesis,
           ["can_invoke(_Goal, _Principal, _Chain, _Ns).\n"
            "leaf(ok).\n"]),
    start_namespace(
      Target, TargetPub, ?FOURTH_NS, FourthGenesis, [], Config),
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
    DirectoryAllow = #{?NS => [ThirdPub, TargetPub],
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
            "can_invoke((instance_of(pet, my_dog), _), "
            "agent_instance_ref(<<\"pets\">>, _, human_user(test_agent)), "
            "_Chain, _Ns).\n",
            "can_invoke(independent(_), "
            "agent_instance_ref(<<\"pets\">>, _, human_user(test_agent)), "
            "_Chain, _Ns).\n"
            "can_invoke((_;_), "
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
    FourthAnchor = peer:call(
                     Target, quod_simplex, genesis_hash, [?FOURTH_NS]),
    AskerAnchor = peer:call(
                     Asker, quod_simplex, genesis_hash, [?ASKER_NS]),
    RootAnchor = peer:call(
                   Target, quod_simplex, genesis_hash, [?ROOT_NS]),
    NetworkId = RootAnchor,
    lists:foreach(
      fun(Peer) -> set_network_identity(Peer, NetworkId) end,
      [Target, Asker, Third]),
    %% Root's seed/spec requires a local replica before durable effects.
    %% The old fixture declared its anchor as locally desired on every peer
    %% but left Asker/Third without the corresponding owner. R2 correctly
    %% treats that as unavailable local history, never as foreign permission.
    %% Pin the refusal, then establish real non-voting replicas. Root writes
    %% and effect custody still execute on Target, its sole validator.
    start_brahms(Target, ?ROOT_NS, TargetAddr, []),
    lists:foreach(fun({RootPeer, RootPub, RootAddr}) ->
        ?assertEqual(undefined,
            peer:call(RootPeer, quod_reg, where, [{quod_simplex, ?ROOT_NS}])),
        RootDeadline = peer:call(RootPeer, quod_time, mono_ms, []) + 1000,
        ?assertEqual({error, not_ready}, peer:call(RootPeer, quod_simplex,
            history_view_at, [{?ROOT_NS, RootAnchor}, 1, RootDeadline])),
        start_join_namespace(RootPeer, RootPub, ?ROOT_NS, RootAnchor, [TargetAddr], Config),
        start_brahms(RootPeer, ?ROOT_NS, RootAddr, [TargetAddr]),
        wait_ready(RootPeer, ?ROOT_NS, {effect_custody_capacity, 64}),
        ?assertMatch(#{role := observer},
            peer:call(RootPeer, quod_simplex, status, [?ROOT_NS]))
    end, [{Asker, AskerPub, AskerAddr}, {Third, ThirdPub, ThirdAddr}]),
    %% The third node is a real, fully synchronized observer of `animals`.
    %% Its key sorts before the sole validator so the live selection tests
    %% below would choose it first if advertised roles were trusted.
    ok = peer:call(Third, quod_quic, learn, [TargetPub, TargetAddr]),
    ok = peer:call(Target, quod_quic, learn, [ThirdPub, ThirdAddr]),
    start_join_namespace(
      Third, ThirdPub, ?NS, TargetAnchor, [TargetAddr], Config),
    start_brahms(Third, ?NS, ThirdAddr, [TargetAddr]),
    AgentRef = {agent_instance_ref, ?ASKER_NS, AskerAnchor,
                {human_user, test_agent}},
    {ok, _} = peer:call(
                Asker, quod_ct, install_directory_generation,
                [TargetPub, TargetAddr,
                 [{?NS, TargetAnchor, validator},
                  {?FOURTH_NS, FourthAnchor, validator},
                  {?ROOT_NS, RootAnchor, validator}], 1, 1]),
    %% DTX phase references are verified independently at every participant.
    %% A therefore needs exact routes to B and C, while B/C each need the
    %% origin route for Begin/Decision evidence.  B deliberately still has no
    %% C route: nested scope selection remains owned and relayed by A.
    {ok, _} = peer:call(
                Asker, quod_ct, install_directory_generation,
                [ThirdPub, ThirdAddr,
                 [{?THIRD_NS, ThirdAnchor, validator},
                  {?NS, TargetAnchor, observer}], 1, 1]),
    {ok, _} = peer:call(
                Third, quod_ct, install_directory_generation,
                [TargetPub, TargetAddr,
                 [{?NS, TargetAnchor, validator}], 1, 1]),
    {ok, _} = peer:call(
                Target, quod_ct, install_directory_generation,
                [AskerPub, AskerAddr,
                 [{?ASKER_NS, AskerAnchor, validator}], 1, 1]),
    {ok, _} = peer:call(
                Third, quod_ct, install_directory_generation,
                [AskerPub, AskerAddr,
                 [{?ASKER_NS, AskerAnchor, validator}], 1, 1]),
    %% Private reachability is the local projection of an exact committed
    %% HostNodeRef.  The target ontology's public route supplies that host's
    %% current endpoint; the private ontology itself is never advertised.
    PrivateAnchor = peer:call(
                      Target, quod_simplex, genesis_hash, [?PRIVATE_NS]),
    HostNodeRef = {agent_instance_ref, ?NS, TargetAnchor, target_node},
    ok = peer:call(
           Asker, quod_directory, install_private_projection,
           [[#{namespace => ?PRIVATE_NS, anchor => PrivateAnchor,
               host_node_ref => HostNodeRef}]]),
    %% The origin, not the currently executing B scope, selects C for A→B→C.
    %% B therefore has no C route; this exercises the authenticated controller
    %% relay and target-only atom materialization path.
    %% C was installed above through the same candidate path.
    start_brahms(Asker, ?ASKER_NS, AskerAddr, [TargetAddr]),
    start_brahms(Third, ?THIRD_NS, ThirdAddr, []),
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
    wait_ready(Third, ?NS, {diet, dog, kibble}),
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
     {target_addr, TargetAddr}, {third_pub, ThirdPub},
     {third_addr, ThirdAddr}, {network_id, NetworkId},
     {target_anchor, TargetAnchor}, {third_anchor, ThirdAnchor},
     {fourth_anchor, FourthAnchor},
     {asker_anchor, AskerAnchor}, {filter_symbol_name, FilterSymbolName},
     {agent_ref, AgentRef},
     {agent_key, AgentKey}, {agent_pub, AgentPub},
     {client_peer, ClientPeer}, {client_session, Session},
     {client_auth, AuthPid} | Config].

end_per_suite(Config) ->
    _ = [catch peer:stop(P) || P <- [?config(target, Config),
                                      ?config(asker, Config),
                                      ?config(third, Config)]],
    ok.

%% A real, caught-up observer can answer the ontology locally, but an
%% advertised observer row is never eligible to answer a single-host remote
%% read. The sole current validator must own the live scope.
remote_plain_read_excludes_live_observer(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    Observer = ?config(third, Config),
    ObserverKey = ?config(third_pub, Config),
    {known, Routes} = peer:call(Asker, quod_directory, resolve, [?NS]),
    ?assert(lists:any(
              fun(#{node_key := Key, role := observer}) ->
                      Key =:= ObserverKey;
                 (_) -> false
              end, Routes)),
    ?assertMatch(
       {ok, [_], _},
       peer:call(Observer, quod_prolog, prove_ro,
                 [?NS, {diet, dog, kibble}], 5000)),
    assert_symbol_opaque(Asker, ?config(filter_symbol_name, Config)),
    AtomsBefore = peer:call(Asker, erlang, system_info, [atom_count]),
    assert_remote_scope_owner(Asker, Target, Observer),
    ?assertEqual(
       AtomsBefore, peer:call(Asker, erlang, system_info, [atom_count])),
    assert_symbol_opaque(Asker, ?config(filter_symbol_name, Config)).

%% The same live observer now lies in its next signed directory generation and
%% labels itself a validator. Its key sorts before the real validator, so a
%% role-trusting selector would open the scope there. The certified target
%% committee removes it and resolution reaches the honest coexisting route.
remote_plain_read_rejects_lying_validator(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    Liar = ?config(third, Config),
    LiarKey = ?config(third_pub, Config),
    LiarEndpoint = ?config(third_addr, Config),
    TargetKey = ?config(target_pub, Config),
    TargetAnchor = ?config(target_anchor, Config),
    ThirdAnchor = ?config(third_anchor, Config),
    LyingRows = [{?THIRD_NS, ThirdAnchor, validator},
                 {?NS, TargetAnchor, validator}],
    HonestRows = [{?THIRD_NS, ThirdAnchor, validator},
                  {?NS, TargetAnchor, observer}],
    {ok, _} = peer:call(
                Asker, quod_ct, install_directory_generation,
                [LiarKey, LiarEndpoint, LyingRows, 1, 2]),
    try
        {known, Routes} = peer:call(
                            Asker, quod_directory, resolve, [?NS]),
        ValidatorKeys = [Key || #{role := validator, node_key := Key} <- Routes],
        ?assertEqual([LiarKey, TargetKey], ValidatorKeys),
        assert_symbol_opaque(Asker, ?config(filter_symbol_name, Config)),
        AtomsBefore = peer:call(Asker, erlang, system_info, [atom_count]),
        assert_remote_scope_owner(Asker, Target, Liar),
        ?assertEqual(
           AtomsBefore, peer:call(Asker, erlang, system_info, [atom_count])),
        assert_symbol_opaque(Asker, ?config(filter_symbol_name, Config))
    after
        {ok, _} = peer:call(
                    Asker, quod_ct, install_directory_generation,
                    [LiarKey, LiarEndpoint, HonestRows, 1, 3])
    end.

assert_remote_scope_owner(Asker, Validator, RefusedHost) ->
    wait_scope_workers(Validator, 0, 200),
    wait_scope_workers(RefusedHost, 0, 200),
    Loop = {'::', ?NS, loop},
    Caller = peer:call(Asker, erlang, spawn,
                       [quod_prolog, prove_ro, [?ASKER_NS, Loop]]),
    try
        wait_scope_workers(Validator, 1, 1500),
        ?assertEqual(0, scope_worker_count(RefusedHost))
    after
        true = peer:call(Asker, erlang, exit, [Caller, kill]),
        wait_engine_stat(Asker, ?ASKER_NS, proof_workers, 0, 500),
        wait_scope_workers(Validator, 0, 500),
        wait_scope_workers(RefusedHost, 0, 200)
    end.

scope_worker_count(Peer) ->
    maps:get(scope_workers,
             peer:call(Peer, quod_prolog, stats, [?NS]), undefined).

assert_symbol_opaque(Peer, SymbolName) ->
    ?assertEqual(
       {ok, {'$quod_symbol', SymbolName}},
       peer:call(Peer, quod_wire_term, decode, [{0, SymbolName}])).

remote_scope_solutions(Config) ->
    Asker = ?config(asker, Config),
    Goal = {'::', ?NS, {diet, dog, {'D'}}},
    ?assertMatch({ok, [#{'D' := {'$quod_symbol', <<"kibble">>}}], _},
                 peer:call(Asker, quod_prolog, prove, [?ASKER_NS, Goal], 60000)),
    All = {findall, {'D'}, Goal, {'L'}},
    ?assertMatch({ok, [#{'L' := [{'$quod_symbol', <<"kibble">>},
                                  {'$quod_symbol', <<"meat">>}]}], _},
                 peer:call(Asker, quod_prolog, prove, [?ASKER_NS, All], 60000)).

remote_scope_trace_parentage(Config) ->
    Target = ?config(target, Config),
    Asker = ?config(asker, Config),
    %% These peers use standard_io, not Erlang distribution to the CT VM.
    %% All trace collection and monitoring stay on the owning peer; neither
    %% target loads this suite's intentionally caller-only vocabulary.
    Collector = peer:call(Target, quod_trace_fixture, start, []),
    try
        {Result, Public, Open, Directory, ScopeOpen, Request} = peer:call(
                                                                 Asker,
                                                                 quod_trace_fixture,
                                                                 prove,
                                                                 [?ASKER_NS,
                                                                  {'::', ?NS,
                                                                   {diet, dog,
                                                                    {'D'}}}],
                                                                 60000),
        ?assertMatch({ok, [#{'D' := {'$quod_symbol', <<"kibble">>}}], _}, Result),
        ?assertEqual(Public#span.trace_id, Open#span.trace_id),
        ?assertEqual(Open#span.span_id, Directory#span.parent_span_id),
        ?assertEqual(Directory#span.span_id, ScopeOpen#span.parent_span_id),
        ?assertEqual(Open#span.span_id, Request#span.parent_span_id),
        Auth = peer:call(Target, quod_trace_fixture, take_span,
                         [Collector, <<"quod.scope.authenticate">>]),
        InvokeOpen = peer:call(Target, quod_trace_fixture, take_span,
                              [Collector, <<"quod.scope.invoke_open">>]),
        InvokeNext = peer:call(Target, quod_trace_fixture, take_span,
                              [Collector, <<"quod.scope.invoke_next">>]),
        %% These spans are emitted by the actual remote authentication worker
        %% and target invocation worker, not by a codec-only fixture.
        lists:foreach(fun(Span) ->
            ?assertEqual(Public#span.trace_id, Span#span.trace_id),
            ?assertEqual(ScopeOpen#span.span_id, Span#span.parent_span_id),
            ?assert(Span#span.parent_span_is_remote),
            ?assert(Span#span.end_time >= Span#span.start_time)
        end, [Auth, InvokeOpen, InvokeNext])
    after
        ok = peer:call(Target, quod_trace_fixture, stop, [Collector])
    end.

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

%% A retains the new predicate as an opaque symbol. C alone starts with its
%% fact. B materializes the spelling from a deliberately failing local branch
%% while leaving C's nested goal opaque, then C returns that same symbol. Both
%% simultaneous first-use requests must bind without a failed seed request.
remote_signed_fresh_nested_symbol(Config) ->
    Asker = ?config(asker, Config),
    Third = ?config(third, Config),
    NetworkId = ?config(network_id, Config),
    AgentPub = ?config(agent_pub, Config),
    AgentKey = ?config(agent_key, Config),
    Session = ?config(client_session, Config),
    ClientPeer = ?config(client_peer, Config),
    AgentAnchor = ?config(asker_anchor, Config),
    RaceSuffix = integer_to_list(erlang:unique_integer([positive])),
    RacePredicateText = "quod_fresh_race_" ++ RaceSuffix,
    RacePredicate = list_to_atom(RacePredicateText),
    ?assertMatch(
       {ok, [_], _},
       peer:call(
         Third, quod_prolog, prove,
         [?THIRD_NS, {assertz, {RacePredicate, ok}}], 60000)),
    RaceGoalText = iolist_to_binary(
                     ["\"animals\"::((", RacePredicateText,
                      "(ok), fail); \"third\"::", RacePredicateText,
                      "(ok))."]),
    Requests =
        [signed_goal_request(
           NetworkId, AgentPub, AgentKey, ?ASKER_NS, AgentAnchor,
           maps:get(expires_ms, Session), read, RaceGoalText)
         || _ <- [first, second]],
    Parent = self(),
    RaceRef = make_ref(),
    Workers =
        [spawn(
           fun() ->
               receive {RaceRef, go} -> ok end,
               Parent !
                   {RaceRef, Label,
                    peer:call(
                      Asker, quod_client_goal_ingress, submit,
                      [read, maps:get(session_id, Session), Bytes,
                       RequestSignature, ClientPeer], 60000)}
           end)
         || {Label, {Bytes, RequestSignature}} <-
                lists:zip([first, second], Requests)],
    lists:foreach(fun(Worker) -> Worker ! {RaceRef, go} end, Workers),
    Results = collect_gateway_race(RaceRef, 2, []),
    lists:foreach(
      fun({_Label,
           {ok, _, {normalized, {answers, _Height, [_Answer]}}}}) -> ok;
         ({Label, Other}) -> error({fresh_symbol_race_failed, Label, Other})
      end, Results).

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
    {known, Routes} = peer:call(
                        Asker, quod_directory, resolve, [?PRIVATE_NS]),
    ?assert(Routes =/= []),
    ?assert(lists:all(
              fun(#{scope := private, status := confirmed}) -> true;
                 (_) -> false
              end, Routes)),
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
                 [{0, <<"third_blocked">>}])),
    assert_foreign_current_keeps_symbol_opaque(
      Asker, ?config(third, Config), ?THIRD_NS,
      ?config(third_pub, Config), ?config(third_addr, Config),
      <<"third_blocked">>).

remote_scope_deep_failure_reasons(Config) ->
    Asker = ?config(asker, Config),
    Remote = {'::', ?NS, {deep_failure, 70}},
    {fail, Reasons} = peer:call(
                        Asker, quod_prolog, prove,
                        [?ASKER_NS, Remote], 60000),
    ?assert(length(Reasons) > 64),
    ?assertEqual(Remote, hd(Reasons)),
    ?assertEqual({'$quod_symbol', <<"deep_bottom">>}, lists:last(Reasons)),
    assert_foreign_current_keeps_symbol_opaque(
      Asker, ?config(target, Config), ?NS,
      ?config(target_pub, Config), ?config(target_addr, Config),
      <<"deep_bottom">>).

assert_foreign_current_keeps_symbol_opaque(
  Asker, Host, Ns, HostKey, Endpoint, SymbolName) ->
    Anchor = peer:call(Host, quod_simplex, genesis_hash, [Ns]),
    ?assertMatch(
       {ok, #{identity := {Ns, Anchor}}},
       peer:call(
         Asker, quod_foreign_log, current,
         [[{HostKey, [Endpoint]}], {Ns, Anchor}, 20000], 25000)),
    %% current/3 must be able to certify and retain the complete foreign
    %% history without interning that ontology's application vocabulary.
    ?assertEqual(
       {ok, {'$quod_symbol', SymbolName}},
       peer:call(Asker, quod_wire_term, decode, [{0, SymbolName}])).

remote_scope_structural_reason_truncation(Config) ->
    Asker = ?config(asker, Config),
    %% A deep value at the wire boundary must survive intact.  This makes the
    %% over-depth assertion below non-vacuous: the recursive builder really is
    %% compiled and its binding crosses the remote proof boundary.
    Legal = {'::', ?NS, bounded_reason},
    {fail, LegalReasons} = peer:call(
                             Asker, quod_prolog, prove,
                             [?ASKER_NS, Legal], 60000),
    {ok, Bottom} = peer:call(
                     Asker, quod_wire_term, decode,
                     [{0, <<"deep_bottom">>}]),
    LegalReason = lists:foldl(
                    fun(_, Acc) -> [Acc] end, Bottom,
                    lists:seq(1, 63)),
    ?assert(lists:member(LegalReason, LegalReasons)),
    ?assert(quod_wire_term:valid_failure_reason_stack(LegalReasons)),

    Remote = {'::', ?NS, deep_reason},
    {fail, Reasons} = peer:call(
                        Asker, quod_prolog, prove,
                        [?ASKER_NS, Remote], 60000),
    ?assertEqual(Remote, hd(Reasons)),
    ?assert(lists:member(deep_reason, Reasons)),
    ?assert(lists:member(fail_reasons_truncated, Reasons)),
    ?assert(quod_wire_term:valid_failure_reason_stack(Reasons)).

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
    Tag = erlang:unique_integer([positive]),
    ExecuteText = iolist_to_binary(
                    io_lib:format("assertz(gateway_mark(~B)).", [Tag])),
    {ExecuteBytes, ExecuteSignature} = signed_goal_request(
                                         NetworkId, AgentPub, AgentKey,
                                         ?ASKER_NS, AgentAnchor,
                                         maps:get(expires_ms, Session),
                                         execute,
                                         <<"\"animals\"::", ExecuteText/binary>>),
    {ok, ExecuteEvidence,
     {normalized,
      {committed, [_],
       {transaction, ?NS, TargetAnchor, _} = ExecuteTargetRef}}} =
        peer:call(
          Asker, quod_client_goal_ingress, submit,
          [execute, maps:get(session_id, Session), ExecuteBytes,
           ExecuteSignature, Peer], 60000),
    ?assertEqual(
       ExecuteTargetRef,
       completed_remote_operation(
         Asker, maps:get(operation_ref, ExecuteEvidence), 600)),
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
    {ok, CursorEvidence,
     {normalized,
      {committed, [_],
       {transaction, ?NS, TargetAnchor, _} = CursorTargetRef}}} =
        peer:call(
          Asker, quod_client_goal_ingress, cursor_command,
          [maps:get(session_id, Session), CursorId, accept, Peer], 60000),
    ?assertEqual(
       CursorTargetRef,
       completed_remote_operation(
         Asker, maps:get(operation_ref, CursorEvidence), 600)),
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

%% B contributes only a certified read. C remains the sole writer, so this is
%% one ordinary remote operation claim and target transaction, never a DTX
%% group with empty Prepare/Finalize slots for B.
remote_signed_read_certified_write(Config) ->
    Asker = ?config(asker, Config),
    Third = ?config(third, Config),
    Tag = erlang:unique_integer([positive]),
    GoalText = iolist_to_binary(
                 io_lib:format(
                   "\"animals\"::diet(dog, kibble), "
                   "\"third\"::dtx_write(~B).", [Tag])),
    {ok, Evidence,
     {normalized,
      {committed, [_],
       {transaction, ?THIRD_NS, ThirdAnchor, _} = TargetRef}}} =
        submit_signed_execute(Config, GoalText),
    ?assertEqual(
       ThirdAnchor,
       peer:call(Third, quod_simplex, genesis_hash, [?THIRD_NS])),
    ?assertEqual(
       TargetRef,
       completed_remote_operation(
         Asker, maps:get(operation_ref, Evidence), 600)),
    assert_fact_once(Third, ?THIRD_NS, dtx_third_mark, Tag).

%% A writes locally while B contributes only a certified read. The result is
%% A's ordinary transaction; there is no source claim and no DTX group.
local_write_with_foreign_read(Config) ->
    Asker = ?config(asker, Config),
    Tag = erlang:unique_integer([positive]),
    GoalText = iolist_to_binary(
                 io_lib:format(
                   "assertz(signed_pets_mark(~B)), "
                   "\"animals\"::diet(dog, kibble).", [Tag])),
    ?assertMatch(
       {ok, _,
        {normalized,
         {committed, [_], {transaction, ?ASKER_NS, _, _}}}},
       submit_signed_execute(Config, GoalText)),
    assert_fact_once(Asker, ?ASKER_NS, signed_pets_mark, Tag).

%% The read token is sealed first. B then commits another diet/2 fact before
%% its validators sign the certificate. Certification must reject the stale
%% token and A's local write must remain absent.
read_certificate_stale_rejected(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    Tag = erlang:unique_integer([positive]),
    GoalText = iolist_to_binary(
                 io_lib:format(
                   "assertz(signed_pets_mark(~B)), "
                   "\"animals\"::diet(dog, kibble).", [Tag])),
    ok = peer:call(
           Asker, quod_prolog,
           test_install_read_certificate_barrier, []),
    Parent = self(),
    RequestRef = make_ref(),
    _ = spawn(
          fun() ->
              Parent ! {RequestRef, submit_signed_execute(Config, GoalText)}
          end),
    try
        ok = peer:call(
               Asker, quod_prolog,
               test_await_read_certificate_barrier, [3000]),
        ?assertMatch(
           {ok, [_], _},
           peer:call(
             Target, quod_prolog, prove,
             [?NS, {assertz, {diet, dog, {stale_marker, Tag}}}],
             60000))
    after
        %% Never leave the TEST-only rendezvous installed if an assertion
        %% above fails: a later proof would otherwise correctly wait forever.
        _ = peer:call(
              Asker, quod_prolog,
              test_release_read_certificate_barrier, [])
    end,
    Result = receive
                 {RequestRef, Value} -> Value
             after 60000 ->
                 ct:fail(stale_read_request_did_not_finish)
             end,
    ?assertMatch(
       {ok, _, {normalized, {error, conflict_retry}}}, Result),
    assert_fact_absent(Asker, ?ASKER_NS, signed_pets_mark, Tag).

%% The signed claim lane treats A's own read exactly like any other read-only
%% dependency. If A changes after sealing but before certification, neither the
%% source claim nor C's write may be submitted.
remote_signed_origin_read_certificate_stale_rejected(Config) ->
    Asker = ?config(asker, Config),
    Third = ?config(third, Config),
    Tag = erlang:unique_integer([positive]),
    GoalText = iolist_to_binary(
                 io_lib:format(
                   "instance_of(pet, my_dog), \"third\"::dtx_write(~B).",
                   [Tag])),
    ok = peer:call(
           Asker, quod_prolog,
           test_install_read_certificate_barrier, []),
    Parent = self(),
    RequestRef = make_ref(),
    _ = spawn(
          fun() ->
              Parent ! {RequestRef, submit_signed_execute(Config, GoalText)}
          end),
    try
        ok = peer:call(
               Asker, quod_prolog,
               test_await_read_certificate_barrier, [3000]),
        %% The source proof is deliberately parked before its certificate.
        %% Commit the intervening source-head change at the consensus seam so
        %% this test does not depend on a second client ingress being admitted
        %% while the first signed request still owns that ingress session.
        append_source_marker(Config, Tag)
    after
        _ = peer:call(
              Asker, quod_prolog,
              test_release_read_certificate_barrier, [])
    end,
    Result = receive
                 {RequestRef, Value} -> Value
             after 60000 ->
                 ct:fail(origin_stale_read_request_did_not_finish)
             end,
    ?assertMatch(
       {ok, _, {normalized, {error, conflict_retry}}}, Result),
    assert_fact_absent(Third, ?THIRD_NS, dtx_third_mark, Tag).

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
    OutcomeRef = {transaction, ?NS, TargetAnchor, _} =
        completed_remote_operation(Asker, OperationRef, 600),
    ?assertEqual(
       TargetAnchor,
       peer:call(Target, quod_simplex, genesis_hash, [?NS])),
    ?assertMatch(
       {ok, #{status := claimed, operation_state := terminal,
              outcome_ref := {applications, [{transaction, ?NS, TargetAnchor, _}]}}},
       peer:call(Third, quod_prolog, outcome, [OperationRef])),
    ?assertMatch(
       {ok, _, {operation_outcome,
                #{status := claimed, outcome_ref := _},
                #{status := committed}}},
       wait_remote_operation(
         Asker, maps:get(session_id, AskerSession), RequestBytes,
         Signature, ClientPeer, 8)),
    {ok, #{status := committed, height := OutcomeHeight, ref := OutcomeRef}} =
        peer:call(Target, quod_prolog, outcome, [OutcomeRef]),
    %% Third is an observer of the target ontology. A remote result at Asker
    %% does not mean Third's local projection has consumed the target block.
    %% Wait for that actual event; do not resubmit, nudge the feed, or replace
    %% the fixture's ordering requirement with a short repeated resolve loop.
    ok = peer:call(Third, quod_ct, await_applied,
                   [?NS, OutcomeHeight, 10000], 15000),
    ?assertMatch(
       {ok, _, {operation_outcome,
                #{status := claimed, outcome_ref := _},
                #{status := committed}}},
       peer:call(
         Third, quod_client_goal_ingress, resolve_operation,
         [maps:get(session_id, ThirdSession), RequestBytes,
          Signature, ClientPeer], 10000)),
    assert_fact_once(Target, ?NS, gateway_race_mark, Tag).

%% A signed agent stored in A reaches B and then C through the same nested
%% scope and group machinery. No specialized client or agent executor exists.
remote_independent_routes(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    ?assertMatch({ok, _, {normalized, {answers, _, [_]}}},
      submit_signed_execute(Config, <<"animals::independent(true).">>)),
    Tag = erlang:unique_integer([positive]),
    Text = iolist_to_binary(io_lib:format(
      "animals::independent(assertz(s6_remote(~B))).", [Tag])),
    {ok, Evidence, {normalized, {committed, [_], Ref}}} =
        submit_signed_execute(Config, Text),
    ?assertMatch({transaction, ?NS, _, _}, Ref),
    ?assertEqual(Ref, completed_remote_operation(
                       Asker, maps:get(operation_ref, Evidence), 600)),
    assert_fact_once(Target, ?NS, s6_remote, Tag),
    lists:foreach(fun(Goal) ->
        ?assertMatch({ok, _, {normalized, {error, independent_lane_unavailable}}},
                     submit_signed_execute(Config, Goal))
    end, [<<"independent((assertz(s6_ab), animals::assertz(s6_ab))).">>,
          <<"animals::independent((assertz(s6_bc), third::assertz(s6_bc))).">>]),
    lists:foreach(fun({Peer, Ns, Fact}) ->
        ?assertMatch({fail, _}, peer:call(Peer, quod_prolog, prove, [Ns, Fact]))
    end, [{Asker, ?ASKER_NS, s6_ab}, {Target, ?NS, s6_ab},
          {Target, ?NS, s6_bc}, {?config(third, Config), ?THIRD_NS, s6_bc}]).

remote_independent_branch_provenance(Config) ->
    Target = ?config(target, Config),
    Third = ?config(third, Config),
    %% The original signed request and real sealed retained writes choose L3.
    ?assertMatch({ok, _, {normalized, {committed, [_], {group_outcome, _, _, _}}}},
      submit_signed_execute(Config,
        <<"animals::((independent((assertz(s6_f1), third::assertz(s6_f1), fail))); true).">>)),
    ?assertMatch({ok, [#{}], _},
                 peer:call(Target, quod_prolog, prove, [?NS, s6_f1])),
    ?assertMatch({ok, [_], _}, peer:call(Third, quod_prolog, prove, [?THIRD_NS, s6_f1])),
    ?assertMatch({ok, _, {normalized, {error, independent_mixed_writes}}},
      submit_signed_execute(Config,
        <<"animals::(((assertz(s6_f2), fail); true), independent(third::assertz(s6_f2))).">>)),
    ?assertMatch({ok, _, {normalized, {error, independent_lane_unavailable}}},
      submit_signed_execute(Config,
        <<"animals::((independent((assertz(s6_f3), fail)); true), independent(third::assertz(s6_f3))).">>)),
    %% A remotely-produced successful marker must unwind at its caller too.
    ?assertMatch({ok, _, {normalized, {committed, [_], {group_outcome, _, _, _}}}},
      submit_signed_execute(Config,
        <<"((animals::independent((assertz(s6_unwound), third::assertz(s6_unwound))), fail); true).">>)),
    lists:foreach(fun(Fact) ->
        ?assertMatch({fail, _}, peer:call(Target, quod_prolog, prove, [?NS, Fact])),
        ?assertMatch({fail, _}, peer:call(Third, quod_prolog, prove, [?THIRD_NS, Fact]))
    end, [s6_f2, s6_f3]).

remote_independent_nesting_and_auth(Config) ->
    lists:foreach(fun(Text) ->
        ?assertMatch({ok, _, {normalized, {error, independent_nesting}}},
                     submit_signed_execute(Config, Text))
    end, [<<"animals::independent(third::transaction(true)).">>,
          <<"animals::transaction(third::independent(true)).">>,
          <<"animals::independent(third::independent(true)).">>,
          <<"animals::independent(third::(animals::transaction(true))).">>]),
    Session = ?config(client_session, Config),
    {Bytes, _Signature} = signed_goal_request(
      ?config(network_id, Config), ?config(agent_pub, Config), ?config(agent_key, Config),
      ?ASKER_NS, ?config(asker_anchor, Config), maps:get(expires_ms, Session),
      <<"animals::independent(assertz(s6_invalid_auth)).">>),
    ?assertEqual({error, invalid_signature}, peer:call(
      ?config(asker, Config), quod_client_goal_ingress, submit,
      [execute, maps:get(session_id, Session), Bytes, <<0:512>>, ?config(client_peer, Config)])),
    ?assertMatch({fail, _}, peer:call(
      ?config(target, Config), quod_prolog, prove, [?NS, s6_invalid_auth])).

remote_independent_cursor_selects_only_accepted_answer(Config) ->
    Asker = ?config(asker, Config),
    Session = ?config(client_session, Config),
    SessionId = maps:get(session_id, Session),
    ClientPeer = ?config(client_peer, Config),
    lists:foreach(fun(AcceptSecond) ->
        Tag = erlang:unique_integer([positive]),
        Text = iolist_to_binary(io_lib:format(
          "animals::((independent((assertz(s6_cursor(~B)), third::assertz(s6_cursor(~B)))), X=first); X=second).",
          [Tag, Tag])),
        {Bytes, Signature} = signed_goal_request(
          ?config(network_id, Config), ?config(agent_pub, Config), ?config(agent_key, Config),
          ?ASKER_NS, ?config(asker_anchor, Config), maps:get(expires_ms, Session), cursor, Text),
        {ok, _, {normalized, {solution, CursorId, _, First}}} = peer:call(
          Asker, quod_client_goal_ingress, submit,
          [cursor, SessionId, Bytes, Signature, ClientPeer], 60000),
        ?assertEqual({ok, [{<<"X">>, first}]}, quod_durable_term:decode_result(First)),
        case AcceptSecond of
            false -> ok;
            true ->
                {ok, _, {normalized, {solution, CursorId, _, Second}}} = peer:call(
                  Asker, quod_client_goal_ingress, cursor_command,
                  [SessionId, CursorId, next, ClientPeer], 60000),
                ?assertEqual({ok, [{<<"X">>, second}]},
                             quod_durable_term:decode_result(Second))
        end,
        Result = peer:call(Asker, quod_client_goal_ingress, cursor_command,
                          [SessionId, CursorId, accept, ClientPeer], 60000),
        case AcceptSecond of
            false ->
                ?assertMatch({ok, _, {normalized, {error, independent_lane_unavailable}}}, Result),
                assert_fact_absent(?config(target, Config), ?NS, s6_cursor, Tag),
                assert_fact_absent(?config(third, Config), ?THIRD_NS, s6_cursor, Tag);
            true ->
                ?assertMatch({ok, _, {normalized,
                                     {committed, [_], {group_outcome, _, _, _}}}}, Result),
                assert_fact_once(?config(target, Config), ?NS, s6_cursor, Tag),
                assert_fact_once(?config(third, Config), ?THIRD_NS, s6_cursor, Tag)
        end
    end, [false, true]).

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
                Target, quod_ct, install_directory_generation,
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
    ?assertEqual(2, length(Slots)),
    assert_fact_once(Target, ?NS, dtx_animals_mark, Tag),
    assert_fact_once(Third, ?THIRD_NS, dtx_third_mark, Tag),
    ?assertMatch(
       {ok, #{status := claimed, outcome_ref := GroupRef}},
       peer:call(
         Asker, quod_prolog, outcome,
         [maps:get(operation_ref, GroupEvidence)])),
    ok.

%% Eight independently signed, non-conflicting A -> B -> C writes enter
%% together. Each writes distinct predicate heads on B and C, so this exercises
%% the conflict-safe batch path rather than the separate wait-die abort test
%% below. The old single handoff slot rejected this shape as busy.
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
    PredicateRows = dtx_disjoint_predicates(),
    Requests =
        [begin
             Tag = erlang:unique_integer([positive]),
             GoalText = iolist_to_binary(
                          io_lib:format(
                            "\"animals\"::~s(~B).",
                            [atom_to_list(ChainPredicate), Tag])),
             {RequestBytes, Signature} = signed_goal_request(
                                           NetworkId, AgentPub, AgentKey,
                                           ?ASKER_NS, AgentAnchor,
                                           maps:get(expires_ms, Session),
                                           execute, GoalText),
             {Index, Tag, LocalPredicate, RemotePredicate,
              RequestBytes, Signature}
         end || {Index, {ChainPredicate, LocalPredicate,
                         _RemoteWriter, RemotePredicate}} <-
                    lists:zip(lists:seq(1, 8), PredicateRows)],
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
         || {Index, _Tag, _LocalPredicate, _RemotePredicate,
             RequestBytes, Signature} <- Requests],
    lists:foreach(fun(Pid) -> Pid ! {ConcurrentRef, go} end, Writers),
    Results = collect_gateway_race(ConcurrentRef, length(Requests), []),
    EvidenceByIndex =
        maps:from_list(
          [{Index, concurrent_submit_evidence(Index, Result)}
           || {Index, Result} <- Results]),
    OperationRefs =
        [maps:get(operation_ref, maps:get(Index, EvidenceByIndex))
         || {Index, _Tag, _LocalPredicate, _RemotePredicate,
             _RequestBytes, _Signature} <- Requests],
    ?assertEqual(length(Requests), length(lists:usort(OperationRefs))),
    lists:foreach(
      fun({Index, Tag, LocalPredicate, RemotePredicate,
           _RequestBytes, _Signature}) ->
          OperationRef = maps:get(
                           operation_ref, maps:get(Index, EvidenceByIndex)),
          {#{status := claimed, outcome_ref := GroupRef},
           #{status := committed, participant_slots := Slots}} =
              wait_operation_claim(Asker, OperationRef, 600),
          ?assertMatch(
             {group, ?ASKER_NS, AgentAnchor, _, _, _}, GroupRef),
          ?assertEqual(2, length(Slots)),
          assert_fact_once(Target, ?NS, LocalPredicate, Tag),
          assert_fact_once(Third, ?THIRD_NS, RemotePredicate, Tag)
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
                   "remote_effect_created(ok).\\n\")], _Anchor).",
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
%% through the ordinary group protocol.
remote_signed_group_uses_exact_agent_request(Config) ->
    Asker = ?config(asker, Config),
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

%% A route consumer knows the certified identities but starts with no live
%% route rows.  Each missing hop parks on the one exact directory property;
%% installing the ordinary complete generation wakes that same proof.  Four
%% ontology scopes are involved even though B and D share one physical node.
remote_four_scope_chain_recovers_empty_routes(Config) ->
    Asker = ?config(asker, Config),
    TargetIdentity = {?NS, ?config(target_anchor, Config)},
    ThirdIdentity = {?THIRD_NS, ?config(third_anchor, Config)},
    Before = peer:call(Asker, quod_directory_control, stats, []),
    ok = peer:call(Asker, quod_directory, expire, [1 bsl 60]),
    ?assertEqual(
       {known, []}, peer:call(Asker, quod_directory, resolve, [?NS])),
    ?assertEqual(
       {known, []}, peer:call(Asker, quod_directory, resolve, [?THIRD_NS])),
    Parent = self(),
    ProofRef = make_ref(),
    _Caller = spawn(
                fun() ->
                    Result = peer:call(
                               Asker, quod_prolog, prove_ro,
                               [?ASKER_NS,
                                {'::', ?NS, {via_fourth, {'X'}}}],
                               60000),
                    Parent ! {ProofRef, Result}
                end),
    try
        ok = wait_route_demand(Asker, TargetIdentity, 500),
        ok = install_chain_target_generation(Config, 2),
        ok = wait_route_demand(Asker, ThirdIdentity, 500),
        ok = install_chain_third_generation(Config, 2),
        ?assertMatch(
           {ok, [#{'X' := _}], _},
           receive
               {ProofRef, ProofResult} -> ProofResult
           after 10000 ->
               ct:fail(four_scope_route_wake_timeout)
           end),
        After = peer:call(Asker, quod_directory_control, stats, []),
        ?assert(maps:get(route_demanded, After) >=
                    maps:get(route_demanded, Before) + 2),
        ?assert(maps:get(route_wakes, After) >=
                    maps:get(route_wakes, Before) + 2)
    after
        %% Restore complete generations even if the assertion failed so this
        %% suite never leaves a hidden route dependency for later cleanup.
        _ = install_chain_target_generation(Config, 3),
        _ = install_chain_third_generation(Config, 3)
    end.

wait_route_demand(_Peer, Identity, 0) ->
    ct:fail({route_demand_timeout, Identity});
wait_route_demand(Peer, Identity, Retries) ->
    case peer:call(Peer, quod_directory_control, test_control_state, []) of
        #{route_demands := Demands} ->
            case lists:member(Identity, Demands) of
                true -> ok;
                false ->
                    timer:sleep(10),
                    wait_route_demand(Peer, Identity, Retries - 1)
            end;
        _ ->
            timer:sleep(10),
            wait_route_demand(Peer, Identity, Retries - 1)
    end.

install_chain_target_generation(Config, Epoch) ->
    Asker = ?config(asker, Config),
    case peer:call(
           Asker, quod_ct, install_directory_generation,
           [?config(target_pub, Config), ?config(target_addr, Config),
            [{?NS, ?config(target_anchor, Config), validator},
             {?FOURTH_NS, ?config(fourth_anchor, Config), validator},
             {?ROOT_NS, ?config(network_id, Config), validator}],
            Epoch, 1]) of
        {ok, _} -> ok;
        Other -> Other
    end.

install_chain_third_generation(Config, Epoch) ->
    Asker = ?config(asker, Config),
    case peer:call(
           Asker, quod_ct, install_directory_generation,
           [?config(third_pub, Config), ?config(third_addr, Config),
            [{?THIRD_NS, ?config(third_anchor, Config), validator},
             {?NS, ?config(target_anchor, Config), observer}],
            Epoch, 1]) of
        {ok, _} -> ok;
        Other -> Other
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
       {ok, {phase, _, _, not_found}, []},
       peer:call(Peer, quod_simplex, dtx_endpoint_local,
                 [Ns, Request, [], 1000])).

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
            #{dtx_coordinators := Coordinators} ->
                single_coordinator_id(Coordinators);
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
              endpoint_counts => Counts};
        Other ->
            #{state => Other}
    end.

single_coordinator_id(Coordinators) when is_map(Coordinators) ->
    case maps:keys(Coordinators) of
        [GroupId] -> GroupId;
        _ -> undefined
    end;
single_coordinator_id(_Malformed) ->
    undefined.

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

append_source_marker(Config, Tag) ->
    Asker = ?config(asker, Config),
    Author = ?config(asker_pub, Config),
    Anchor = ?config(asker_anchor, Config),
    {ok, Goal} = quod_durable_term:encode_goal({test_source_marker, Tag}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    PlanDigest = crypto:hash(
                   sha256,
                   term_to_binary({test_source_marker, Tag},
                                  [deterministic])),
    Change = quod_transaction:bind_id(
               {?ASKER_NS, Anchor},
               #transaction{tx_id = <<>>,
                            origin = {?ASKER_NS, Anchor},
                            proof_id = <<0:256>>, plan_digest = PlanDigest,
                            goal = Goal, result = Result,
                            diff = [{assert,
                                     {{instance_of, pet,
                                       {stale_origin_marker, Tag}}, true}}],
                            read_check = #{}, author = Author, sig = none}),
    ?assertMatch({ok, _},
                 peer:call(Asker, quod_simplex, append,
                           [?ASKER_NS, Change], 60000)).

dtx_disjoint_predicates() ->
    [{dtx_disjoint_write_chain_1, dtx_animals_mark_1,
      dtx_third_write_1, dtx_third_mark_1},
     {dtx_disjoint_write_chain_2, dtx_animals_mark_2,
      dtx_third_write_2, dtx_third_mark_2},
     {dtx_disjoint_write_chain_3, dtx_animals_mark_3,
      dtx_third_write_3, dtx_third_mark_3},
     {dtx_disjoint_write_chain_4, dtx_animals_mark_4,
      dtx_third_write_4, dtx_third_mark_4},
     {dtx_disjoint_write_chain_5, dtx_animals_mark_5,
      dtx_third_write_5, dtx_third_mark_5},
     {dtx_disjoint_write_chain_6, dtx_animals_mark_6,
      dtx_third_write_6, dtx_third_mark_6},
     {dtx_disjoint_write_chain_7, dtx_animals_mark_7,
      dtx_third_write_7, dtx_third_mark_7},
     {dtx_disjoint_write_chain_8, dtx_animals_mark_8,
      dtx_third_write_8, dtx_third_mark_8}].

dtx_disjoint_target_rules() ->
    [io_lib:format(
       "~s(X) :- assertz(~s(X)), third::~s(X).~n",
       [atom_to_list(Chain), atom_to_list(Local),
        atom_to_list(RemoteWriter)])
     || {Chain, Local, RemoteWriter, _RemoteFact} <-
            dtx_disjoint_predicates()].

dtx_disjoint_third_rules() ->
    [io_lib:format(
       "~s(X) :- assertz(~s(X)).~n",
       [atom_to_list(RemoteWriter), atom_to_list(RemoteFact)])
     || {_Chain, _Local, RemoteWriter, RemoteFact} <-
            dtx_disjoint_predicates()].

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

completed_remote_operation(Target, OperationRef, 0) ->
    ct:fail(
      {operation_completion_timeout, OperationRef,
       peer:call(Target, quod_simplex, stats, [?ASKER_NS])});
completed_remote_operation(Target, OperationRef, Remaining) ->
    case peer:call(Target, quod_prolog, outcome, [OperationRef]) of
        {ok, #{status := claimed, operation_state := terminal,
               outcome_ref := {applications, [OutcomeRef]}, included := Included}} ->
            ?assertEqual([{quod_operation_vector:target(OutcomeRef),
                           {included, OutcomeRef}}], Included),
            case peer:call(Target, quod_prolog, outcome, [OutcomeRef]) of
                {ok, #{status := committed, ref := OutcomeRef}} -> OutcomeRef;
                _ ->
                    timer:sleep(50),
                    completed_remote_operation(
                      Target, OperationRef, Remaining - 1)
            end;
        _ ->
            timer:sleep(50),
            completed_remote_operation(Target, OperationRef, Remaining - 1)
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
    ?assertEqual(#{}, maps:get(groups, Dtx)),
    ?assertEqual(#{}, maps:get(conflicts, Dtx)),
    ?assertEqual(#{}, maps:get(apply_fences, Dtx)).

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

submit_signed_execute(Config, GoalText) ->
    NetworkId = ?config(network_id, Config),
    AgentPub = ?config(agent_pub, Config),
    AgentKey = ?config(agent_key, Config),
    AgentAnchor = ?config(asker_anchor, Config),
    Session = ?config(client_session, Config),
    {RequestBytes, Signature} = signed_goal_request(
                                  NetworkId, AgentPub, AgentKey,
                                  ?ASKER_NS, AgentAnchor,
                                  maps:get(expires_ms, Session), execute,
                                  GoalText),
    peer:call(
      ?config(asker, Config), quod_client_goal_ingress, submit,
      [execute, maps:get(session_id, Session), RequestBytes, Signature,
       ?config(client_peer, Config)], 60000).

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
    %% Runtime lifecycle preparation may legitimately use the application's
    %% default data root. Keep that root private to this peer and CT run: the
    %% VM-local unique_integer/1 sequence restarts in later runs, so sharing
    %% the developer cache could reopen an old genesis under a dead test key.
    CacheDir = filename:join(
                 ?config(priv_dir, Config),
                 atom_to_list(Name) ++ "_cache"),
    true = peer:call(
             Peer, os, putenv, ["XDG_CACHE_HOME", CacheDir]),
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
    _ = DirectoryAllowlist,
    Set(directory, #{ttl_ms => 600000, expire_tick_ms => 60000}),
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

start_join_namespace(Peer, Pub, Ns, Anchor, Seeds, Config) ->
    DataDir = filename:join(
                ?config(priv_dir, Config),
                unicode:characters_to_list(
                  [atom_to_list(peer:call(Peer, erlang, node, [])),
                   "_observer_", Ns])),
    Cfg = #{node_id => Pub, mode => join, genesis_hash => Anchor,
            data_dir => DataDir, seed_peers => Seeds},
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
    wait_ready(Peer, Ns, Goal, 750).

wait_ready(Peer, Ns, _Goal, 0) ->
    ct:fail(
      {ontology_never_ready, Ns,
       #{children => peer:call(Peer, quod_ns_sup, children, []),
         desired => peer:call(
                      Peer, application, get_env,
                      [quod, namespace_desired, undefined]),
         genesis => peer:call(Peer, quod_simplex, genesis_hash, [Ns]),
         status => peer:call(Peer, quod_simplex, status, [Ns]),
         prolog => peer:call(Peer, quod_prolog, stats, [Ns])}});
wait_ready(Peer, Ns, Goal, Retries) ->
    case peer:call(Peer, quod_prolog, prove, [Ns, Goal], 5000) of
        {error, rebuilding} ->
            timer:sleep(20),
            wait_ready(Peer, Ns, Goal, Retries - 1);
        {ok, _, _} -> ok;
        Other -> ct:fail({not_ready, Ns, Other})
    end.

wait_scope_workers(_Peer, _Expected, 0) -> ct:fail(scope_worker_timeout);
wait_scope_workers(Peer, Expected, Retries) ->
    wait_engine_stat(Peer, ?NS, scope_workers, Expected, Retries).

wait_engine_stat(_Peer, _Ns, _Key, _Expected, 0) ->
    ct:fail(engine_stat_timeout);
wait_engine_stat(Peer, Ns, Key, Expected, Retries) ->
    Stats = peer:call(Peer, quod_prolog, stats, [Ns]),
    case maps:get(Key, Stats, undefined) of
        Expected -> ok;
        _ ->
            timer:sleep(10),
            wait_engine_stat(Peer, Ns, Key, Expected, Retries - 1)
    end.

key_before(TargetPub) ->
    {Pub, _} = Key = quod_identity:generate(),
    case Pub < TargetPub of
        true -> Key;
        false -> key_before(TargetPub)
    end.

deep_failure_rules() ->
    [[io_lib:format("deep_failure(~B) :- deep_failure(~B).~n", [N, N - 1])
      || N <- lists:seq(70, 1, -1)],
     "deep_failure(0) :- fail_with_reason(deep_bottom).\n",
     %% Build the deliberately over-depth reason at proof time.  Canonical
     %% ledger material is depth-bounded, so embedding that value as a genesis
     %% literal would test genesis rejection instead of reply truncation.
     "bounded_reason :- deep_reason_value(63, deep_bottom, Reason), !, "
     "fail_with_reason(Reason).\n"
     "deep_reason :- deep_reason_value(70, deep_bottom, Reason), !, "
     "fail_with_reason(Reason).\n"
     "deep_reason_value(0, Acc, Acc).\n"
     "deep_reason_value(N, Acc, Out) :- N > 0, Next is N - 1, "
     "deep_reason_value(Next, [Acc], Out).\n"].
