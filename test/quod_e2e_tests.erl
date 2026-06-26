-module(quod_e2e_tests).
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% single-node end-to-end: prove(write) -> commit -> apply -> read,
%%% restart-from-disk -> replay, prolog-only restart -> rebuild, and
%%% the failure paths the review flagged (no ETS leak on failing proofs).
%%%===================================================================

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    U   = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_e2e_" ++ U),
    Ns  = list_to_binary("e2e:" ++ U),
    Cfg = #{node_id => {"127.0.0.1", 5000}, data_dir => Dir, mode => create},
    {Dir, Ns, Cfg}.

cleanup({Dir, Ns, _Cfg}) ->
    case quod_reg:where({quod_ns, Ns}) of
        undefined -> ok;
        Pid       -> stop_ns(Pid)
    end,
    _ = file:del_dir_r(Dir),
    ok.

e2e_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun t_write_read/1,
      fun t_restart_reload/1,
      fun t_prolog_restart_rebuild/1,
      fun t_failing_proofs_no_ets_leak/1]}.

%%%===================================================================
%%% helpers
%%%===================================================================

start_ns(Ns, Cfg) ->
    {ok, Pid} = quod_ns:start_link(Ns, Cfg),
    unlink(Pid),
    Pid.

stop_ns(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> ok end.

%% prove, retrying only while the engine is still rebuilding (a transient state
%% right after (re)start). `fail`/`{ok,_,_}`/other answers are returned as-is.
rp(Ns, Goal) -> rp(Ns, Goal, 300).
rp(_Ns, _Goal, 0) -> {error, timeout};
rp(Ns, Goal, N) ->
    case quod_prolog:prove(Ns, Goal, Ns) of
        {error, rebuilding} -> timer:sleep(10), rp(Ns, Goal, N - 1);
        R -> R
    end.

wait_new_pid(Key, OldPid) -> wait_new_pid(Key, OldPid, 300).
wait_new_pid(_K, _Old, 0) -> error(timeout);
wait_new_pid(Key, OldPid, N) ->
    case quod_reg:where(Key) of
        P when is_pid(P), P =/= OldPid -> P;
        _ -> timer:sleep(10), wait_new_pid(Key, OldPid, N - 1)
    end.

%%%===================================================================
%%% tests
%%%===================================================================

t_write_read({_Dir, Ns, Cfg}) ->
    fun() ->
        _Pid = start_ns(Ns, Cfg),
        %% a write goes prove -> stage -> append -> commit -> apply -> reply
        ?assertMatch({ok, [#{}], _}, rp(Ns, {assertz, {parent, tom, bob}})),
        ?assertMatch({ok, [#{'X' := bob}], _}, rp(Ns, {parent, tom, {'X'}})),
        %% an unknown predicate fails (does not crash) — unknown=fail
        ?assertEqual(fail, rp(Ns, {grandparent, tom, {'Y'}})),
        ?assertMatch(#{commit_index := 1, last_applied := 1, appends := 1, is_leader := true},
                     quod_log:stats(Ns))
    end.

t_restart_reload({_Dir, Ns, Cfg}) ->
    fun() ->
        Pid1 = start_ns(Ns, Cfg),
        {ok, _, _} = rp(Ns, {assertz, {parent, tom, bob}}),
        {ok, _, _} = rp(Ns, {assertz, {parent, ann, eve}}),
        stop_ns(Pid1),
        %% restart with the SAME data_dir: quod_log reloads the block list from disk,
        %% quod_prolog rebuilds a fresh kb by replaying it
        _Pid2 = start_ns(Ns, Cfg),
        ?assertMatch({ok, [#{'X' := bob}], _}, rp(Ns, {parent, tom, {'X'}})),
        ?assertMatch({ok, [#{'P' := ann}], _}, rp(Ns, {parent, {'P'}, eve})),
        ?assertMatch(#{commit_index := 2, last_applied := 2}, quod_log:stats(Ns))
    end.

%% quod_prolog crashes alone (rest_for_one restarts only it); the rebuild handshake
%% must refill the kb from quod_log's committed log without an apply_gap crash.
t_prolog_restart_rebuild({_Dir, Ns, Cfg}) ->
    fun() ->
        _Pid = start_ns(Ns, Cfg),
        {ok, _, _} = rp(Ns, {assertz, {item, sword}}),
        {ok, _, _} = rp(Ns, {assertz, {item, shield}}),
        Old = quod_reg:where({quod_prolog, Ns}),
        exit(Old, kill),
        _New = wait_new_pid({quod_prolog, Ns}, Old),
        %% facts survive via rebuild from quod_log (which never restarted)
        ?assertMatch({ok, [#{}], _}, rp(Ns, {item, sword})),
        ?assertMatch({ok, [#{}], _}, rp(Ns, {item, shield})),
        ?assertEqual(fail, rp(Ns, {item, bow}))
    end.

%% Every failing/unknown proof used to leak its read-set ETS table; after the fix
%% the table count must be stable across many failing proves.
t_failing_proofs_no_ets_leak({_Dir, Ns, Cfg}) ->
    fun() ->
        _Pid = start_ns(Ns, Cfg),
        ?assertEqual(fail, rp(Ns, {nope, x})),   %% also waits for readiness
        Before = length(ets:all()),
        _ = [?assertEqual(fail, quod_prolog:prove(Ns, {undefined_pred, k}, Ns))
             || _ <- lists:seq(1, 50)],
        After = length(ets:all()),
        ?assert(After =< Before + 2)
    end.
