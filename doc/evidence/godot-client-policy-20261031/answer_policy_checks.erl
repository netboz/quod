-module(answer_policy_checks).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

%% An output-only binding crosses the actual selected-scope worker. The input
%% is small and the value is below the enclosing scope transport capacity.
selected_scope_large_answer_test() ->
    Value = binary:copy(<<"a">>, 80000),
    Est = quod_ct:committed_kb([
        {can_invoke, {'Goal'}, {'Principal'}, {'Chain'}, {'Namespace'}},
        {answer_value, Value}]),
    #est{db = #db{ref = Db}} = Est,
    {Handle, Monitor} = quod_scope_session:start(
        <<1:128>>, <<2:256>>, self(), <<"answer:target">>, <<3:256>>,
        1, Est, self(),
        #{principal => {node, <<4:256>>}, request_binding => none,
          deadline_ms => quod_time:mono_ms() + 5000}),
    {quod_scope_session, Worker, _, Proof, Session, _, _} = Handle,
    try
        Invocation = <<5:128>>,
        {ok, Open} = quod_scope_session:invoke_open(
            Handle, Invocation, {answer_value, {'Value'}},
            [{<<"answer:origin">>, <<6:256>>}],
            quod_transaction_scope:empty_selection()),
        ?assertEqual({opened, Invocation}, reply(Worker, Proof, Session, Open)),
        {ok, Next} = quod_scope_session:invoke_next(Handle, Invocation, 1),
        Result = reply(Worker, Proof, Session, Next),
        %% Report only shape/quantity; never print a whole private answer.
        io:format("ANSWER_BASELINE output_bytes=~B result=~p~n",
                  [byte_size(Value), result_shape(Result)]),
        ?assertEqual(solution, element(1, Result)),
        ?assertEqual({answer_value, Value}, element(3, Result))
    after
        ok = quod_scope_session:close(Handle),
        receive {'DOWN', Monitor, process, Worker, _} -> ok
        after 1000 -> error(scope_not_retired)
        end,
        quod_erlog_db_mvcc:delete(Db)
    end.

result_shape({solution, Seq, _, Dirty, Independent}) ->
    {solution, Seq, Dirty, Independent};
result_shape(Other) -> Other.

reply(Worker, Proof, Session, Ref) ->
    receive
        {scope_reply, Worker, Proof, Session, Ref, Reply} -> Reply
    after 5000 -> error(scope_reply_timeout)
    end.
