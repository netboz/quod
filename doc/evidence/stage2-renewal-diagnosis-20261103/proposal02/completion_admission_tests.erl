-module(completion_admission_tests).
-include_lib("eunit/include/eunit.hrl").

completion_validates_the_complete_stack_once_test() ->
    Reasons=[{reason,N}||N<-lists:seq(1,128)],
    {module,quod_wire_term}=code:ensure_loaded(quod_wire_term),
    Trace=trace:session_create(completion_admission,self(),[]),
    MFA={quod_wire_term,encode_failure_reasons,1},
    try
        trace:function(Trace,MFA,true,[local,call_count]),
        ?assertEqual({complete,Reasons},quod_ask:checked_completion(Reasons)),
        {call_count,Count}=trace:info(Trace,MFA,call_count),
        ?assertEqual(1,Count)
    after trace:session_destroy(Trace) end.

completion_keeps_empty_exhaustion_test() ->
    ?assertEqual({complete,[]},quod_ask:checked_completion([])).

completion_keeps_large_and_opaque_reasons_test() ->
    Reasons=[{reason,binary:copy(<<"x">>,8192)},{{'$quod_symbol',<<"foreign">>},value}],
    ?assertEqual({complete,Reasons},quod_ask:checked_completion(Reasons)).

completion_rejects_nonportable_and_malformed_stacks_test() ->
    lists:foreach(fun(Value)->?assertEqual(error,quod_ask:checked_completion(Value)) end,
        [[{'Unbound'}],[self()],[make_ref()],[#{a=>b}],[ok|improper],not_a_list]).
