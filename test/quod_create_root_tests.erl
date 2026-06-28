-module(quod_create_root_tests).
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% create-a-network: the founder reads quod_root.pl once and commits it
%%% into the ledger as the genesis; the content is queryable; a restart
%%% REPLAYS it (does not re-create); a bad genesis .pl fails the start.
%%%===================================================================

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    U   = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_create_root_" ++ U),
    Ns  = list_to_binary("createroot:" ++ U),
    Content = #{namespace    => Ns,
                mode         => create,
                genesis_file => <<"ontologies/quod_root.pl">>,
                data_dir     => list_to_binary(Dir),
                seeds        => []},
    {Dir, Ns, Content}.

cleanup({Dir, Ns, _}) ->
    case quod_reg:where({quod_ns, Ns}) of
        undefined -> ok;
        Pid       -> stop_ns(Pid)
    end,
    _ = file:del_dir_r(Dir),
    ok.

create_root_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun t_create_root/1,
      fun t_create_root_restart/1,
      fun t_genesis_failure/1]}.

%% genesis_diff compiles the real quod_root.pl into write-set ops (compiled clause
%% bodies, the on-disk form). Every op is an assert; the acl_sovereign head is present.
genesis_diff_test() ->
    File = filename:join(code:priv_dir(quod), "ontologies/quod_root.pl"),
    Ops  = quod_prolog:genesis_diff(File),
    ?assert(length(Ops) >= 3),
    ?assert(lists:all(fun({assert, {_H, _B}}) -> true; (_) -> false end, Ops)),
    Heads = [H || {assert, {H, _B}} <- Ops],
    ?assert(lists:member({acl_sovereign, 'quod:root'}, Heads)).

%%%===================================================================
%%% helpers (mirror quod_e2e_tests)
%%%===================================================================

start_ns(Ns, Cfg) ->
    {ok, Pid} = quod_ns:start_link(Ns, Cfg),
    unlink(Pid),
    Pid.

stop_ns(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ok end.

rp(Ns, Goal) -> rp(Ns, Goal, 300).
rp(_Ns, _Goal, 0) -> {error, timeout};
rp(Ns, Goal, N) ->
    case quod_prolog:prove(Ns, Goal, Ns) of
        {error, rebuilding} -> timer:sleep(10), rp(Ns, Goal, N - 1);
        R -> R
    end.

%%%===================================================================
%%% tests
%%%===================================================================

t_create_root({_Dir, Ns, Content}) ->
    fun() ->
        {Ns, NsCfg} = quod_app:build_ns_config(Content),
        _Pid = start_ns(Ns, NsCfg),
        %% the genesis content from quod_root.pl is committed + applied into the kb
        ?assertMatch({ok, [#{}], _}, rp(Ns, {acl_sovereign, 'quod:root'})),
        ?assertMatch({ok, [#{}], _},
                     rp(Ns, {system_ontology, 'quod:root', 'quod_root.pl', [], []})),
        %% the default-open can_read/3 rule unifies with anything
        ?assertMatch({ok, [#{}], _}, rp(Ns, {can_read, foo, bar, baz})),
        %% index 1 = founding {add,self} config; index 2 = the genesis content block
        ?assertMatch(#{commit_index := 2, last_applied := 2, is_leader := true},
                     quod_ledger:stats(Ns))
    end.

t_create_root_restart({_Dir, Ns, Content}) ->
    fun() ->
        {Ns, NsCfg} = quod_app:build_ns_config(Content),
        Pid1 = start_ns(Ns, NsCfg),
        ?assertMatch({ok, [#{}], _}, rp(Ns, {acl_sovereign, 'quod:root'})),
        #{commit_index := CI1} = quod_ledger:stats(Ns),
        stop_ns(Pid1),
        %% restart from the same data_dir is a JOIN: replay the local ledger (the
        %% genesis is already there) — do NOT re-read the .pl, do NOT re-create.
        _Pid2 = start_ns(Ns, NsCfg),
        ?assertMatch({ok, [#{}], _}, rp(Ns, {acl_sovereign, 'quod:root'})),
        #{commit_index := CI2} = quod_ledger:stats(Ns),
        ?assertEqual(CI1, CI2)   %% no extra genesis block appended
    end.

t_genesis_failure({_Dir, Ns, Content}) ->
    fun() ->
        Bad = Content#{genesis_file => <<"ontologies/does_not_exist.pl">>},
        {Ns, NsCfg} = quod_app:build_ns_config(Bad),
        %% quod_ledger init returns {stop, {genesis_failed, _}} ⇒ the sub-sup fails to
        %% start (fail-fast). Run it in a trap-exit helper so the failed supervisor's
        %% link doesn't take down the eunit test process.
        ?assertMatch({error, _}, start_link_isolated(Ns, NsCfg))
    end.

start_link_isolated(Ns, NsCfg) ->
    Parent = self(),
    spawn(fun() ->
              process_flag(trap_exit, true),
              Parent ! {start_result, (catch quod_ns:start_link(Ns, NsCfg))}
          end),
    receive {start_result, R} -> R after 5000 -> {error, timeout} end.
