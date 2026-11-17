-module(selection_cost_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-export([observe_0/3]).

ordinary_choicepoints_require_no_checkpoint_scan_test() ->
    with_state(fun(St) ->
        Many=lists:foldl(fun(_,Acc)->
            erlog_int:push_choicepoint(#cp{type=compiled},Acc)
        end,St,lists:seq(1,256)),
        MFA={quod_erlog_db_local_prove,live_transaction_tokens,2},
        Trace=trace:session_create(selection_cost,self(),[]),
        try
            trace:function(Trace,MFA,true,[local,call_count]),
            ?assertEqual([],quod_erlog_db_local_prove:live_transaction_tokens(Many)),
            {call_count,Count}=trace:info(Trace,MFA,call_count),
            ?assertEqual(0,Count)
        after trace:session_destroy(Trace) end
    end).

nested_checkpoint_mode_keeps_real_pending_tokens_test() ->
    with_state(fun(St) ->
        {ok,_}=quod_transaction_scope:with_invocation(
          {<<1:128>>,<<2:128>>},quod_transaction_scope:empty_selection(),undefined,fun()->
            Frame=quod_transaction_scope:enter(St),
            Enabled=erlog_int:enter_choicepoint_checkpoints(
                erlog_int:enter_choicepoint_checkpoints(St)),
            Pushed=erlog_int:push_choicepoint(#cp{type=compiled},Enabled),
            ?assertEqual([{pending,Frame}],quod_erlog_db_local_prove:live_transaction_tokens(Pushed)),
            Parent=erlog_int:leave_choicepoint_checkpoints(Pushed),
            ?assertEqual([{pending,Frame}],quod_erlog_db_local_prove:live_transaction_tokens(Parent)),
            ok=quod_transaction_scope:finish(Frame),ok
          end)
    end).

finished_and_failed_savepoints_retire_their_checkpoint_choicepoints_test() ->
    with_state(fun(St)->
        {ok,_}=quod_transaction_scope:with_invocation(
          {<<3:128>>,<<4:128>>},quod_transaction_scope:empty_selection(),undefined,fun()->
            Step={',',{member,{'Choice'},[a,b]},observe_checkpoint},
            Goals=[{transaction,Step},
                   {';', {transaction,{',',{once,Step},fail}},true}],
            lists:foreach(fun(Goal)->
                erase(selection_cost_observed),
                {succeed,Final}=erlog_int:prove_goal(Goal,St),
                {Depth,Tokens}=get(selection_cost_observed),
                ?assert(Depth>0),?assertMatch([{pending,_}],Tokens),
                ?assertEqual(0,Final#est.checkpoint_depth),
                ?assertEqual([],quod_erlog_db_local_prove:live_transaction_tokens(Final))
            end,Goals),ok
          end)
    end).

observe_0(observe_checkpoint,Next,St) ->
    put(selection_cost_observed,{St#est.checkpoint_depth,
        quod_erlog_db_local_prove:live_transaction_tokens(St)}),
    erlog_int:prove_body(Next,St).

with_state(Fun) ->
    C0=quod_committed_projection:new_est(),
    D=erlog_int:add_compiled_proc({observe_checkpoint,0},?MODULE,observe_0,C0#est.db),
    C=quod_ct:commit_kb(C0#est{db=D}),
    Wrapped=quod_erlog_db_local_prove:wrap_state(C,#{read_set=>true}),
    St=quod_predicates:set_context(Wrapped,
        quod_predicates:proof_context(<<"test:selection-cost">>,1,undefined)),
    try Fun(St)
    after
        erase(selection_cost_observed),
        quod_erlog_db_local_prove:cleanup_read_set(St),
        #est{db=#db{ref=Ref}}=C,quod_erlog_db_mvcc:delete(Ref)
    end.
