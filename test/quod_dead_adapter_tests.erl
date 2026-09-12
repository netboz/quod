-module(quod_dead_adapter_tests).
-include_lib("eunit/include/eunit.hrl").

removed_unused_adapters_test_() ->
    [{lists:flatten(io_lib:format("~p:~p/~p", [M, F, A])), fun() ->
        {module, M} = code:ensure_loaded(M),
        ?assertNot(erlang:function_exported(M, F, A))
    end} || {M, F, A} <-
        [{quod_proof_session, run_first_with_dependencies, 3},
         {quod_proof_session, absorb_live_bridges, 2},
         {quod_erlog_db_local_prove, absorb_live_bridges, 2},
         {quod_dtx, live_bridges_bytes, 1},
         {quod_dtx, live_bridges, 1},
         {quod_committed_projection, target, 1},
         {quod_client_goal, digest, 1}]].

exclusive_bridge_merge_validator_is_removed_test() ->
    M = quod_erlog_db_local_prove,
    {ok, {M, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(M), [abstract_code]),
    ?assertEqual([], [Name || {function, _, Name, _, _} <- Forms,
                              Name =:= valid_bridge]).

canonical_dependency_and_validation_interfaces_remain_test_() ->
    [{lists:flatten(io_lib:format("~p:~p/~p", [M, F, A])), fun() ->
        {module, M} = code:ensure_loaded(M),
        ?assert(erlang:function_exported(M, F, A))
    end} || {M, F, A} <-
        [{quod_proof_session, run_first, 3},
         {quod_proof_session, absorb_read_set, 2},
         {quod_proof_session, live_bridges, 1},
         {quod_erlog_db_local_prove, absorb_read_set, 2},
         {quod_dtx, material, 1},
         {quod_dtx, verify, 1},
         {quod_committed_projection, apply_entry, 3},
         {quod_client_goal, verify_for, 5}]].
