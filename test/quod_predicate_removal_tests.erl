-module(quod_predicate_removal_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

signed_definition_removal_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(C = #{namespace := Ns}) ->
            committed(Ns, {retract, {empty_defined, last}}),
            holds(Ns, {current_predicate, {'/', empty_defined, 1}}),
            denied(Ns, {transaction, conjunction([
                {abolish, {'/', likes, 2}}, '!', fail])}),
            holds(Ns, {likes, alice, bob}),
            {Bytes, Sig, _} = committed(Ns, {transaction, {abolish, {'/', likes, 2}}}),
            absent(Ns, {current_predicate, {'/', likes, 2}}),
            holds(Ns, {unaffected, kept}),
            holds(Ns, {current_predicate, {'/', empty_defined, 1}}),
            committed(Ns, {abolish, {'/', empty_defined, 1}}),
            absent(Ns, {current_predicate, {'/', empty_defined, 1}}),
            %% Restore the decided operation through the original ontology owner.
            Anchor = quod_simplex:genesis_hash(Ns), Height = quod_prolog:applied(Ns),
            restart(C, Ns, Anchor),
            try
                ?assertEqual(Height, quod_prolog:applied(Ns)),
                absent(Ns, {current_predicate, {'/', likes, 2}}),
                absent(Ns, {current_predicate, {'/', empty_defined, 1}}),
                holds(Ns, {unaffected, kept}),
                ?assertMatch({ok, _, {operation_outcome, _, #{status := completed,
                    targets := [{{Ns, Anchor}, {committed, _}}]}}},
                    quod_client_goal_ingress:resolve_operation(Bytes, Sig)),
                quod_space_tests:await_runtime(Ns),
                quod_lobby_tests:assert_read_has_no_io(fun() ->
                    [begin absent(Ns, {current_predicate, {'/', likes, 2}}),
                           holds(Ns, {unaffected, kept}) end || _ <- lists:seq(1, 3)]
                end)
            after stop_namespace(Ns) end
        end, [{likes, alice, bob}, {empty_defined, last}, {unaffected, kept}])
    end}.

signed_origin_removal_recovery_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(C = #{node := {agent_instance_ref, Ns, Anchor, _}}) ->
            committed(Ns, {assertz, {origin_definition, saved}}),
            {Bytes, Sig, _} = committed(Ns, {abolish, {'/', origin_definition, 1}}),
            restart(C, Ns, Anchor),
            try
                absent(Ns, {current_predicate, {'/', origin_definition, 1}}),
                ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}},
                    quod_client_goal_ingress:resolve_operation(Bytes, Sig))
            after stop_namespace(Ns) end
        end)
    end}.

signed_denial_atomic_rollback_and_conflict_test_() ->
    {timeout, 90, fun() ->
        quod_agent_hosting_tests:with_host(fun(C = #{namespace := Ns, node := Node,
                                                    directory := Dir, identity := Identity}) ->
            Other = <<"abolish-other">>, Denied = <<"abolish-denied">>,
            Sup = quod_agent_hosting_tests:start_ontology(Other, Dir, Identity, [],
                [{can_invoke, {'_'}, Node, {'_'}, {'_'}}, {likes, other, value}]),
            Locked = quod_agent_hosting_tests:start_ontology(Denied, Dir, Identity, [],
                [{can_invoke, {current_predicate, {'_'}}, Node, {'_'}, {'_'}}, {likes, locked, value}]),
            try
                {DeniedBytes, DeniedSig} = sign(execute, Denied, {abolish, {'/', likes, 2}}),
                {ok, _, {normalized, {failed, DeniedReasons}}} =
                    quod_client_goal_ingress:submit(DeniedBytes, DeniedSig),
                ?assertEqual({ok, [{not_allowed, Denied}]},
                             quod_wire_term:decode_failure_reasons(DeniedReasons)),
                holds(Denied, {current_predicate, {'/', likes, 2}}),
                Both = conjunction([{abolish, {'/', likes, 2}},
                                    {'::', Other, {abolish, {'/', likes, 2}}}]),
                denied(Ns, {transaction, {',', Both, fail}}),
                holds(Ns, {likes, alice, bob}), holds(Other, {likes, other, value}),
                conflict(Ns),
                {Bytes, Sig, _} = committed(Ns, {transaction, Both}),
                absent(Ns, {current_predicate, {'/', likes, 2}}),
                absent(Other, {current_predicate, {'/', likes, 2}}),
                Anchor = quod_simplex:genesis_hash(Other), restart(C, Other, Anchor),
                absent(Other, {current_predicate, {'/', likes, 2}}),
                ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}},
                    quod_client_goal_ingress:resolve_operation(Bytes, Sig))
            after
                stop_namespace(Other),
                quod_agent_hosting_tests:stop_ontology(Sup),
                quod_agent_hosting_tests:stop_ontology(Locked)
            end
        end, [{likes, alice, bob}, {racing, original}])
    end}.

conflict(Ns) ->
    true = quod_reg:reg({host_test, local_proof}), Parent = self(),
    {Bytes, Sig} = sign(execute, Ns, {',', {abolish, {'/', racing, 1}}, test_local_wait}),
    {Caller, Monitor} = spawn_monitor(fun() ->
        Parent ! {removal_result, self(), quod_client_goal_ingress:submit(Bytes, Sig)}
    end),
    try
        Worker = receive {local_proof_waiting, Pid, _} -> Pid
                 after 10000 -> error(removal_not_prepared) end,
        committed(Ns, {assertz, {racing, concurrent}}),
        Worker ! release,
        Result = receive {removal_result, Caller, R} -> R
                 after 15000 -> error(removal_not_resolved) end,
        ?assertMatch({ok, _, {normalized, {error, conflict_retry}}}, Result),
        holds(Ns, {racing, original}), holds(Ns, {racing, concurrent}),
        receive {'DOWN', Monitor, process, Caller, normal} -> ok
        after 5000 -> error(removal_caller_not_finished) end
    after
        gproc:unreg(quod_reg:name({host_test, local_proof})),
        exit(Caller, kill)
    end.

empty_definition_has_durable_write_and_conflict_key_test() ->
    Est = quod_ct:committed_kb([{empty, last}]),
    {ok, Empty0} = quod_diff:apply_ops(Est, [{retract, {{empty, last}, true}}]),
    Empty = quod_ct:commit_kb(Empty0, 2, 1),
    Wrapped = quod_erlog_db_local_prove:wrap_state(Empty, #{read_set => true}),
    try
        {succeed, Removed = #est{db = #db{ref = Overlay}}} =
            erlog_int:prove_goal({abolish, {'/', empty, 1}}, Wrapped),
        Ops = quod_erlog_db_local_prove:get_local_changes(Overlay),
        ?assertEqual([{abolish, {empty, 1}}], Ops),
        ?assertEqual(1, quod_erlog_db_local_prove:provenance(Removed)),
        ?assertMatch(#{writes := [{<<"empty">>, 1}]},
            quod_dtx:conflict_descriptor(Ops, #{}, [])),
        {ok, Applied, Ops} = quod_diff:apply_ops_report(Empty, Ops),
        ?assertEqual(undefined, quod_erlog_db_mvcc:get_procedure_type(
            (Applied#est.db)#db.ref, {empty, 1})),
        ?assertMatch({ok, _, []}, quod_diff:apply_ops_report(Applied, Ops)),
        {ok, Wire} = quod_wire_term:encode_canonical(Ops),
        ?assertEqual({ok, Ops}, quod_wire_term:decode_canonical(Wire, unlimited)),
        ?assert(quod_diff:valid_ops(Ops)),
        [?assertNot(quod_diff:valid_ops([Bad])) || Bad <-
            [{abolish, {empty, -1}}, {abolish, {empty, 1.0}}, {abolish, {{0}, 1}}]],
        ?assert(quod_diff:touches_functor([{abolish, {peer_admitted, 4}}], {peer_admitted, 4})),
        ?assertNot(quod_simplex:membership_diff_acceptable([{abolish, {peer_admitted, 4}}], [<<1:256>>]))
    after quod_erlog_db_local_prove:cleanup_read_set(Wrapped),
          quod_erlog_db_mvcc:delete((Est#est.db)#db.ref) end.

sign(Mode, Ns, Goal) ->
    {ok, Bytes, Sig} = quod_node_actor:signed_goal(Mode, {'::', Ns, Goal},
        crypto:strong_rand_bytes(32), quod_time:now_ms() + 20000),
    {Bytes, Sig}.
committed(Ns, Goal) ->
    {Bytes, Sig} = sign(execute, Ns, Goal),
    Result = quod_client_goal_ingress:submit(Bytes, Sig),
    {ok, Evidence, {normalized, {committed, _, _}}} = Result,
    Operation = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state := terminal},
        quod_ct:await_operation_complete(element(2, Operation), Operation, 10000)),
    {Bytes, Sig, Result}.
denied(Ns, Goal) ->
    {Bytes, Sig} = sign(execute, Ns, Goal),
    ?assertMatch({ok, _, {normalized, fail}}, quod_client_goal_ingress:submit(Bytes, Sig)).
holds(Ns, Goal) ->
    {Bytes, Sig} = sign(read, Ns, Goal),
    ?assertMatch({ok, _, {normalized, {read, _, {answers, _, [_ | _]}}}},
        quod_client_goal_ingress:submit(Bytes, Sig)).
absent(Ns, Goal) ->
    {Bytes, Sig} = sign(read, Ns, Goal),
    ?assertMatch({ok, _, {normalized, {read, _, fail}}},
        quod_client_goal_ingress:submit(Bytes, Sig)).
conjunction([G]) -> G;
conjunction([G | Rest]) -> {',', G, conjunction(Rest)}.
stop_namespace(Ns) -> quod_agent_hosting_tests:stop_ontology(quod_reg:where({quod_ns, Ns})).
restart(#{directory := Dir, identity := Identity}, Ns, Anchor) ->
    stop_namespace(Ns),
    {_, _} = quod_lobby_tests:start_namespace(Ns,
        #{node_id => maps:get(pubkey, Identity), identity => Identity,
          data_dir => filename:join(Dir, binary_to_list(Ns)), mode => join,
          genesis_hash => Anchor}),
    ok.
