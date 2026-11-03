%% Proposed tests only. Not installed or executed in this campaign.
-module(quod_remaining_admission_tests).
-include_lib("eunit/include/eunit.hrl").
-include("erlog_int.hrl").
-export([two_reasons/1]).

committee_population_keeps_crypto_and_exact_honest_count_test() ->
    Identities = [begin
        {Pub, Seed} = quod_identity:generate(),
        {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}
    end || _ <- lists:seq(1,65)],
    Members = lists:sort([P || {P,_} <- Identities]),
    Bytes = <<"remaining-admission/committee">>,
    Rows = lists:sort([{P,quod_identity:sign(Bytes,I)} || {P,I} <- Identities]),
    ?assertEqual({ok,65},quod_quorum:committee_size(Members)),
    ?assert(quod_quorum:verify(Members,Bytes,Rows)),
    Honest = lists:sublist(Rows,quod_quorum:honest_threshold(65)),
    ?assert(quod_quorum:verify_honest(Members,Bytes,Honest)),
    ?assertNot(quod_quorum:verify_honest(Members,Bytes,Rows)),
    ?assertNot(quod_quorum:verify(Members,<<"wrong-domain">>,Rows)),
    ?assertNot(quod_quorum:verify([hd(Members)|Members],Bytes,Rows)),
    ?assertNot(quod_quorum:canonical_signatures([hd(Rows)|Rows])).

complete_page_above_former_count_and_byte_quotas_test() ->
    %% Carrier shape only; authenticated history acceptance is a separate owner.
    Parts = [{group,N,N} || N <- lists:seq(1,257)] ++
            [{entry,binary:copy(<<0>>,901*1024)}],
    Page = {history_page3,<<1:128>>,<<2:128>>,Parts,257,done,<<3:128>>},
    {ok,Blob} = quod_catchup:encode_frame(<<"remaining:test">>,Page),
    ?assertMatch({ok,Page,_},quod_catchup:decode_frame(<<"remaining:test">>,Blob)),
    ?assertMatch({error,_},quod_catchup:decode_frame(<<"wrong:owner">>,Blob)),
    ?assertMatch({error,_},quod_catchup:decode_frame(<<"remaining:test">>,<<Blob/binary,0>>)),
    ?assertMatch({error,_},quod_catchup:encode_frame(<<"remaining:test">>,setelement(4,Page,[invalid]))).

callable_population_preserves_opaque_argument_data_test() ->
    Names = [<<"remaining_callable_",(integer_to_binary(N))/binary>> || N <- lists:seq(1,513)],
    Goal = lists:foldr(fun(N,Rest)->{',',{'$quod_symbol',N},Rest} end,true,Names),
    ?assertMatch({ok,_},quod_wire_term:materialize_goal_symbols(Goal)),
    Opaque = {'$quod_symbol',<<"unmaterialized_argument_",(binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>},
    ?assertEqual({ok,{known,Opaque}},quod_wire_term:materialize_goal_symbols({known,Opaque})),
    ?assertException(error,badarg,binary_to_existing_atom(element(2,Opaque),utf8)).

single_effect_with_canonical_large_actor_keeps_semantic_singleton_test() ->
    Text = <<"human_user(<<\"",(binary:copy(<<"a">>,2200))/binary,"\">>).">>,
    {ok,#{blob := Actor}} = quod_agent_ref:from_text(<<"quod:agent">>,<<5:256>>,Text,2),
    {ok,Effect} = quod_effect:new(create,<<1:256>>,{agent,Actor},
                                  {<<"quod:effect">>,<<2:256>>},<<3:256>>,<<4:256>>),
    ?assert(quod_effect:validate_list([Effect])),
    ?assertNot(quod_effect:validate_list([Effect,Effect])),
    ?assertNot(quod_effect:validate_list([{invalid_effect}])),
    ?assertMatch({ok,_,_,_,_,_},quod_dtx:encode_material([],#{},[Effect],[],[])).

complete_diagnostics_and_explicit_finite_callback_test() ->
    {ok,Native} = erlog_int:new(erlog_db_dict,null),
    St = erlog_int:set_failure_reason_policy({quod_wire_term,valid_failure_reason_stack},Native),
    Large = {because,binary:copy(<<"d">>,4097)},
    Next = lists:foldl(fun(_,S)->erlog_int:add_failure_reason(Large,S) end,St,lists:seq(1,257)),
    Reasons = Next#est.fail_reasons,
    ?assertEqual(257,length(Reasons)),
    ?assertNot(lists:member(fail_reasons_truncated,Reasons)),
    {ok,Blob} = quod_wire_term:encode_failure_reasons(Reasons),
    ?assertEqual({ok,Reasons},quod_wire_term:decode_failure_reasons(Blob)),
    ?assertEqual({error,bad_term},quod_wire_term:encode_failure_reasons([{'Unbound'}])),
    ?assertEqual({error,bad_term},quod_wire_term:encode_failure_reasons([ok|invalid])),
    Finite = erlog_int:set_failure_reason_policy({?MODULE,two_reasons},Native),
    Refused = lists:foldl(fun(_,S)->erlog_int:add_failure_reason(reason,S) end,Finite,lists:seq(1,3)),
    ?assertEqual([fail_reasons_truncated,reason],Refused#est.fail_reasons).

two_reasons(Reasons) -> length(Reasons) =< 2.
