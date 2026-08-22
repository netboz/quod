-module(quod_directory_predicates_tests).

-include_lib("eunit/include/eunit.hrl").

directory_control_peer_is_registered_root_snapshot_query_test() ->
    K1 = key(1),
    K2 = key(2),
    BadShort = <<3>>,
    Facts = [peer_fact(K2, <<"old-b">>, 3002),
             peer_fact(K1, <<"old-a">>, 3001),
             peer_fact(K1, <<"duplicate-address">>, 3999),
             peer_fact(BadShort, <<"malformed">>, 3003)],
    Erl0 = proof_erlog(<<"quod:root">>, Facts),
    ?assertEqual(
       query,
       quod_predicates:class(
         element(3, Erl0), {directory_control_peer, 1})),
    Goal = {directory_control_peer, {'Key'}},
    {{succeed, First}, Erl1} = erlog:prove(Goal, Erl0),
    {{succeed, Second}, Erl2} = erlog:next_solution(Erl1),
    {fail, _} = erlog:next_solution(Erl2),
    %% The real dispatcher reaches the handler; duplicate membership keys are
    %% emitted once and malformed binary keys never enter the root API.
    ?assertEqual([[{'Key', K1}], [{'Key', K2}]], [First, Second]),
    {fail, _} = erlog:prove(
                  {directory_control_peer, BadShort}, Erl0),
    %% The execution namespace, not the caller process, is the boundary.
    {fail, _} = erlog:prove(
                  Goal, proof_erlog(<<"private:body">>, Facts)).

directory_control_peer_tracks_membership_snapshots_test() ->
    K1 = key(11),
    K2 = key(12),
    ?assertEqual(
       [K1],
       control_keys([peer_fact(K1, <<"first-address">>, 4011)])),
    ?assertEqual(
       [K1, K2],
       control_keys([peer_fact(K1, <<"changed-address">>, 4999),
                     peer_fact(K2, <<"second">>, 4012)])),
    ?assertEqual(
       [K2],
       control_keys([peer_fact(K2, <<"second">>, 4012)])).

directory_host_enumerates_live_system_routes_test() ->
    Ns = <<"quod:agent">>,
    K1 = key(21),
    K2 = key(22),
    {Goal, Erl0} = with_directory(
      #{allowlist => #{Ns => [K1, K2]}},
      fun(Pid) ->
          {ok, _} = quod_directory:install_record(
                 K2, {<<"node-b">>, 4002},
                 [{Ns, anchor(2), observer}], 1, 1),
          {ok, _} = quod_directory:install_record(
                 K1, {<<"node-a">>, 4001},
                 [{Ns, anchor(1), validator}], 1, 1),
          Erl0 = proof_erlog(<<"quod:root">>),
          ?assertEqual(
             undefined,
             quod_predicates:class(element(3, Erl0), {directory_host, 4})),
          ?assertEqual(
             query,
             quod_predicates:class(element(3, Erl0), {directory_host, 5})),
          Goal = {directory_host, {':', quod, agent},
                  {'Anchor'}, {'Key'}, {'Host'}, {'Port'}},
          {{succeed, First}, Erl1} = erlog:prove(Goal, Erl0),
          {{succeed, Second}, Erl2} = erlog:next_solution(Erl1),
          {fail, _} = erlog:next_solution(Erl2),
          ?assertEqual(
             [[{'Anchor', anchor(1)}, {'Host', <<"node-a">>},
               {'Key', K1}, {'Port', 4001}],
              [{'Anchor', anchor(2)}, {'Host', <<"node-b">>},
               {'Key', K2}, {'Port', 4002}]],
             [First, Second]),

          %% The read path is ETS-only and stays available with its owner blocked.
          ok = sys:suspend(Pid),
          try
              {{succeed, _}, _} = erlog:prove(Goal, Erl0)
          after
              ok = sys:resume(Pid)
          end,
          {Goal, Erl0}
      end),
    %% The process and all three indexes are gone: the predicate fails closed.
    {fail, _} = erlog:prove(Goal, Erl0).

directory_host_is_root_only_and_ground_namespace_only_test() ->
    Ns = <<"quod:agent">>,
    Key = key(3),
    with_directory(
      #{allowlist => #{Ns => [Key]}},
      fun(_Pid) ->
          {ok, _} = quod_directory:install_record(
                 Key, {<<"node">>, 4003},
                 [{Ns, anchor(3), validator}], 1, 1),
          {fail, _} = erlog:prove(
                        {directory_host, Ns, {'A'}, {'K'}, {'H'}, {'P'}},
                        proof_erlog(<<"private:body">>)),
          {fail, _} = erlog:prove(
                        {directory_host, {'Ns'}, {'A'}, {'K'}, {'H'}, {'P'}},
                        proof_erlog(<<"quod:root">>))
      end).

private_seed_is_not_visible_to_predicate_test() ->
    Ns = <<"private:arm">>,
    with_directory(
      #{},
      fun(_Pid) ->
          ok = quod_directory:add_direct_seed(
                 Ns, {<<"private-node">>, 4004}),
          {fail, _} = erlog:prove(
                        {directory_host, Ns, {'A'}, {'K'}, {'H'}, {'P'}},
                        proof_erlog(<<"quod:root">>))
      end).

proof_erlog(ContextNs) ->
    proof_erlog(ContextNs, []).

proof_erlog(ContextNs, Facts) ->
    {ok, Erl0} = erlog:new(erlog_db_dict, null),
    Est0 = element(3, Erl0),
    Est1 = quod_predicates:load_modules(
             quod_predicates:load(Est0),
             [quod_directory_predicates]),
    Est2 = quod_ct:assert_facts(Facts, Est1),
    %% Query bridges run in the local proof overlay. This focused handler test
    %% uses an in-memory dictionary rather than a published MVCC snapshot, so
    %% it deliberately does not enable plan read-set capture.
    Est3 = quod_erlog_db_local_prove:wrap_state(Est2),
    Est4 = quod_predicates:set_context(
             Est3,
             quod_predicates:proof_context(ContextNs, 0, undefined)),
    setelement(3, Erl0, Est4).

control_keys(Facts) ->
    Goal = {findall, {'Key'},
            {directory_control_peer, {'Key'}}, {'Keys'}},
    {{succeed, Bindings}, _} =
        erlog:prove(Goal, proof_erlog(<<"quod:root">>, Facts)),
    proplists:get_value('Keys', Bindings).

peer_fact(Key, Host, Port) ->
    {peer_admitted, Key, Host, Port, Key}.

with_directory(Opts, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, Pid} = quod_directory:start_link(
                  maps:merge(
                    #{expire_tick_ms => 60000, ttl_ms => 10000,
                      renew_min_ms => 1},
                    Opts)),
    try
        Fun(Pid)
    after
        _ = catch gen_server:stop(Pid)
    end.

key(N) -> <<N:256>>.

anchor(N) -> <<N:256>>.
