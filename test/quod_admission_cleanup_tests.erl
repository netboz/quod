-module(quod_admission_cleanup_tests).
-include_lib("eunit/include/eunit.hrl").

obsolete_goal_only_interface_is_absent_test() ->
    {module, quod_client_auth} = code:ensure_loaded(quod_client_auth),
    ?assertNot(erlang:function_exported(quod_client_auth, materialize_goal, 3)).

obsolete_unsigned_plan_adapter_is_absent_test() ->
    {module, quod_prolog} = code:ensure_loaded(quod_prolog),
    ?assertNot(erlang:function_exported(quod_prolog, submit_plan, 4)).

captured_projection_is_validated_once_before_exact_evidence_test() ->
    %% Real signed/certified fixture bytes, not a consensus-admission witness.
    %% Only the owner registration is a stub; the production verifier reads the
    %% real ledger and still checks this caller's certificate and historical era.
    quod_operation_fixture:with(2, fun(F) ->
        Store = maps:get(store, F), Ns = quod_ledger_store:namespace(Store),
        true = quod_reg:reg({quod_simplex, Ns}),
        try
            View = quod_operation_fixture:view(Store, maps:get(projection, F), maps:get(entry, F)),
            Ref = maps:get(certified_target_ref, F),
            {module, quod_foreign_log} = code:ensure_loaded(quod_foreign_log),
            {{ok, Evidence}, {call_count, Counts}} = tprof:profile(fun() ->
                quod_foreign_log:verify_local_deadline(View, Ref, transaction, infinity)
            end, #{type => call_count, report => return,
                   pattern => [{quod_foreign_log, valid_projection, 2}], timeout => 5000}),
            ?assertEqual(maps:get(target, F), maps:get(identity, Evidence)),
            ?assertEqual(maps:get(application, F), maps:get(transaction, Evidence)),
            ?assertEqual(1, lists:sum([N || {quod_foreign_log, valid_projection, 2, Ps} <- Counts,
                                            {_, N, _} <- Ps]))
        after gproc:unreg(quod_reg:name({quod_simplex, Ns}))
        end
    end).
