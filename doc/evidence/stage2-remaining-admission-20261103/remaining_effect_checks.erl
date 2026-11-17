-module(remaining_effect_checks).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

callable_population_is_not_syntax_test() ->
    Terms = [{'$quod_symbol', <<"remaining_callable_",(integer_to_binary(N))/binary>>}
             || N <- lists:seq(1,513)],
    Goal = lists:foldr(fun(X,Y)->{',',X,Y} end,true,Terms),
    ?assertMatch({ok,_}, quod_wire_term:materialize_goal_symbols(Goal)).

transfer_page_count_is_not_shape_test() ->
    Parts = [{group,N,N} || N <- lists:seq(1,257)],
    ?assert(quod_catchup:valid_transfer_parts(Parts,0,0)).

transfer_opaque_payload_is_not_page_quota_test() ->
    %% This checks carrier shape only. History authentication remains downstream.
    ?assert(quod_catchup:valid_transfer_parts(
        [{entry,binary:copy(<<0>>,901*1024)}],0,0)).

same_author_queue_is_not_population_policy_test() ->
    F = quod_ledger_artifact_tests:fixture(quod_ledger),
    T = maps:get(transaction,F),
    Request = quod_ingress_state:prepare_request(quod_ingress_state:request(T),false),
    Q = lists:foldl(fun(N,S)->
        {ok,N,Next}=quod_ingress_state:enqueue({caller,N},self(),Request,1,S),Next
    end,quod_ingress_state:new(),lists:seq(1,65)),
    ?assertEqual(65,quod_ingress_state:count(Q)).

valid_single_effect_is_not_byte_quota_test() ->
    {ok,Effect} = quod_effect:new(create,<<1:256>>,
        {agent,<<5:256>>}, {binary:copy(<<"n">>,2200),<<2:256>>},
        <<3:256>>,<<4:256>>),
    ?assert(quod_effect:validate_list([Effect])),
    ?assertMatch({ok,_,_,_,_,_},quod_dtx:encode_material([],#{},[Effect],[],[])).

failure_stack_is_not_population_quota_test() ->
    Reasons = lists:duplicate(257,{because,missing}),
    {ok,Bytes} = quod_wire_term:encode_failure_reasons(Reasons),
    ?assertEqual({ok,Reasons},quod_wire_term:decode_failure_reasons(Bytes)).

namespace_storage_supports_current_admitted_name_test() ->
    Ns = binary:copy(<<"n">>,192),
    ?assert(quod_directory_shape:valid_namespace(Ns)),
    Root = "/checks/namespace-store-baseline",
    {ok,S} = quod_ledger_store:open(Ns,Root),
    ok = quod_ledger_store:close(S).
