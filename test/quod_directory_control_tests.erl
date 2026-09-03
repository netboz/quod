-module(quod_directory_control_tests).
-include_lib("eunit/include/eunit.hrl").

one_generation_wire_rejects_old_shapes_test() ->
    Page = <<1,2,3>>,
    Frame = term_to_binary({quod_directory_generation, Page}, [deterministic]),
    ?assertEqual({generation, Page}, quod_directory_control:decode_control(Frame)),
    ?assertEqual(
       resync_request,
       quod_directory_control:decode_control(
         term_to_binary(quod_directory_generation_resync, [deterministic]))),
    ?assertEqual(
       error,
       quod_directory_control:decode_control(
         term_to_binary({quod_directory_announce, Page}, [deterministic]))),
    ?assertEqual(
       error,
       quod_directory_control:decode_control(
         term_to_binary({quod_directory_snapshot, [Page], done},
                        [deterministic]))).

root_system_and_node_rows_use_separate_authorities_test() ->
    Root = {<<"quod:root">>, key(10), validator, bootstrap},
    System = {<<"quod:system">>, key(11), observer, system},
    Node = {<<"quod:ordinary">>, key(12), validator, node},
    ?assertEqual({[Root, System], [Node]},
                 quod_directory_control:test_partition_hosted(
                   [Root, System, Node])).

root_peer_proof_is_closed_and_exact_test() ->
    K1 = key(1), K2 = key(2),
    ?assertEqual(
       {ok, 7, #{K1 => true, K2 => true}},
       quod_directory_control:test_validate_peer_proof(
         {ok, [#{'DirectoryControlKeys' => [K1, K2]}], 7})),
    ?assertEqual(
       {error, malformed_peer_keys},
       quod_directory_control:test_validate_peer_proof(
         {ok, [#{'DirectoryControlKeys' => [K1, K1]}], 7})),
    ?assertMatch(
       {error, _},
       quod_directory_control:test_validate_peer_proof({ok, [#{}], 7})).

manager_snapshot_is_bound_to_current_pid_and_revision_test() ->
    with_control(fun() ->
        Manager = spawn(fun wait/0),
        Other = spawn(fun wait/0),
        try
            ok = quod_directory_control:test_set_manager_epoch(Manager),
            quod_directory_control:hosting_changed(
              Other, 1, [hosting_row(<<"quod:wrong">>)], []),
            _ = quod_directory_control:stats(),
            S0 = quod_directory_control:test_control_state(),
            ?assertEqual(-1, maps:get(hosting_revision, S0)),
            quod_directory_control:hosting_changed(
              Manager, 2, [hosting_row(<<"quod:right">>)], []),
            _ = quod_directory_control:stats(),
            S1 = quod_directory_control:test_control_state(),
            ?assertEqual(2, maps:get(hosting_revision, S1)),
            ?assertEqual([hosting_row(<<"quod:right">>)],
                         maps:get(hosting_projection, S1))
        after
            Other ! stop, Manager ! stop
        end
    end).

with_control(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    stop_control(),
    {ok, Pid} = quod_directory_control:start_link(#{}),
    try Fun()
    after catch gen_server:stop(Pid) end.

stop_control() ->
    case quod_reg:where({directory, control}) of
        P when is_pid(P) -> catch gen_server:stop(P);
        _ -> ok
    end.

hosting_row(Ns) ->
    #{namespace => Ns, anchor => crypto:hash(sha256, Ns),
      source => node, visibility => discoverable}.

wait() ->
    receive stop -> ok end.

key(N) -> crypto:hash(sha256, term_to_binary({key, N})).
