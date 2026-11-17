-module(erlog_dispatch_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-export([native_probe/3]).

interpreted_list_traversal_does_not_rewalk_completed_tails_test() ->
    Small = traversal_calls(128), Large = traversal_calls(256),
    io:format(user,"DISPATCH_DDEREF_COUNTS ~p ~p~n",[Small,Large]),
    ?assert(Large < 3 * Small).

call_time_failure_snapshot_survives_later_bindings_test() ->
    St = clauses([{':-',{later,{'X'}},{',',{'=',{'X'},changed},fail}}]),
    {fail,Final} = erlog_int:prove_goal({later,{'Value'}},St),
    ?assert(lists:member({later,unbound},Final#est.fail_reasons)),
    ?assertNot(lists:member({later,changed},Final#est.fail_reasons)).

bound_nested_call_keeps_call_time_failure_snapshot_test() ->
    St = clauses([{':-',{later,{box,{'X'}}},{',',{'=',{'X'},changed},fail}}]),
    Goal = {',',{'=',{'Value'},{box,{'Inner'}}},{later,{'Value'}}},
    {fail,Final} = erlog_int:prove_goal(Goal,St),
    ?assert(lists:member({later,{box,unbound}},Final#est.fail_reasons)).

aliased_interpreted_heads_preserve_unification_test() ->
    St = clauses([{same,{'X'},{'X'}}]),
    Goal = {',',{same,{box,{'A'}},{box,{'B'}}},
        {',',{'=',{'A'},one},{'=',{'B'},two}}},
    ?assertMatch({fail,_},erlog_int:prove_goal(Goal,St)).

native_call_still_receives_deeply_dereferenced_arguments_test() ->
    St = clauses([]),
    Db = erlog_int:add_compiled_proc({native_probe,1},?MODULE,native_probe,St#est.db),
    Goal = {',',{'=',{'Value'},[{'A'},{box,{'B'}}]},
        {',',{'=',{'A'},one},{',',{'=',{'B'},two},{native_probe,{'Value'}}}}},
    ?assertMatch({succeed,_},erlog_int:prove_goal(Goal,St#est{db=Db})).

native_probe({native_probe,[one,{box,two}]},Next,St) -> erlog_int:prove_body(Next,St);
native_probe(Goal,_,_) -> error({native_argument_contract,Goal}).

traversal_calls(Length) ->
    St = clauses([{'$walk',[]},
        {':-',{'$walk',[{'_'}|{'Rest'}]},{'$walk',{'Rest'}}}]),
    {{succeed,_},{call_count,Rows}} = tprof:profile(
        fun()->erlog_int:prove_goal({'$walk',lists:duplicate(Length,item)},St) end,
        #{type=>call_count,report=>return,pattern=>[{erlog_int,dderef,2}]}),
    lists:sum([N||{erlog_int,dderef,2,Counts}<-Rows,{_,N,_}<-Counts]).

clauses(Clauses) ->
    {ok,St0} = erlog_int:new(erlog_db_dict,null),
    Db0 = lists:foldl(fun(M,D)->M:load(D) end,St0#est.db,[erlog_bips,erlog_lib_lists]),
    St0#est{db=lists:foldl(fun erlog_int:assertz_clause/2,Db0,Clauses)}.
