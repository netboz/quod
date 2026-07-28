-module(quod_directory_predicates_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

directory_host_enumerates_live_system_routes_test() ->
    Ns = <<"quod:agent">>,
    K1 = key(1),
    K2 = key(2),
    {Goal, Erl0} = with_directory(
      #{allowlist => #{Ns => [K1, K2]}},
      fun(Pid) ->
          {ok, _} = quod_directory:install_record(
                 K2, {<<"node-b">>, 4002}, [Ns], 1, 1),
          {ok, _} = quod_directory:install_record(
                 K1, {<<"node-a">>, 4001}, [Ns], 1, 1),
          Erl0 = proof_erlog(<<"quod:root">>),
          Goal = {directory_host, {':', quod, agent},
                  {'Key'}, {'Host'}, {'Port'}},
          {{succeed, First}, Erl1} = erlog:prove(Goal, Erl0),
          {{succeed, Second}, Erl2} = erlog:next_solution(Erl1),
          {fail, _} = erlog:next_solution(Erl2),
          ?assertEqual(
             [[{'Host', <<"node-a">>}, {'Key', K1}, {'Port', 4001}],
              [{'Host', <<"node-b">>}, {'Key', K2}, {'Port', 4002}]],
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
                 Key, {<<"node">>, 4003}, [Ns], 1, 1),
          {fail, _} = erlog:prove(
                        {directory_host, Ns, {'K'}, {'H'}, {'P'}},
                        proof_erlog(<<"private:body">>)),
          {fail, _} = erlog:prove(
                        {directory_host, {'Ns'}, {'K'}, {'H'}, {'P'}},
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
                        {directory_host, Ns, {'K'}, {'H'}, {'P'}},
                        proof_erlog(<<"quod:root">>))
      end).

proof_erlog(ContextNs) ->
    {ok, Erl0} = erlog:new(erlog_db_dict, null),
    Est0 = element(3, Erl0),
    Est1 = quod_predicates:load(Est0),
    Est2 = quod_predicates:set_context(
             Est1,
             quod_predicates:proof_context(ContextNs, 0, undefined)),
    setelement(3, Erl0, Est2).

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
