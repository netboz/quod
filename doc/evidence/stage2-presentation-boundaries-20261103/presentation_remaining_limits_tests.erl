-module(presentation_remaining_limits_tests).
-include_lib("eunit/include/eunit.hrl").

link_carries_complete_payload_above_old_quota_test() ->
    Payload=binary:copy(<<42>>,1024*1024+37),
    ?assertEqual({[Payload],<<>>},quod_link:parse(quod_link:frame(Payload))).

safe_term_accepts_deep_canonical_value_test() ->
    Term=nested(96),Bytes=term_to_binary(Term,[deterministic]),
    ?assertEqual({ok,Term},quod_safe_term:decode_wrapped(Bytes,byte_size(Bytes))).

safe_term_preserves_explicit_finite_and_unlimited_allowances_test() ->
    Term={payload,binary:copy(<<1>>,4096)},Bytes=term_to_binary(Term,[deterministic]),
    ?assertEqual({error,too_large},quod_safe_term:encode_canonical(Term,byte_size(Bytes)-1)),
    ?assertEqual({ok,Bytes},quod_safe_term:encode_canonical(Term,unlimited)),
    ?assertEqual({ok,Term},quod_safe_term:decode_wrapped(Bytes,unlimited)).

wire_term_accepts_deep_exact_value_test() ->
    Term=nested(96),{ok,Wire}=quod_wire_term:encode(Term),
    ?assertEqual({ok,Term},quod_wire_term:decode(Wire)).

signed_large_goal_retains_exact_bytes_and_signature_test() ->
    {Public,_}=Key=quod_identity:generate(),
    Blob=binary:copy(<<$x>>,140*1024),
    Text= <<"X = <<\"",Blob/binary,"\">>.">>,
    Request=#{network_identity=><<1:256>>,signing_public_key=>Public,
        operation_id=><<2:256>>,agent_namespace=><<"limits:test">>,
        agent_genesis_anchor=><<3:256>>,agent_instance_text=><<"me.">>,
        mode=>read,parser_version=>3,not_after_ms=>1800000000000,goal_text=>Text},
    {ok,Bytes}=quod_client_goal:encode(Request),
    Signature=quod_identity:sign(Bytes,quod_identity:key_term(Key)),
    ?assertMatch({ok,_},quod_client_goal:verify(Bytes,Signature)),
    ?assertEqual({ok,Request},quod_client_goal:decode(Bytes)),
    ?assertMatch({error,_},quod_client_goal:verify(<<Bytes/binary,0>>,Signature)).

parser_accepts_complete_token_population_test() ->
    Items=lists:join(",",lists:duplicate(3000,"1")),
    Text=iolist_to_binary(["p([",Items,"])."]),
    ?assertMatch({ok,_},quod_client_goal_parser:parse(Text,3)).

parser_accepts_long_opaque_symbol_without_atom_creation_test() ->
    Name=binary:copy(<<$z>>,1100),
    ?assertError(badarg,binary_to_existing_atom(Name)),
    ?assertMatch({ok,_},quod_client_goal_parser:parse(<<Name/binary,"(ok).">>,3)),
    ?assertError(badarg,binary_to_existing_atom(Name)).

parser_accepts_large_integer_text_test() ->
    Digits=binary:copy(<<$1>>,1100),
    ?assertMatch({ok,_},quod_client_goal_parser:parse(<<"X = ",Digits/binary,".">>,3)).

durable_goal_and_result_use_material_admission_test() ->
    Term={payload,binary:copy(<<5>>,140*1024)},
    {ok,Goal}=quod_durable_term:encode_goal(Term),
    ?assertMatch({ok,_},quod_durable_term:decode_goal(Goal)),
    {ok,Result}=quod_durable_term:encode_result(#{<<"Value">>=>Term}),
    ?assertMatch({ok,_},quod_durable_term:decode_result(Result)).

nested(0) -> leaf;
nested(N) -> {node,nested(N-1)}.
