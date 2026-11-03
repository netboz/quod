-module(presentation_reply_checks).
-include_lib("eunit/include/eunit.hrl").

complete_authorized_result_has_no_second_byte_quota_test() ->
    F=quod_ct:signed_goal_fixture(#{mode=>read,goal_text=><<"lookup(X).">>}),
    Evidence=maps:get(evidence,F), Value=binary:copy(<<"x">>,600000),
    Result=quod_client_result:normalize(Evidence,{ok,[#{0=>Value}],7}),
    ?assertMatch({answers,7,[_]},Result),
    {ok,Bytes}=quod_client_result:encode(Result),
    ?assertEqual({ok,Result},quod_client_result:decode(Bytes)).
