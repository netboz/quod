-module(quod_namespace_manager_tests).

-behaviour(gen_server).

-include_lib("eunit/include/eunit.hrl").

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-record(fake, {
          parent,
          mode = normal,
          pending = none,
          children = #{}
         }).

slow_retained_ensure_outlives_the_old_deadline_test_() ->
    {timeout, 25,
     fun() ->
         with_fixture(
           fun(#{fake_sup := Fake, dir := Dir}) ->
               ok = gen_server:call(Fake, {mode, block}),
               Ns = unique_ns(<<"slow-ensure">>),
               Config = join_config(Dir),
               {Caller, Monitor} = call_async(
                                     fun() ->
                                         quod_namespace_manager:start_content(
                                           Ns, Config)
                                     end),
               receive {fake_start_waiting, Fake, Ns} -> ok after 1000 ->
                   error(start_did_not_reach_child_owner)
               end,
               receive
                   {'DOWN', Monitor, process, Caller, Early} ->
                       error({ensure_returned_before_child, Early})
               after 15200 ->
                   ok
               end,
               gen_server:cast(Fake, release),
               receive
                   {call_result, Caller, {ok, Child}} when is_pid(Child) -> ok;
                   {'DOWN', Monitor, process, Caller, Reason} ->
                       error({ensure_failed, Reason})
               after 2000 ->
                   error(ensure_completion_timeout)
               end
           end)
     end}.

terminal_child_failure_is_returned_test() ->
    with_fixture(
      fun(#{fake_sup := Fake, dir := Dir}) ->
          ok = gen_server:call(Fake, {mode, fail}),
          ?assertEqual(
             {error, terminal_child_failure},
             quod_namespace_manager:start_content(
               unique_ns(<<"terminal">>), join_config(Dir)))
      end).

manager_death_releases_unbounded_ensure_test() ->
    with_fixture(
      fun(#{manager := Manager, fake_sup := Fake, dir := Dir}) ->
          ok = gen_server:call(Fake, {mode, block}),
          Ns = unique_ns(<<"manager-death">>),
          {Caller, Monitor} = call_async(
                                fun() ->
                                    quod_namespace_manager:start_content(
                                      Ns, join_config(Dir))
                                end),
          receive {fake_start_waiting, Fake, Ns} -> ok after 1000 ->
              error(start_did_not_reach_child_owner)
          end,
          exit(Manager, kill),
          receive
              {call_result, Caller, {'EXIT', _}} -> ok;
              {'DOWN', Monitor, process, Caller, normal} -> ok;
              {'DOWN', Monitor, process, Caller, Reason} ->
                  error({unexpected_caller_exit, Reason})
          after 1000 ->
              error(unbounded_caller_not_released)
          end
      end).

mutation_worker_crash_returns_outcome_unknown_test() ->
    with_fixture(
      fun(#{fake_sup := Fake, dir := Dir}) ->
          ok = gen_server:call(Fake, {mode, kill_worker}),
          ?assertEqual(
             {error, outcome_unknown},
             quod_namespace_manager:start_content(
               unique_ns(<<"worker-crash">>), join_config(Dir)))
      end).

client_start_and_stop_calls_remain_bounded_test_() ->
    {timeout, 35,
     fun() ->
         bounded_call_case(start_new),
         bounded_call_case(stop)
     end}.

bounded_call_case(Kind) ->
    with_fixture(
      fun(#{manager := Manager, fake_sup := Fake, dir := Dir}) ->
          Ns = unique_ns(<<"bounded">>),
          Config = join_config(Dir),
          case Kind of
              stop ->
                  {ok, _} = quod_namespace_manager:start_content(Ns, Config);
              start_new ->
                  ok
          end,
          ok = sys:suspend(Manager),
          Started = erlang:monotonic_time(millisecond),
          Result = case Kind of
                       start_new ->
                           catch quod_namespace_manager:start_new_content(
                                   Ns, Config);
                       stop ->
                           catch quod_namespace_manager:stop_content(Ns)
                   end,
          Elapsed = erlang:monotonic_time(millisecond) - Started,
          ?assertMatch({'EXIT', {timeout, _}}, Result),
          ?assert(Elapsed >= 14500),
          ?assert(Elapsed < 17500),
          exit(Manager, kill),
          %% The fake child is test-owned and must not survive the fixture.
          ok = gen_server:call(Fake, stop_children)
      end).

with_fixture(Fun) ->
    Fixture = setup(),
    try Fun(Fixture)
    after cleanup(Fixture)
    end.

setup() ->
    {ok, _} = application:ensure_all_started(gproc),
    cleanup_registered(),
    Dir = filename:join(
            "/tmp",
            "quod_namespace_manager_" ++
                binary_to_list(
                  binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))),
    Saved = save_env(
              [identity_dir, namespace_desired, namespace_static_content,
               content_storage_dirs, node_actor_principal]),
    application:set_env(quod, identity_dir, Dir),
    application:set_env(
      quod, namespace_desired, #{content => #{}, brahms => #{}}),
    application:set_env(quod, namespace_static_content, #{}),
    application:set_env(quod, content_storage_dirs, #{}),
    {ok, FakeSup} = gen_server:start_link(
                      quod_reg:via({quod_ns_sup, node}), ?MODULE, self(), []),
    unlink(FakeSup),
    {ok, BrahmsSup} = quod_brahms_sup:start_link(),
    unlink(BrahmsSup),
    {ok, Manager} = quod_namespace_manager:start_link(),
    unlink(Manager),
    #{dir => Dir, saved => Saved, manager => Manager,
      fake_sup => FakeSup, brahms_sup => BrahmsSup}.

cleanup(#{dir := Dir, saved := Saved, manager := Manager,
          fake_sup := FakeSup, brahms_sup := BrahmsSup}) ->
    stop_process(Manager),
    case is_process_alive(FakeSup) of
        true -> _ = catch gen_server:call(FakeSup, stop_children);
        false -> ok
    end,
    stop_process(FakeSup),
    stop_process(BrahmsSup),
    restore_env(Saved),
    _ = file:del_dir_r(Dir),
    ok.

cleanup_registered() ->
    stop_process(quod_reg:where({namespace_manager, node})),
    stop_process(quod_reg:where({quod_ns_sup, node})),
    stop_process(quod_reg:where({quod_brahms_sup, node})).

call_async(Fun) ->
    Parent = self(),
    spawn_monitor(
      fun() -> Parent ! {call_result, self(), catch Fun()} end).

join_config(Dir) ->
    #{mode => join, genesis_hash => crypto:strong_rand_bytes(32),
      data_dir => Dir, seed_peers => []}.

unique_ns(Prefix) ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    <<Prefix/binary, "-", Suffix/binary>>.

save_env(Keys) ->
    [{Key, application:get_env(quod, Key)} || Key <- Keys].

restore_env(Saved) ->
    lists:foreach(
      fun({Key, {ok, Value}}) -> application:set_env(quod, Key, Value);
         ({Key, undefined}) -> application:unset_env(quod, Key)
      end, Saved).

stop_process(Pid) when is_pid(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 1000 -> ok end;
stop_process(_) -> ok.

init(Parent) ->
    process_flag(trap_exit, true),
    {ok, #fake{parent = Parent}}.

handle_call({mode, Mode}, _From, S) ->
    {reply, ok, S#fake{mode = Mode}};
handle_call(which_children, _From, S = #fake{children = Children}) ->
    Rows = [{{quod_ns, Ns}, Pid, supervisor, [quod_ns]}
            || {Ns, Pid} <- maps:to_list(Children), is_process_alive(Pid)],
    {reply, Rows, S};
handle_call({start_child, #{id := {quod_ns, Ns},
                            start := {quod_ns, start_link, [Ns, Config]}}},
            From, S = #fake{mode = block, parent = Parent}) ->
    Parent ! {fake_start_waiting, self(), Ns},
    {noreply, S#fake{pending = {start, From, Ns, Config}}};
handle_call({start_child, _Spec}, {Worker, _Tag},
            S = #fake{mode = kill_worker}) ->
    exit(Worker, kill),
    {noreply, S};
handle_call({start_child, _Spec}, _From, S = #fake{mode = fail}) ->
    {reply, {error, terminal_child_failure}, S};
handle_call({start_child, #{id := {quod_ns, Ns},
                            start := {quod_ns, start_link, [Ns, Config]}}},
            _From, S) ->
    {Pid, S1} = start_fake_child(Ns, Config, S),
    {reply, {ok, Pid}, S1};
handle_call({terminate_child, {quod_ns, Ns}}, _From,
            S = #fake{children = Children}) ->
    stop_process(maps:get(Ns, Children, undefined)),
    {reply, ok, S};
handle_call({delete_child, {quod_ns, Ns}}, _From,
            S = #fake{children = Children}) ->
    {reply, ok, S#fake{children = maps:remove(Ns, Children)}};
handle_call(stop_children, _From, S = #fake{children = Children}) ->
    maps:foreach(fun(_Ns, Pid) -> stop_process(Pid) end, Children),
    {reply, ok, S#fake{children = #{}}};
handle_call(_Request, _From, S) ->
    {reply, {error, unsupported}, S}.

handle_cast(release, S = #fake{pending = {start, From, Ns, Config}}) ->
    {Pid, S1} = start_fake_child(Ns, Config, S#fake{pending = none}),
    gen_server:reply(From, {ok, Pid}),
    {noreply, S1};
handle_cast(_Message, S) ->
    {noreply, S}.

handle_info({'EXIT', _Pid, _Reason}, S) ->
    {noreply, S};
handle_info(_Message, S) ->
    {noreply, S}.

terminate(_Reason, #fake{children = Children}) ->
    maps:foreach(fun(_Ns, Pid) -> stop_process(Pid) end, Children),
    ok.

start_fake_child(Ns, Config, S = #fake{children = Children}) ->
    Parent = self(),
    Anchor = maps:get(genesis_hash, Config),
    Pid = spawn(
            fun() ->
                true = quod_reg:reg({quod_ns, Ns}),
                Table = binary_to_atom(
                          <<"quod_simplex_genesis_", Ns/binary>>, utf8),
                _ = ets:new(Table, [named_table, protected, set]),
                true = ets:insert(Table, {anchor, Anchor}),
                Parent ! {fake_child_ready, self()},
                receive stop -> ok end
            end),
    receive {fake_child_ready, Pid} -> ok after 1000 ->
        error(fake_child_start_timeout)
    end,
    {Pid, S#fake{children = Children#{Ns => Pid}}}.
