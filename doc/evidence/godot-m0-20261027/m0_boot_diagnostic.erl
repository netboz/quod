-module(m0_boot_diagnostic).
-export([run/0, observe/0]).

run() ->
    io:format("priv_directory=~p~n",[code:priv_dir(quod)]),
    Dir = "/tmp/quod-m0-boot-diagnostic-02",
    ok = filelib:ensure_dir(filename:join(Dir,"placeholder")),
    try quod_ask_SUITE:init_per_suite([{priv_dir,Dir}]) of
        Config ->
            io:format("fixture_started_without_deadline_change~n"),
            try quod_ask_SUITE:proof_policy_refusal_local_and_remote(Config)
            after quod_ask_SUITE:end_per_suite(Config) end,
            ok
    catch
        exit:{timeout,{gen_server,call,[Peer,{call,application,ensure_all_started,[quod]},5000]}} ->
            io:format("startup_timeout_peer=~p~n",[Peer]),
            try io:format("startup_observation=~p~n",[peer:call(Peer,?MODULE,observe,[],2000)])
            after peer:stop(Peer) end,
            blocked;
        Class:Reason:Stack ->
            io:format("diagnostic_failure=~p:~p ~p~n",[Class,Reason,Stack]),
            blocked
    end.

observe() ->
    %% No dictionary, messages, environment or state records: stacks/arity only.
    Rows = [{P,process_info(P,[registered_name,current_function,current_stacktrace,
                              message_queue_len,status])} || P <- processes()],
    lists:sublist([Row || Row = {_,Info} <- Rows, Info =/= undefined,
        lists:any(fun({M,_,_,_}) -> relevant(M); (_) -> false end,
                  proplists:get_value(current_stacktrace,Info,[]))],64).

relevant(code_server) -> true;
relevant(erl_prim_loader) -> true;
relevant(application_controller) -> true;
relevant(application_master) -> true;
relevant(M) -> lists:prefix("quod_",atom_to_list(M)).
